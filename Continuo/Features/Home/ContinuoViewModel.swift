import Foundation
import Observation
import PhotosUI
import OSLog

enum SourceCleanupState: Equatable {
    case hidden
    case available
    case deleting
    case deleted
    case resetOnly
}

@MainActor
@Observable
final class ContinuoViewModel {
    private struct PreparedMapping: Sendable {
        let sourceIDs: [UUID]
        let joins: [JoinResult]
    }

    private struct MappingPairKey: Hashable, Sendable {
        let from: UUID
        let to: UUID
    }

    enum ProcessingState: Equatable {
        case idle
        case processing(StitchProgress)
        case ready
        case needsReview
        case failed
        case cancelled
    }

    var sources: [SourceImage] = []
    var preview: StitchPreview?
    var completedStitches: [CompletedStitch] = []
    var state: ProcessingState = .idle
    var errorMessage: String?
    var recoverySuggestion: String?
    var selectedJoinDiagnostics: JoinDiagnostics?
    var sourceCleanupState: SourceCleanupState = .hidden
    var sourceCleanupError: String?
    var preparationStatus: String?
    private(set) var historyStorageLocation: HistoryStorageLocation
    private var requestedHistoryStorageLocation: HistoryStorageLocation
    private(set) var historySyncState: HistorySyncState
    private(set) var historyLastSyncedAt: Date?
    private(set) var historySyncError: String?
    private(set) var historyTransferProgress: HistoryTransferProgress?
    private(set) var historyTransferResult: HistoryTransferResult?
    private(set) var historyTransferError: String?
    private(set) var historyAssetPreparationID: UUID?
    private(set) var historyAssetPreparationProgress: HistoryAssetPreparationProgress?
    private(set) var isCurrentPreviewSaved = false
    var intelligenceMode: StitchIntelligenceMode
    private(set) var stitchDirection: StitchDirection = .vertical

    private let photosImporter = PhotosImageImporter()
    private let automaticScreenshotImporter = AutomaticScreenshotImporter()
    private let filesImporter = FileImageImporter()
    private let sourceDeletionService = SourceDeletionService()
    private var historyImageStore: HistoryImageStore
    private var engine = StitchEngine(direction: .vertical)
    private var processingTask: Task<Void, Never>?
    private var mappingPreparationTask: Task<[JoinResult], Error>?
    private var mappingPreparationObserver: Task<Void, Never>?
    private var preparedMapping: PreparedMapping?
    private var preparedJoinsByPair: [MappingPairKey: JoinResult] = [:]
    private var mappingPreparationSourceIDs: [UUID]?
    private var historyArchiveTask: Task<Void, Never>?
    private var historyLoadTask: Task<Void, Never>?
    private var historyRecoveryTask: Task<Void, Never>?
    private var historySyncMonitorTask: Task<Void, Never>?
    private(set) var isLoadingHistory = false
    /// Progress callbacks are delivered through main-actor tasks. This token
    /// prevents a callback from an older stitch from changing the state of a
    /// newer stitch, or from changing `.ready` back to `.processing(.complete)`
    /// after the result has been published.
    private var activeStitchID: UUID?
    private let logger = Logger(subsystem: "dev.iamshift.Continuo", category: "stitching")
    private static let historyStoragePreferenceKey = "historyStorageLocation"
    private static let locallyDeletedHistoryKey = "locallyDeletedHistoryIDs"
    private static let intelligenceModePreferenceKey = "stitchIntelligenceMode"

