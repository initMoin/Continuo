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
    private(set) var isCurrentPreviewSaved = false

    private let photosImporter = PhotosImageImporter()
    private let automaticScreenshotImporter = AutomaticScreenshotImporter()
    private let filesImporter = FileImageImporter()
    private let sourceDeletionService = SourceDeletionService()
    private var historyImageStore: HistoryImageStore
    private let engine = StitchEngine()
    private var processingTask: Task<Void, Never>?
    private var historyArchiveTask: Task<Void, Never>?
    /// Progress callbacks are delivered through main-actor tasks. This token
    /// prevents a callback from an older stitch from changing the state of a
    /// newer stitch, or from changing `.ready` back to `.processing(.complete)`
    /// after the result has been published.
    private var activeStitchID: UUID?
    private let logger = Logger(subsystem: "dev.iamshift.Continuo", category: "stitching")
    private static let historyStoragePreferenceKey = "historyStorageLocation"

    init(historyImageStore: HistoryImageStore? = nil) {
        let preferredLocation = HistoryStorageLocation(
            rawValue: UserDefaults.standard.string(forKey: Self.historyStoragePreferenceKey) ?? ""
        ) ?? .onThisDevice
        let configuredStore = historyImageStore ?? HistoryImageStore(location: preferredLocation)
        let usableStore = configuredStore.isAvailable ? configuredStore : HistoryImageStore()
        self.historyImageStore = usableStore
        self.historyStorageLocation = usableStore.location
        do {
            completedStitches = try usableStore.load()
        } catch {
            logger.error("Could not load stitch history: \(error.localizedDescription, privacy: .public)")
        }
    }

    var isHistoryStorageAvailable: Bool {
        historyImageStore.isAvailable
    }

    func switchHistoryStorageLocation(to location: HistoryStorageLocation) async -> String? {
        guard location != historyStorageLocation else {
            return nil
        }

        let currentStore = historyImageStore
        let destinationStore = HistoryImageStore(location: location)
        guard destinationStore.isAvailable else {
            return HistoryImageStoreError.iCloudUnavailable.localizedDescription
        }

        do {
            try await Task.detached(priority: .utility) {
                try currentStore.migrateHistory(to: destinationStore)
            }.value
            let loaded = try await Task.detached(priority: .utility) {
                try destinationStore.load()
            }.value
            try await Task.detached(priority: .utility) {
                try currentStore.removeStoredFiles()
            }.value
            historyImageStore = destinationStore
            historyStorageLocation = location
            completedStitches = loaded
            UserDefaults.standard.set(location.rawValue, forKey: Self.historyStoragePreferenceKey)
            logger.info("Moved stitch history to \(location.rawValue, privacy: .public).")
            return nil
        } catch {
            logger.error("Could not move stitch history to \(location.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    isolated deinit {
        processingTask?.cancel()
    }

    func importPhotos(_ results: [PHPickerResult]) {
        logger.info("Received photo selection with \(results.count) item(s) and Photos asset identifiers.")
        let pendingArchiveTask = prepareForIncomingSources()
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
        let pendingArchiveTask = prepareForIncomingSources()
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

        let pendingArchiveTask = prepareForIncomingSources()
        if pendingArchiveTask == nil {
            preparationStatus = "Finding nearby screenshots that fit together…"
        }

        let importer = automaticScreenshotImporter
        let builder = AutomaticScreenshotSequenceBuilder()
        processingTask = Task { [weak self] in
            await pendingArchiveTask?.value
            guard let owner = self, !Task.isCancelled else { return }
            guard owner.state != .failed else {
                owner.processingTask = nil
                return
            }
            owner.preparationStatus = "Finding nearby screenshots that fit together…"

            let (progressStream, progressContinuation) = AsyncStream<StitchProgress>.makeStream()
            let progressTask = Task { @MainActor [weak self] in
                for await progress in progressStream {
                    guard let self else { return }
                    preparationStatus = progress.stage == .registering
                        ? "Comparing nearby screenshots…"
                        : self.preparationStatus(for: progress)
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
                let selection = try await Task.detached(priority: .userInitiated) {
                    try await builder.select(from: candidates) { progress in
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
                resetResult(cancelCurrentTask: false)
                preparationStatus = nil
                state = .idle
                processingTask = nil
                logger.info(
                    "Automatically selected \(selection.sources.count) screenshot(s) from \(importedCandidates.count) recent candidate(s); sequence_score=\(selection.score, privacy: .public)."
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
        let stitchID = UUID()
        activeStitchID = stitchID
        state = .processing(StitchProgress(stage: .normalizing, completed: 0, total: selectedSources.count, message: "Preparing screenshots…"))

        processingTask = Task { [weak self] in
            do {
                guard let self else { return }
                let result = try await runStitching(sources: selectedSources, stitchID: stitchID)
                guard !Task.isCancelled, activeStitchID == stitchID else { return }
                let registrationMilliseconds = result.joins.reduce(0) { $0 + $1.diagnostics.elapsedMilliseconds }
                logger.info("Manual stitch completed successfully. Preview rendered at \(result.pixelSize.width)x\(result.pixelSize.height) pixels with \(result.joins.count) join(s); registration_ms=\(registrationMilliseconds, privacy: .public).")
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
        try await historyImageStore.prepareForExport(url)
        return url
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

    private func prepareForIncomingSources() -> Task<Void, Never>? {
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

    private func runStitching(sources selectedSources: [SourceImage], stitchID: UUID) async throws -> StitchPreview {
        let engine = engine
        let progressHandler: @Sendable (StitchProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.activeStitchID == stitchID else { return }
                guard case .processing = self.state else { return }
                self.state = .processing(progress)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            try await engine.stitch(sources: selectedSources, progress: progressHandler)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func resetResult(cancelCurrentTask: Bool = true) {
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
        if progress.total > 0, progress.completed >= progress.total {
            return "Putting the screenshots in the order you picked…"
        }
        if progress.completed.isMultiple(of: 2) {
            return "Waking up the screenshots…"
        }
        return "Making sure every pixel knows where it belongs…"
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
