import Foundation
import Observation
import PhotosUI
import _PhotosUI_SwiftUI
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
    var state: ProcessingState = .idle
    var errorMessage: String?
    var recoverySuggestion: String?
    var selectedJoinDiagnostics: JoinDiagnostics?
    var sourceCleanupState: SourceCleanupState = .hidden
    var sourceCleanupError: String?
    var preparationStatus: String?

    private let photosImporter = PhotosImageImporter()
    private let filesImporter = FileImageImporter()
    private let sourceDeletionService = SourceDeletionService()
    private let engine = StitchEngine()
    private var processingTask: Task<Void, Never>?
    /// Progress callbacks are delivered through main-actor tasks. This token
    /// prevents a callback from an older stitch from changing the state of a
    /// newer stitch, or from changing `.ready` back to `.processing(.complete)`
    /// after the result has been published.
    private var activeStitchID: UUID?
    private let logger = Logger(subsystem: "dev.iamshift.Continuo", category: "stitching")

    isolated deinit {
        processingTask?.cancel()
    }

    func importPhotos(_ items: [PhotosPickerItem]) {
        logger.info("Received photo selection with \(items.count) item(s).")
        processingTask?.cancel()
        activeStitchID = nil
        preview = nil
        errorMessage = nil
        recoverySuggestion = nil
        selectedJoinDiagnostics = nil
        sourceCleanupState = .hidden
        sourceCleanupError = nil
        preparationStatus = "Preparing screenshots for stitching…"
        state = .idle

        let importer = photosImporter
        processingTask = Task { [weak self] in
            do {
                let imported = try await importer.importItems(items) { [weak self] progress in
                    self?.preparationStatus = self?.preparationStatus(for: progress)
                }
                try Task.checkCancellation()

                guard let self else { return }
                appendSources(imported, cancelCurrentTask: false)
                logger.info("Imported \(imported.count) still image(s); waiting for the user to start stitching.")
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
        do {
            let imported = try filesImporter.importFiles(urls)
            appendSources(imported)
            logger.info("Imported \(imported.count) still image(s) from Files; waiting for the user to start stitching.")
        } catch {
            showError(error)
        }
    }

    func removeSources(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where sources.indices.contains(index) {
            sources.remove(at: index)
        }
        resetResult()
    }

    func removeSource(id: UUID) {
        sources.removeAll { $0.id == id }
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
        sources.removeAll()
        resetResult()
    }

    func stitch() {
        logger.info("Manual stitch requested for \(self.sources.count) source(s).")
        processingTask?.cancel()
        activeStitchID = nil
        preview = nil
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
                logger.info("Manual stitch completed successfully. Preview rendered at \(result.pixelSize.width)x\(result.pixelSize.height) pixels with \(result.joins.count) join(s).")
                activeStitchID = nil
                preview = result
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

    private func runStitching(sources selectedSources: [SourceImage], stitchID: UUID) async throws -> StitchPreview {
        let engine = engine
        let progressHandler: @Sendable (StitchProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.activeStitchID == stitchID else { return }
                guard case .processing = self.state else { return }
                self.state = .processing(progress)
            }
        }
        return try await engine.stitch(sources: selectedSources, progress: progressHandler)
    }

    private func resetResult(cancelCurrentTask: Bool = true) {
        if cancelCurrentTask {
            processingTask?.cancel()
            processingTask = nil
        }
        activeStitchID = nil
        preview = nil
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
                "\(prefix, privacy: .public): \(error.localizedDescription, privacy: .public) score=\(diagnostics.similarityScore, privacy: .public) overlap=\(diagnostics.overlapPercentage, privacy: .public) drift=\(diagnostics.crossAxisDrift, privacy: .public) translation=(\(diagnostics.translation.x, privacy: .public),\(diagnostics.translation.y, privacy: .public)) backend=\(diagnostics.backend.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
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
        default:
            state = .failed
            errorMessage = error.localizedDescription
            recoverySuggestion = "Check the selected sources and try again."
        }
    }
}