    private static func locallyDeletedHistoryIDs() -> Set<UUID> {
        Set(
            (UserDefaults.standard.stringArray(forKey: Self.locallyDeletedHistoryKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
    }

    private static func setLocallyDeletedHistoryIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: Self.locallyDeletedHistoryKey)
    }

    private static func visibleHistory(_ stitches: [CompletedStitch]) -> [CompletedStitch] {
        let locallyDeleted = locallyDeletedHistoryIDs()
        return stitches.filter { !locallyDeleted.contains($0.id) }
    }

    init(
        historyImageStore: HistoryImageStore? = nil,
        loadsHistoryInBackground: Bool = false
    ) {
        let preferredLocation = HistoryStorageLocation(
            rawValue: UserDefaults.standard.string(forKey: Self.historyStoragePreferenceKey) ?? ""
        ) ?? .onThisDevice
        let configuredStore = historyImageStore ?? HistoryImageStore(location: preferredLocation)
        let usableStore = configuredStore.isAvailable ? configuredStore : HistoryImageStore()
        self.historyImageStore = usableStore
        self.historyStorageLocation = usableStore.location
        self.requestedHistoryStorageLocation = preferredLocation
        self.historySyncState = preferredLocation == .iCloudDrive && usableStore.location != .iCloudDrive
            ? .unavailable
            : (usableStore.location == .iCloudDrive ? .syncing : .localOnly)
        self.historyLastSyncedAt = nil
        self.historySyncError = preferredLocation == .iCloudDrive && usableStore.location != .iCloudDrive
            ? HistoryImageStoreError.iCloudUnavailable.localizedDescription
            : nil
        self.intelligenceMode = StitchIntelligenceMode(
            rawValue: UserDefaults.standard.string(forKey: Self.intelligenceModePreferenceKey) ?? ""
        ) ?? .automatic
        if preferredLocation == .iCloudDrive {
            startHistorySyncMonitor()
        }
        if loadsHistoryInBackground {
            isLoadingHistory = true
            historyLoadTask = Task { [weak self, usableStore] in
                do {
                    let loaded = try await Task.detached(priority: .utility) {
                        try usableStore.load()
                    }.value
                    guard let self, !Task.isCancelled else { return }
                    completedStitches = Self.visibleHistory(loaded)
                    if usableStore.location == .iCloudDrive {
                        historySyncState = .upToDate
                        historyLastSyncedAt = Date()
                        historySyncError = nil
                    }
                    isLoadingHistory = false
                } catch is CancellationError {
                    guard let self else { return }
                    isLoadingHistory = false
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    isLoadingHistory = false
                    if usableStore.location == .iCloudDrive {
                        historySyncState = .failed
                        historySyncError = error.localizedDescription
                    }
                    logger.error("Could not load stitch history: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            do {
                completedStitches = try usableStore.load()
                if usableStore.location == .iCloudDrive {
                    historySyncState = .upToDate
                    historyLastSyncedAt = Date()
                }
            } catch {
                if usableStore.location == .iCloudDrive {
                    historySyncState = .failed
                    historySyncError = error.localizedDescription
                }
                logger.error("Could not load stitch history: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var isHistoryStorageAvailable: Bool {
        historyImageStore.isAvailable
    }

    var isHistorySyncEnabled: Bool {
        requestedHistoryStorageLocation == .iCloudDrive
    }

    var isProcessing: Bool {
        if case .processing = state {
            return true
        }
        return false
    }

    /// Refreshes the lightweight history records after iCloud Drive has had
    /// an opportunity to receive changes from another device.
    func refreshHistoryIfNeeded() {
        guard isHistorySyncEnabled,
              !isLoadingHistory,
              !isProcessing,
              historyArchiveTask == nil,
              historyRecoveryTask == nil,
              historyTransferProgress?.phase == nil || historyTransferProgress?.phase == .finished
        else {
            return
        }

        guard historyStorageLocation == .iCloudDrive else {
            historyRecoveryTask = Task { [weak self] in
                _ = await self?.switchHistoryStorageLocation(to: .iCloudDrive)
                guard let self else { return }
                historyRecoveryTask = nil
            }
            return
        }

        historyLoadTask?.cancel()
        isLoadingHistory = true
        historySyncState = .syncing
        historySyncError = nil
        let store = historyImageStore
        historyLoadTask = Task { [weak self, store] in
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    try store.load()
                }.value
                guard let self, !Task.isCancelled else { return }
                completedStitches = Self.visibleHistory(loaded)
                isLoadingHistory = false
                historySyncState = .upToDate
                historyLastSyncedAt = Date()
                historySyncError = nil
                historyLoadTask = nil
            } catch is CancellationError {
                guard let self else { return }
                isLoadingHistory = false
                historyLoadTask = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                isLoadingHistory = false
                historySyncState = .failed
                historySyncError = error.localizedDescription
                historyLoadTask = nil
                logger.error("Could not refresh iCloud stitch history: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Retries an unavailable or failed iCloud operation while the app is
    /// active. Healthy history is not reloaded on every retry tick.
    func retryHistorySyncIfNeeded() {
        guard isHistorySyncEnabled,
              historyStorageLocation != .iCloudDrive || historySyncState == .unavailable || historySyncState == .failed
        else {
            return
        }
        refreshHistoryIfNeeded()
    }

    private func startHistorySyncMonitor() {
        historySyncMonitorTask?.cancel()
        historySyncMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                retryHistorySyncIfNeeded()
            }
        }
    }

    func setIntelligenceMode(_ mode: StitchIntelligenceMode) {
        intelligenceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.intelligenceModePreferenceKey)
    }

    func setStitchDirection(_ direction: StitchDirection) {
        guard stitchDirection != direction else { return }
        stitchDirection = direction
        engine.direction = direction
        preparedJoinsByPair.removeAll(keepingCapacity: false)
        resetResult()
    }

    func switchHistoryStorageLocation(to location: HistoryStorageLocation) async -> String? {
        requestedHistoryStorageLocation = location
        UserDefaults.standard.set(location.rawValue, forKey: Self.historyStoragePreferenceKey)

        if location == .onThisDevice {
            historyRecoveryTask?.cancel()
            historyRecoveryTask = nil
            historySyncMonitorTask?.cancel()
            historySyncMonitorTask = nil
        } else {
            startHistorySyncMonitor()
        }

        guard location != historyStorageLocation else {
            historySyncState = location == .iCloudDrive ? .upToDate : .localOnly
            historySyncError = nil
            return nil
        }

        historyLoadTask?.cancel()
        if location == .onThisDevice {
            historyRecoveryTask?.cancel()
        }
        historyLoadTask = nil
        historyRecoveryTask = nil
        isLoadingHistory = false

        historyTransferProgress = HistoryTransferProgress(
            phase: .preparing,
            completed: 0,
            total: 0,
            currentFile: nil
        )
        historyTransferResult = nil
        historyTransferError = nil
        historySyncError = nil
        historySyncState = location == .iCloudDrive ? .syncing : .localOnly

        let currentStore = historyImageStore
        let destinationStore = HistoryImageStore(location: location)
        guard destinationStore.isAvailable else {
            historyTransferProgress = nil
            historySyncState = .unavailable
            historySyncError = HistoryImageStoreError.iCloudUnavailable.localizedDescription
            historyTransferError = HistoryImageStoreError.iCloudUnavailable.localizedDescription
            return HistoryImageStoreError.iCloudUnavailable.localizedDescription
        }

        do {
            let (progressStream, progressContinuation) = AsyncStream<HistoryTransferProgress>
                .makeStream()
            let progressTask = Task { @MainActor [weak self] in
                for await progress in progressStream {
                    guard let self else { return }
                    historyTransferProgress = progress
                }
            }
            defer {
                progressContinuation.finish()
                progressTask.cancel()
            }
            let result = try await Task.detached(
                priority: .utility
            ) { [currentStore, destinationStore, progressContinuation] in
                try currentStore.migrateHistory(to: destinationStore) { progress in
                    progressContinuation.yield(progress)
                }
            }.value
            historyTransferProgress = HistoryTransferProgress(
                phase: .loading,
                completed: result.copiedFileCount,
                total: result.copiedFileCount,
                currentFile: nil
            )
            let loaded = try await Task.detached(priority: .utility) {
                try destinationStore.load()
            }.value
            historyTransferProgress = HistoryTransferProgress(
                phase: .cleaning,
                completed: result.copiedFileCount,
                total: result.copiedFileCount,
                currentFile: nil
            )
            try await Task.detached(priority: .utility) {
                try currentStore.removeStoredFiles()
            }.value
            historyImageStore = destinationStore
            historyStorageLocation = location
                completedStitches = Self.visibleHistory(loaded)
            historySyncState = location == .iCloudDrive ? .upToDate : .localOnly
            historyLastSyncedAt = location == .iCloudDrive ? Date() : nil
            historySyncError = nil
            historyTransferProgress = HistoryTransferProgress(
                phase: .finished,
                completed: result.copiedFileCount,
                total: result.copiedFileCount,
                currentFile: nil
            )
            historyTransferResult = result
            logger.info("Moved stitch history to \(location.rawValue, privacy: .public).")
            return nil
        } catch {
            historyTransferProgress = nil
            historySyncState = location == .iCloudDrive ? .failed : .localOnly
            historySyncError = error.localizedDescription
            historyTransferError = error.localizedDescription
            logger.error("Could not move stitch history to \(location.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    isolated deinit {
        processingTask?.cancel()
        mappingPreparationTask?.cancel()
        mappingPreparationObserver?.cancel()
        historyLoadTask?.cancel()
        historyRecoveryTask?.cancel()
        historySyncMonitorTask?.cancel()
    }

    func importPhotos(_ results: [PHPickerResult]) {
        logger.info("Received photo selection with \(results.count) item(s) and Photos asset identifiers.")
        let pendingArchiveTask = prepareForIncomingSources(replacesCurrentSelection: false)
        if pendingArchiveTask == nil {
            preparationStatus = "Preparing screenshots for stitching…"
        }

        let importer = photosImporter
        processingTask = Task { [weak self] in
            await pendingArchiveTask?.value
            guard let owner = self, !Task.isCancelled else { return }
            guard owner.state != .failed else {
                owner.processingTask = nil
                return
            }
            owner.preparationStatus = "Preparing screenshots for stitching…"

            do {
                let imported = try await importer.importItems(results) { [weak self] progress in
                    self?.preparationStatus = self?.preparationStatus(for: progress)
                }
                try Task.checkCancellation()

                guard let self else { return }
                appendSources(imported, cancelCurrentTask: false)
                logger.info("Imported \(imported.count) still image(s) with Photos asset identifiers; waiting for the user to start stitching.")
                preparationStatus = nil
                state = .idle
                processingTask = nil
            } catch let error as ContinuoError {
                guard let self, !Task.isCancelled else { return }
                preparationStatus = nil
                log(error: error, prefix: "Screenshot import failed")
                present(error)
                processingTask = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                preparationStatus = nil
                logger.error("Screenshot import failed unexpectedly: \(error.localizedDescription, privacy: .public)")
                showError(error)
                processingTask = nil
            }
        }
    }

    func importFiles(_ urls: [URL]) {
        let pendingArchiveTask = prepareForIncomingSources(replacesCurrentSelection: false)
        guard let pendingArchiveTask else {
            importFileURLs(urls, cancelCurrentTask: false)
            return
        }

        processingTask = Task { [weak self] in
            await pendingArchiveTask.value
            guard let owner = self, !Task.isCancelled else { return }
            guard owner.state != .failed else {
                owner.processingTask = nil
                return
            }
            owner.preparationStatus = "Preparing screenshots for stitching…"
            owner.importFileURLs(urls, cancelCurrentTask: false)
            owner.processingTask = nil
        }
    }

    private func importFileURLs(_ urls: [URL], cancelCurrentTask: Bool) {
        do {
            let imported = try filesImporter.importFiles(urls)
            appendSources(imported, cancelCurrentTask: cancelCurrentTask)
            logger.info("Imported \(imported.count) still image(s) from Files; waiting for the user to start stitching.")
        } catch {
            showError(error)
        }
    }

    func autoSelectScreenshots() {
        guard preparationStatus == nil else { return }
        if case .processing = state {
            return
        }

        if stitchDirection != .vertical {
            stitchDirection = .vertical
            engine.direction = .vertical
            preparedJoinsByPair.removeAll(keepingCapacity: false)
        }

        let pendingArchiveTask = prepareForIncomingSources(replacesCurrentSelection: true)
        if pendingArchiveTask == nil {
            preparationStatus = "Preparing screenshots for stitching…"
        }

        let importer = automaticScreenshotImporter
        let mode = intelligenceMode
        let discoveryRegistrar = PairwiseRegistrar(configuration: RegistrationConfiguration(
            maximumSeedOffsets: 6,
            coarseDriftSamples: 13,
            visionFallbackEnabled: mode != .automatic
        ))
        let builder = AutomaticScreenshotSequenceBuilder(
            registrar: discoveryRegistrar,
            maximumConcurrentRegistrations: 4
        )
        let intelligenceAdvisor = ScreenshotIntelligenceFactory.advisor(for: mode)
        processingTask = Task { [weak self] in
            await pendingArchiveTask?.value
            guard let owner = self, !Task.isCancelled else { return }
            guard owner.state != .failed else {
                owner.processingTask = nil
                return
            }
            owner.preparationStatus = "Preparing screenshots for stitching…"

            let (progressStream, progressContinuation) = AsyncStream<StitchProgress>.makeStream()
            let progressTask = Task { @MainActor [weak self] in
                for await progress in progressStream {
                    guard let self else { return }
                    preparationStatus = self.preparationStatus(for: progress)
                }
            }
            var importedCandidates: [SourceImage] = []
            var fullResolutionSources: [SourceImage] = []
            var retainedFullResolutionIDs = Set<UUID>()
            defer {
                progressContinuation.finish()
                progressTask.cancel()
                for candidate in importedCandidates {
                    try? FileManager.default.removeItem(at: candidate.localURL)
                }
                for source in fullResolutionSources where !retainedFullResolutionIDs.contains(source.id) {
                    try? FileManager.default.removeItem(at: source.localURL)
                }
            }

            do {
                importedCandidates = try await importer.importRecentScreenshotCandidates { progress in
                    progressContinuation.yield(progress)
                }
                try Task.checkCancellation()

                let candidates = importedCandidates
                let candidateMetadata = candidates.compactMap { source -> AutomaticScreenshotCandidate? in
                    guard let identifier = source.sourceIdentifier else { return nil }
                    return AutomaticScreenshotCandidate(
                        identifier: identifier,
                        captureDate: source.captureDate,
                        pixelSize: source.pixelSize
                    )
                }
                let prioritizedCandidateIDs = await intelligenceAdvisor
                    .prioritizedCandidateIDs(candidateMetadata)
                let selection = try await Task.detached(priority: .userInitiated) {
                    try await builder.select(
                        from: candidates,
                        prioritizedCandidateIDs: prioritizedCandidateIDs
                    ) { progress in
                        progressContinuation.yield(progress)
                    }
                }.value
                try Task.checkCancellation()

                fullResolutionSources = try await importer.importFullResolutionSources(selection.sources) { progress in
                    progressContinuation.yield(progress)
                }
                try Task.checkCancellation()

                guard let self else { return }
                retainedFullResolutionIDs = Set(fullResolutionSources.map(\.id))

                let previousSources = sources
                sources = fullResolutionSources
                removeTemporaryWorkingCopies(previousSources)
                resetResult(cancelCurrentTask: false, schedulePreparation: false)
                retainPreparedMapping(selection.joins, for: fullResolutionSources)
                preparationStatus = nil
                state = .idle
                processingTask = nil
                logger.info(
                    "Automatically selected \(selection.sources.count) screenshot(s) from \(importedCandidates.count) recent candidate(s) using \(mode.rawValue, privacy: .public); sequence_score=\(selection.score, privacy: .public)."
                )
            } catch let error as ContinuoError {
                guard let self, !Task.isCancelled else { return }
                preparationStatus = nil
                log(error: error, prefix: "Automatic screenshot selection failed")
                present(error)
                processingTask = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                preparationStatus = nil
                logger.error("Automatic screenshot selection failed unexpectedly: \(error.localizedDescription, privacy: .public)")
                showError(error)
                processingTask = nil
            }
        }
    }

    func removeSources(at offsets: IndexSet) {
        let removedSources = offsets.compactMap { index in
            sources.indices.contains(index) ? sources[index] : nil
        }
        for index in offsets.sorted(by: >) where sources.indices.contains(index) {
            sources.remove(at: index)
        }
        removeTemporaryWorkingCopies(removedSources)
        resetResult()
    }

    func removeSource(id: UUID) {
        let removedSources = sources.filter { $0.id == id }
        sources.removeAll { $0.id == id }
        removeTemporaryWorkingCopies(removedSources)
        resetResult()
    }

    func moveSource(id sourceID: UUID, toIndex requestedIndex: Int) {
        guard let sourceIndex = sources.firstIndex(where: { $0.id == sourceID }) else {
            return
        }

        let source = sources.remove(at: sourceIndex)
        let destinationIndex = min(max(0, requestedIndex), sources.count)
        sources.insert(source, at: destinationIndex)
        logger.info("Reordered screenshot \(sourceID.uuidString, privacy: .public) to position \(destinationIndex + 1, privacy: .public).")
        resetResult()
    }

    func clearSources() {
        let removedSources = sources
        sources.removeAll()
        removeTemporaryWorkingCopies(removedSources)
        resetResult()
    }

    func stitch() {
        logger.info("Manual stitch requested for \(self.sources.count) source(s).")
        processingTask?.cancel()
        activeStitchID = nil
        preview = nil
        isCurrentPreviewSaved = false
        errorMessage = nil
        recoverySuggestion = nil
        selectedJoinDiagnostics = nil
        sourceCleanupState = .hidden
        sourceCleanupError = nil
        preparationStatus = nil

        guard sources.count >= 2 else {
            state = .failed
            errorMessage = ContinuoError.needsAtLeastTwoSources.localizedDescription
            return
        }

        let selectedSources = sources
        let precomputedJoins = preparedJoins(for: selectedSources)
        let pendingMappingTask = pendingMappingTask(for: selectedSources)
        preparedMapping = nil
        let stitchID = UUID()
        let stitchStartedAt = DispatchTime.now().uptimeNanoseconds
        activeStitchID = stitchID
        state = .processing(StitchProgress(stage: .normalizing, completed: 0, total: selectedSources.count, message: "Preparing screenshots…"))

        processingTask = Task { [weak self] in
            do {
                guard let self else { return }
                let joinsToReuse: [JoinResult]?
                if let precomputedJoins {
                    joinsToReuse = precomputedJoins
                } else if let pendingMappingTask {
                    joinsToReuse = try? await pendingMappingTask.value
                } else {
                    joinsToReuse = nil
                }
                let result = try await runStitching(
                    sources: selectedSources,
                    precomputedJoins: joinsToReuse,
                    stitchID: stitchID
                )
                guard !Task.isCancelled, activeStitchID == stitchID else { return }
                let registrationSumMilliseconds = result.joins.reduce(0) {
                    $0 + $1.diagnostics.elapsedMilliseconds
                }
                let stitchWallMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds &- stitchStartedAt
                ) / 1_000_000
                logger.info("Manual stitch completed successfully. Preview rendered at \(result.pixelSize.width)x\(result.pixelSize.height) pixels with \(result.joins.count) join(s); stitch_wall_ms=\(stitchWallMilliseconds, privacy: .public) registration_sum_ms=\(registrationSumMilliseconds, privacy: .public).")
                activeStitchID = nil
                preview = result
                isCurrentPreviewSaved = false
                state = .ready
                processingTask = nil
            } catch let error as ContinuoError {
                guard let self, !Task.isCancelled, activeStitchID == stitchID else { return }
                activeStitchID = nil
                logger.error("Manual stitch failed: \(error.localizedDescription, privacy: .public)")
                present(error)
                processingTask = nil
            } catch {
                guard let self, !Task.isCancelled, activeStitchID == stitchID else { return }
                activeStitchID = nil
                logger.error("Manual stitch failed unexpectedly: \(error.localizedDescription, privacy: .public)")
                state = .failed
                errorMessage = error.localizedDescription
                processingTask = nil
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        activeStitchID = nil
        state = .cancelled
        preparationStatus = nil
        errorMessage = ContinuoError.cancelled.localizedDescription
        recoverySuggestion = "Select Stitch Preview when you are ready to try again."
    }

    func markSaveCompleted() {
        guard preview != nil else { return }
        isCurrentPreviewSaved = true
        guard sourceCleanupState != .deleted else { return }
        guard !sources.isEmpty else {
            sourceCleanupState = .hidden
            sourceCleanupError = nil
            return
        }
        sourceCleanupState = .available
        sourceCleanupError = nil
    }

    func deleteSelectedSources() async {
        guard !sources.isEmpty else {
            sourceCleanupState = .resetOnly
            sourceCleanupError = SourceDeletionError.noDeletableSources.localizedDescription
            return
        }

        sourceCleanupState = .deleting
        sourceCleanupError = nil

        do {
            try await sourceDeletionService.delete(sources)
            sourceCleanupState = .deleted
            sourceCleanupError = nil
            logger.info("Deleted the selected original source image(s) after a successful save.")
        } catch {
            sourceCleanupState = .resetOnly
            sourceCleanupError = error.localizedDescription
            logger.error("Selected source deletion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears the active workflow and archives a saved stitch in the
    /// background. Unsaved output is intentionally not retained.
    func resetActiveWorkflow() {
        guard preparationStatus == nil else { return }

        let archiveID = UUID()
        let archiveSavedAt = Date()
        let archiveImage: CGImage?
        let archivePixelSize: PixelSize?
        let archiveSources: [SourceImage]
        let archiveSourceImagesDeleted: Bool
        if isCurrentPreviewSaved, let preview {
            archiveImage = preview.image
            archivePixelSize = preview.pixelSize
            archiveSources = sources
            archiveSourceImagesDeleted = sourceCleanupState == .deleted
        } else {
            archiveImage = nil
            archivePixelSize = nil
            archiveSources = []
            archiveSourceImagesDeleted = false
        }

        let activeSources = sources
        processingTask?.cancel()
        processingTask = nil
        invalidatePreparedMapping(clearPairCache: true)
        activeStitchID = nil
        sources.removeAll()
        removeTemporaryWorkingCopies(activeSources)
        preview = nil
        isCurrentPreviewSaved = false
        errorMessage = nil
        recoverySuggestion = nil
        selectedJoinDiagnostics = nil
        sourceCleanupState = .hidden
        sourceCleanupError = nil
        preparationStatus = nil
        state = .idle

        guard let archiveImage, let archivePixelSize else {
            logger.info("Reset active stitch workflow without archiving an unsaved result.")
            return
        }

        preparationStatus = "Saving stitch for history…"
        let store = historyImageStore
        historyArchiveTask = Task { [weak self] in
            do {
                let asset = try await Task.detached(priority: .utility) {
                    try store.archive(
                        image: archiveImage,
                        pixelSize: archivePixelSize,
                        id: archiveID,
                        savedAt: archiveSavedAt,
                        sources: archiveSources,
                        sourceImagesDeleted: archiveSourceImagesDeleted
                    )
                }.value
                try Task.checkCancellation()

                guard let self else { return }
                completedStitches.insert(
                    CompletedStitch(
                        id: archiveID,
                        thumbnail: asset.thumbnail,
                        fullResolutionURL: asset.fullResolutionURL,
                        pixelSize: asset.pixelSize,
                        savedAt: archiveSavedAt,
                        sources: archiveSources,
                        sourceImagesDeleted: archiveSourceImagesDeleted
                    ),
                    at: 0
                )
                preparationStatus = nil
                historyArchiveTask = nil
                logger.info("Archived completed stitch \(archiveID.uuidString, privacy: .public); history count is now \(self.completedStitches.count, privacy: .public).")
            } catch is CancellationError {
                guard let self else { return }
                preparationStatus = nil
                historyArchiveTask = nil
            } catch {
                guard let self else { return }
                preparationStatus = nil
                historyArchiveTask = nil
                state = .failed
                errorMessage = error.localizedDescription
                recoverySuggestion = "Stitch the screenshots again if you want to keep a history copy."
                logger.error("Completed stitch history archive failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func resetActiveWorkflowAndWait() async {
        resetActiveWorkflow()
        await historyArchiveTask?.value
    }

    func historyExportURL(for id: UUID) async throws -> URL {
        guard
            let stitch = completedStitches.first(where: { $0.id == id }),
            let url = stitch.fullResolutionURL,
            FileManager.default.fileExists(atPath: url.path)
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        historyAssetPreparationID = id
        historyAssetPreparationProgress = HistoryAssetPreparationProgress(
            phase: .checking,
            fraction: nil
        )

        do {
            try await historyImageStore.prepareForExport(url) { [weak self] progress in
                await MainActor.run {
                    guard self?.historyAssetPreparationID == id else { return }
                    self?.historyAssetPreparationProgress = progress
                }
            }
            return url
        } catch {
            clearHistoryAssetPreparation(id: id)
            throw error
        }
    }

    func clearHistoryAssetPreparation(id: UUID) {
        guard historyAssetPreparationID == id else { return }
        historyAssetPreparationID = nil
        historyAssetPreparationProgress = nil
    }

    func consumeHistoryAsset(id: UUID) {
        guard let index = completedStitches.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let url = completedStitches[index].fullResolutionURL {
            historyImageStore.remove(url)
        }
        completedStitches[index].fullResolutionURL = nil
        do {
            try historyImageStore.update(completedStitches[index])
        } catch {
            logger.error("Could not persist consumed history asset \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteHistoryStitch(id: UUID, scope: HistoryDeletionScope) async -> String? {
        guard let index = completedStitches.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let store = historyImageStore
        do {
            if scope == .everywhere || historyStorageLocation == .onThisDevice {
                try await Task.detached(priority: .utility) {
                    try store.deleteHistory(id: id)
                }.value
            }

            var locallyDeleted = Self.locallyDeletedHistoryIDs()
            switch scope {
            case .currentDevice:
                locallyDeleted.insert(id)
            case .everywhere:
                locallyDeleted.remove(id)
            }
            Self.setLocallyDeletedHistoryIDs(locallyDeleted)
            completedStitches.remove(at: index)
            clearHistoryAssetPreparation(id: id)
            logger.info(
                "Deleted completed stitch history \(id.uuidString, privacy: .public) with scope \(String(describing: scope), privacy: .public)."
            )
            return nil
        } catch {
            logger.error("Could not delete completed stitch history \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    func deleteCompletedStitchSources(id: UUID) async {
        guard let index = completedStitches.firstIndex(where: { $0.id == id }) else {
            return
        }

        guard !completedStitches[index].sourceImagesDeleted else {
            return
        }

        let sourcesToDelete = completedStitches[index].sources
        guard !sourcesToDelete.isEmpty else {
            completedStitches[index].sourceDeletionError = SourceDeletionError.noDeletableSources.localizedDescription
            try? historyImageStore.update(completedStitches[index])
            return
        }

        completedStitches[index].sourceDeletionInProgress = true
        completedStitches[index].sourceDeletionError = nil

        do {
            try await sourceDeletionService.delete(sourcesToDelete)
            guard let updatedIndex = completedStitches.firstIndex(where: { $0.id == id }) else {
                return
            }
            completedStitches[updatedIndex].sourceImagesDeleted = true
            completedStitches[updatedIndex].sourceDeletionInProgress = false
            completedStitches[updatedIndex].sourceDeletionError = nil
            completedStitches[updatedIndex].sources.removeAll()
            do {
                try historyImageStore.update(completedStitches[updatedIndex])
            } catch {
                logger.error("Could not persist source deletion for stitch \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            logger.info("Deleted the source images associated with completed stitch \(id.uuidString, privacy: .public).")
        } catch {
            guard let updatedIndex = completedStitches.firstIndex(where: { $0.id == id }) else {
                return
            }
            completedStitches[updatedIndex].sourceDeletionInProgress = false
            completedStitches[updatedIndex].sourceDeletionError = error.localizedDescription
            try? historyImageStore.update(completedStitches[updatedIndex])
            logger.error("Completed stitch source deletion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissError() {
        errorMessage = nil
        recoverySuggestion = nil
        selectedJoinDiagnostics = nil
        state = .idle
    }

    private func appendSources(_ newSources: [SourceImage], cancelCurrentTask: Bool = true) {
        sources.append(contentsOf: newSources)
        resetResult(cancelCurrentTask: cancelCurrentTask)
    }

    private func prepareForIncomingSources(replacesCurrentSelection: Bool) -> Task<Void, Never>? {
        guard replacesCurrentSelection || isCurrentPreviewSaved else {
            return nil
        }
        resetActiveWorkflow()
        return historyArchiveTask
    }

    private func removeTemporaryWorkingCopies(_ sources: [SourceImage]) {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .path

        for source in sources {
            guard
                source.sourceOrigin == .photos ||
                    (source.sourceOrigin == .files && source.originalSourceURL != nil)
            else {
                continue
            }

            let localURL = source.localURL.standardizedFileURL
            guard localURL.path == temporaryRoot || localURL.path.hasPrefix(temporaryRoot + "/") else {
                continue
            }
            if let originalSourceURL = source.originalSourceURL?.standardizedFileURL,
               localURL == originalSourceURL {
                continue
            }
            try? FileManager.default.removeItem(at: localURL)
        }
    }

    private func runStitching(
        sources selectedSources: [SourceImage],
        precomputedJoins: [JoinResult]?,
        stitchID: UUID
    ) async throws -> StitchPreview {
        let engine = engine
        let progressHandler: @Sendable (StitchProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.activeStitchID == stitchID else { return }
                guard case .processing = self.state else { return }
                self.state = .processing(progress)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            try await engine.stitch(
                sources: selectedSources,
                precomputedJoins: precomputedJoins,
                progress: progressHandler
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func scheduleMappingPreparation() {
        invalidatePreparedMapping()
        let candidates = sources.filter { !$0.excluded }
        let currentSourceIDs = Set(candidates.map(\.id))
        preparedJoinsByPair = preparedJoinsByPair.filter {
            currentSourceIDs.contains($0.key.from) && currentSourceIDs.contains($0.key.to)
        }
        guard candidates.count >= 2 else { return }

        let sourceIDs = candidates.map(\.id)
        let reusableJoins = candidates.indices.dropLast().compactMap { index in
            preparedJoinsByPair[MappingPairKey(
                from: candidates[index].id,
                to: candidates[index + 1].id
            )]
        }
        let engine = engine
        let task = Task.detached(priority: .utility) {
            try await engine.precomputeJoins(
                for: candidates,
                reusing: reusableJoins
            )
        }
        mappingPreparationTask = task
        mappingPreparationSourceIDs = sourceIDs
        mappingPreparationObserver = Task { [weak self] in
            do {
                let joins = try await task.value

                guard
                    let self,
                    mappingPreparationSourceIDs == sourceIDs,
                    self.mappingSourceIDs(for: self.sources) == sourceIDs
                else {
                    return
                }
                preparedMapping = PreparedMapping(sourceIDs: sourceIDs, joins: joins)
                for join in joins {
                    preparedJoinsByPair[MappingPairKey(
                        from: join.fromSourceID,
                        to: join.toSourceID
                    )] = join
                }
                mappingPreparationTask = nil
                mappingPreparationObserver = nil
                mappingPreparationSourceIDs = nil
                logger.info(
                    "Prepared \(joins.count) background screenshot mapping join(s) for the current selection."
                )
            } catch is CancellationError {
                // Source edits cancel preparation and start a new task.
            } catch {
                guard let self else { return }
                guard mappingPreparationSourceIDs == sourceIDs else { return }
                mappingPreparationTask = nil
                mappingPreparationObserver = nil
                mappingPreparationSourceIDs = nil
                logger.debug(
                    "Background screenshot mapping was not retained: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func invalidatePreparedMapping(clearPairCache: Bool = false) {
        mappingPreparationTask?.cancel()
        mappingPreparationObserver?.cancel()
        mappingPreparationTask = nil
        mappingPreparationObserver = nil
        mappingPreparationSourceIDs = nil
        preparedMapping = nil
        if clearPairCache {
            preparedJoinsByPair.removeAll(keepingCapacity: false)
        }
    }

    private func preparedJoins(for sources: [SourceImage]) -> [JoinResult]? {
        let sourceIDs = mappingSourceIDs(for: sources)
        guard preparedMapping?.sourceIDs == sourceIDs else { return nil }
        return preparedMapping?.joins
    }

    private func pendingMappingTask(for sources: [SourceImage]) -> Task<[JoinResult], Error>? {
        guard mappingPreparationSourceIDs == mappingSourceIDs(for: sources) else {
            return nil
        }
        return mappingPreparationTask
    }

    private func mappingSourceIDs(for sources: [SourceImage]) -> [UUID] {
        sources.filter { !$0.excluded }.map(\.id)
    }

    private func resetResult(
        cancelCurrentTask: Bool = true,
        schedulePreparation: Bool = true
    ) {
        if cancelCurrentTask {
            processingTask?.cancel()
            processingTask = nil
        }
        activeStitchID = nil
        preview = nil
        isCurrentPreviewSaved = false
        errorMessage = nil
        recoverySuggestion = nil
        selectedJoinDiagnostics = nil
        sourceCleanupState = .hidden
        sourceCleanupError = nil
        preparationStatus = nil
        state = sources.isEmpty ? .idle : .idle
        if schedulePreparation {
            scheduleMappingPreparation()
        }
    }

    private func retainPreparedMapping(
        _ joins: [JoinResult],
        for sources: [SourceImage]
    ) {
        invalidatePreparedMapping(clearPairCache: true)
        let sourceIDs = mappingSourceIDs(for: sources)
        guard joins.count == max(0, sourceIDs.count - 1) else {
            scheduleMappingPreparation()
            return
        }
        preparedMapping = PreparedMapping(sourceIDs: sourceIDs, joins: joins)
        for join in joins {
            preparedJoinsByPair[MappingPairKey(
                from: join.fromSourceID,
                to: join.toSourceID
            )] = join
        }
        logger.info(
            "Retained \(joins.count) automatic-selection mapping join(s) for immediate stitching."
        )
    }

    private func showError(_ error: Error) {
        preparationStatus = nil
        state = .failed
        errorMessage = error.localizedDescription
        recoverySuggestion = "Choose another image or try the import again."
    }

    private func preparationStatus(for progress: StitchProgress) -> String {
        if progress.message.localizedCaseInsensitiveContains("Downloading") {
            return "Fetching the pixels that were hiding in iCloud…"
        }
        return "Preparing screenshots for stitching…"
    }

    private func log(error: ContinuoError, prefix: String) {
        if case let .registrationFailed(join) = error {
            let diagnostics = join.diagnostics
            let reason = diagnostics.failureReason?.rawValue ?? "none"
            logger.error(
                "\(prefix, privacy: .public): \(error.localizedDescription, privacy: .public) score=\(diagnostics.similarityScore, privacy: .public) overlap=\(diagnostics.overlapPercentage, privacy: .public) drift=\(diagnostics.crossAxisDrift, privacy: .public) translation=(\(diagnostics.translation.x, privacy: .public),\(diagnostics.translation.y, privacy: .public)) backend=\(diagnostics.backend.rawValue, privacy: .public) candidates=\(diagnostics.candidateCount, privacy: .public) elapsed_ms=\(diagnostics.elapsedMilliseconds, privacy: .public) reason=\(reason, privacy: .public)"
            )
        } else {
            logger.error("\(prefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func present(_ error: ContinuoError) {
        switch error {
        case let .registrationFailed(join):
            state = .needsReview
            selectedJoinDiagnostics = join.diagnostics
            errorMessage = join.diagnostics.message
            recoverySuggestion = join.diagnostics.recoverySuggestion
        case .cancelled:
            state = .cancelled
            errorMessage = error.localizedDescription
            recoverySuggestion = "Select Stitch Preview when you are ready to try again."
        case .photoLibraryPermissionDenied:
            state = .failed
            errorMessage = error.localizedDescription
            recoverySuggestion = "Allow Photos access in Settings, then try Auto-select again."
        case .noMatchingScreenshotSequence:
            state = .failed
            errorMessage = error.localizedDescription
            recoverySuggestion = "Try manual selection, or create a closer sequence of overlapping screenshots."
        default:
            state = .failed
            errorMessage = error.localizedDescription
            recoverySuggestion = "Check the selected sources and try again."
        }
    }
}
