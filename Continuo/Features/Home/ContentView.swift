import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import _PhotosUI_SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = ContinuoViewModel()
    @State private var showingPhotosPicker = false
    @State private var showingFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var draggedSourceID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragInsertionIndex: Int?
    @State private var sourceFrames: [UUID: CGRect] = [:]
    @State private var sourceContainerFrame: CGRect = .zero
    @State private var isMagicRevealing = false
    @State private var magicProgress: CGFloat = 0
    @State private var revealTask: Task<Void, Never>?
    @State private var displayedProcessingProgress: Double = 0
    @State private var exportDocument: StitchedImageDocument?
    @State private var showingExport = false
    @State private var showingSaveOptions = false
    @State private var exportError: String?
    @State private var isSavingToPhotos = false
    @State private var showingSaveConfirmation = false
    @State private var showingDeleteConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let photosExporter = PhotosImageExporter()

    var body: some View {
        NavigationStack {
            previewDetail
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            showingPhotosPicker = true
                        } label: {
                            Label("Photos", systemImage: "photo.on.rectangle.angled")
                        }
                        .accessibilityHint("Select screenshots from Photos")
                        .disabled(isProcessing || isPreparing)

                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Files", systemImage: "folder")
                        }
                        .accessibilityHint("Select image files")
                        .disabled(isProcessing || isPreparing)
                    }
                }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                viewModel.importFiles(urls)
            case let .failure(error):
                viewModel.errorMessage = error.localizedDescription
                viewModel.recoverySuggestion = "Choose another image or try the import again."
                viewModel.state = .failed
            }
        }
        .photosPicker(
            isPresented: $showingPhotosPicker,
            selection: $photoItems,
            maxSelectionCount: 50,
            selectionBehavior: .ordered,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            viewModel.importPhotos(items)
        }
        .onChange(of: showingPhotosPicker) { _, isPresented in
            guard !isPresented else { return }
            // Let PhotosPicker finish dismissing before clearing its binding.
            // Mutating the selection while the picker plugin is still active
            // can interrupt the picker connection on iOS.
            photoItems.removeAll()
        }
        .onDisappear {
            revealTask?.cancel()
        }
        .fileExporter(
            isPresented: $showingExport,
            document: exportDocument,
            contentType: .png,
            defaultFilename: "Continuo-Stitched"
        ) { result in
            switch result {
            case .success:
                viewModel.markSaveCompleted()
            case let .failure(error):
                exportError = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert(
            "Couldn’t save stitched image",
            isPresented: Binding(
                get: { exportError != nil },
                set: { isPresented in
                    if !isPresented { exportError = nil }
                }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                Text(exportError ?? "Continuo could not create the PNG export.")
            }
        )
        .alert("Saved to Photos", isPresented: $showingSaveConfirmation) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("The full-resolution stitched PNG is now in your Photos library.")
        }
        .confirmationDialog(
            "Delete selected source images?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteSelectedSources() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the original selected images from their source locations. The stitched output will not be deleted.")
        }
    }

    private var previewDetail: some View {
        ZStack {
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        pageHeader

                        if let preparationStatus = viewModel.preparationStatus {
                            preparationView(status: preparationStatus)
                        }

                        if !viewModel.sources.isEmpty {
                            sourceStrip(
                                magicProgress: isMagicRevealing ? magicProgress : 0,
                                isLocked: isSourceInteractionLocked
                            )
                        }

                        if isPreparing {
                            EmptyView()
                        } else if isProcessing {
                            processingView
                        } else if let errorMessage = viewModel.errorMessage {
                            failureView(message: errorMessage)
                        } else if let preview = viewModel.preview {
                            stitchedPreviewView(preview)
                                .id(stitchedOutputAnchor)
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        } else if viewModel.sources.count >= 2 {
                            stitchActionView
                        } else {
                            ContentUnavailableView(
                                "Select another screenshot",
                                systemImage: "photo.on.rectangle.angled",
                                description: Text("Continuo keeps the selection order. Once at least two still images are imported, you can start stitching.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 300)
                        }
                    }
                    .frame(maxWidth: 960, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 48)
                }
                .scrollIndicators(.hidden)
                .onChange(of: viewModel.state) { _, state in
                    if case let .processing(progress) = state {
                        stopMagicReveal()
                        updateProcessingProgress(progress)
                    } else if case .ready = state, viewModel.preview != nil {
                        startMagicReveal()
                        Task { @MainActor in
                            await Task.yield()
                            withAnimation(.easeInOut(duration: 0.65)) {
                                scrollProxy.scrollTo(stitchedOutputAnchor, anchor: .top)
                            }
                        }
                    }
                }
            }

            if case let .processing(progress) = viewModel.state {
                stitchingProgressOverlay(progress)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .navigationTitle("Continuo")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private let stitchedOutputAnchor = "stitched-output"

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("New stitch", systemImage: "rectangle.stack.badge.plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)

            Text("From fragments to the full view.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))

            Text("Select screenshots in order, adjust the sequence if needed, then let Continuo find the shared edges.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preparationView(status: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                Text("Preparing screenshots for stitching…")
                    .font(.subheadline.weight(.semibold))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing screenshots for stitching. (status)")
    }

    private var isProcessing: Bool {
        if case .processing = viewModel.state { return true }
        return false
    }

    private var isPreparing: Bool {
        viewModel.preparationStatus != nil
    }

    private var isSourceInteractionLocked: Bool {
        isPreparing || isProcessing || viewModel.preview != nil
    }

    private var stitchActionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)

            Text("Ready to stitch")
                .font(.headline)

            Text("The screenshots above will be registered in the order you selected them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Button {
                viewModel.stitch()
            } label: {
                Label("Stitch Screenshots", systemImage: "rectangle.stack.badge.plus")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Register adjacent screenshots and render the stitched preview")
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ready to stitch the selected screenshots")
    }

    private func sourceStrip(magicProgress: CGFloat, isLocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Selected screenshots", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                selectionMenu(isLocked: isLocked)
            }

            Text(
                isLocked
                    ? "Order locked while the stitched result is shown."
                    : "Drag screenshots to adjust their stitching order."
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(viewModel.sources.enumerated()), id: \.element.id) { index, source in
                            ZStack(alignment: .topLeading) {
                                ScreenshotThumbnail(
                                    source: source,
                                    index: index,
                                    magicProgress: magicProgress
                                )
                                .offset(sourceOffset(for: source.id))
                                .scaleEffect(draggedSourceID == source.id ? 1.04 : 1)
                                .rotation3DEffect(
                                    .degrees(draggedSourceID == source.id ? 0 : adjacentDragRotation(for: source.id)),
                                    axis: (x: 0, y: 1, z: 0),
                                    perspective: 0.35
                                )
                                .shadow(
                                    color: draggedSourceID == source.id ? .black.opacity(0.28) : .clear,
                                    radius: 18,
                                    y: 10
                                )
                                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.82), value: dragInsertionIndex)
                            }
                            .contentShape(Rectangle())
                            .zIndex(draggedSourceID == source.id ? 10 : 0)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: SourceFramePreferenceKey.self,
                                        value: [source.id: proxy.frame(in: .named("sourceStrip"))]
                                    )
                                }
                            }
                            .highPriorityGesture(sourceDragGesture(for: source))
                            .accessibilityHint(
                                isLocked
                                    ? "Screenshot order is locked while the stitched result is shown"
                                    : "Drag this screenshot to change its position"
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .scrollDisabled(draggedSourceID != nil || isLocked)
                .allowsHitTesting(!isLocked)
            }
            .coordinateSpace(name: "sourceStrip")
            .onPreferenceChange(SourceFramePreferenceKey.self) { frames in
                sourceFrames = frames
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SourceContainerFramePreferenceKey.self,
                        value: CGRect(origin: .zero, size: proxy.size)
                    )
                }
            }
            .onPreferenceChange(SourceContainerFramePreferenceKey.self) { frame in
                sourceContainerFrame = frame
            }
            .frame(minHeight: 270)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if isMagicRevealing {
                GeometryReader { proxy in
                    magicBeam(in: proxy.size)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected screenshots in order")
        .accessibilityHint(isLocked ? "Screenshot order is locked while the stitched result is shown" : "Drag to change the screenshot order")
    }

    private func sourceDragGesture(for source: SourceImage) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("sourceStrip"))
            .onChanged { value in
                if draggedSourceID == nil {
                    draggedSourceID = source.id
                }
                guard draggedSourceID == source.id else { return }
                let boundedTranslation = boundedDragTranslation(
                    for: source.id,
                    translation: value.translation
                )
                dragTranslation = boundedTranslation

                if let frame = sourceFrames[source.id] {
                    let draggedCenterX = frame.midX + boundedTranslation.width
                    dragInsertionIndex = insertionIndex(
                        for: source.id,
                        centerX: draggedCenterX
                    )
                }
            }
            .onEnded { _ in
                guard draggedSourceID == source.id else { return }
                finishSourceDrag(sourceID: source.id)
            }
    }

    private func finishSourceDrag(sourceID: UUID) {
        let targetIndex = dragInsertionIndex ?? {
            guard let frame = sourceFrames[sourceID] else { return 0 }
            return insertionIndex(for: sourceID, centerX: frame.midX + dragTranslation.width)
        }()

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            viewModel.moveSource(id: sourceID, toIndex: targetIndex)
            draggedSourceID = nil
            dragTranslation = .zero
            dragInsertionIndex = nil
        }
    }

    private func sourceOffset(for sourceID: UUID) -> CGSize {
        if draggedSourceID == sourceID {
            return dragTranslation
        }
        return CGSize(width: adjacentDragOffset(for: sourceID), height: 0)
    }

    private func orderedSourceIDs() -> [UUID] {
        sourceFrames
            .sorted { $0.value.minX < $1.value.minX }
            .map(\.key)
    }

    private func insertionIndex(for sourceID: UUID, centerX: CGFloat) -> Int {
        let remainingIDs = orderedSourceIDs().filter { $0 != sourceID }
        return remainingIDs.firstIndex { id in
            guard let frame = sourceFrames[id] else { return false }
            return centerX < frame.midX
        } ?? remainingIDs.count
    }

    private func adjacentDragOffset(for sourceID: UUID) -> CGFloat {
        guard
            let draggedID = draggedSourceID,
            draggedID != sourceID,
            let insertionIndex = dragInsertionIndex
        else {
            return 0
        }

        let orderedIDs = orderedSourceIDs()
        guard
            let originalIndex = orderedIDs.firstIndex(of: draggedID),
            let currentIndex = orderedIDs.filter({ $0 != draggedID }).firstIndex(of: sourceID),
            let frame = sourceFrames[sourceID]
        else {
            return 0
        }

        let stride = frame.width + 12
        if insertionIndex > originalIndex,
           currentIndex >= originalIndex,
           currentIndex < insertionIndex {
            return -stride
        }
        if insertionIndex < originalIndex,
           currentIndex >= insertionIndex,
           currentIndex < originalIndex {
            return stride
        }
        return 0
    }

    private func adjacentDragRotation(for sourceID: UUID) -> Double {
        let offset = adjacentDragOffset(for: sourceID)
        if offset < 0 { return 3.5 }
        if offset > 0 { return -3.5 }
        return 0
    }

    private func boundedDragTranslation(for sourceID: UUID, translation: CGSize) -> CGSize {
        guard
            let frame = sourceFrames[sourceID],
            sourceContainerFrame.width > 0,
            sourceContainerFrame.height > 0
        else {
            return translation
        }

        let minimumX = sourceContainerFrame.minX - frame.minX
        let maximumX = sourceContainerFrame.maxX - frame.maxX
        let minimumY = sourceContainerFrame.minY - frame.minY
        let maximumY = sourceContainerFrame.maxY - frame.maxY

        return CGSize(
            width: min(max(translation.width, minimumX), maximumX),
            height: min(max(translation.height, minimumY), maximumY)
        )
    }

    private func selectionMenu(isLocked: Bool) -> some View {
        Menu {
            if viewModel.sources.isEmpty {
                Text("No images selected")
            } else {
                Section("Selection order") {
                    ForEach(Array(viewModel.sources.enumerated()), id: \.element.id) { index, source in
                        Button(role: .destructive) {
                            viewModel.removeSource(id: source.id)
                        } label: {
                            Label(
                                "Deselect image \(index + 1)",
                                systemImage: "minus.circle"
                            )
                        }
                    }
                }

                Divider()

                Button("Clear all images", role: .destructive) {
                    viewModel.clearSources()
                }
            }
        } label: {
            Label("\(viewModel.sources.count) images selected", systemImage: "checkmark.circle")
                .font(.caption)
        }
        .accessibilityLabel("\(viewModel.sources.count) images selected")
        .accessibilityHint("Open the menu to deselect individual images or clear the selection")
        .disabled(isLocked)
    }

    private func magicBeam(in size: CGSize) -> some View {
        let beamX = ((size.width + 72) * magicProgress) - 36
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.clear, .cyan.opacity(0.2), .white.opacity(0.95), .purple.opacity(0.3), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 72, height: max(80, size.height * 0.84))
                .blur(radius: 5)
                .offset(x: beamX, y: size.height * 0.08)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.cyan.opacity(0.8), .purple.opacity(0.75)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 2
                )
                .opacity(0.45 + (0.35 * sin(Double(magicProgress) * .pi)))
        }
    }

    private func stitchedPreviewView(_ preview: StitchPreview) -> some View {
        let pixelWidth = max(CGFloat(1), CGFloat(preview.pixelSize.width))
        let pixelHeight = max(CGFloat(1), CGFloat(preview.pixelSize.height))
        let maximumDisplayWidth: CGFloat = horizontalSizeClass == .compact ? 340 : 520
        let maximumDisplayHeight: CGFloat = 680
        let displayScale = min(
            1,
            maximumDisplayWidth / pixelWidth,
            maximumDisplayHeight / pixelHeight
        )
        let displayWidth = max(1, pixelWidth * displayScale)
        let displayHeight = max(1, pixelHeight * displayScale)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Halo output", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("\(preview.pixelSize.width) × \(preview.pixelSize.height) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        AngularGradient(
                            colors: [.cyan.opacity(0.85), .blue.opacity(0.35), .purple.opacity(0.85), .pink.opacity(0.35), .cyan.opacity(0.85)],
                            center: .center
                        )
                    )
                    .blur(radius: 24)
                    .opacity(0.8)
                    .padding(18)

                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .blue.opacity(0.35), .purple, .pink.opacity(0.35), .cyan],
                            center: .center
                        ),
                        lineWidth: isMagicRevealing ? 3 : 1
                    )
                    .padding(5)
                    .rotationEffect(.degrees(Double(magicProgress) * 360))
                    .opacity(isMagicRevealing ? 0.95 : 0.18)
                    .blur(radius: isMagicRevealing ? 0 : 1)

                Circle()
                    .fill(.white.opacity(isMagicRevealing ? 0.95 : 0))
                    .frame(width: 10, height: 10)
                    .shadow(color: .cyan.opacity(0.9), radius: 8)
                    .offset(x: (displayWidth / 2) + 20)
                    .rotationEffect(.degrees(Double(magicProgress) * 360))

                Image(preview.image, scale: 1, orientation: .up, label: Text("Stitched screenshot preview"))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayWidth, height: displayHeight)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .purple.opacity(0.35), radius: 18)
                    .accessibilityLabel("Stitched halo output, \(preview.pixelSize.width) by \(preview.pixelSize.height) pixels")
            }
            .padding(.vertical, 8)

            HStack {
                Button {
                    showingSaveOptions = true
                } label: {
                    Label(
                        isSavingToPhotos ? "Saving…" : "Save",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingToPhotos)
                .accessibilityHint("Choose Photos or Files for the full-resolution stitched image")
                .popover(
                    isPresented: $showingSaveOptions,
                    attachmentAnchor: .point(UnitPoint(x: 0.35, y: 0)),
                    arrowEdge: .bottom
                ) {
                    saveOptionsPopover(for: preview)
                        .presentationCompactAdaptation(.popover)
                }

                if isSavingToPhotos {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            sourceCleanupView
        }
    }

    @ViewBuilder
    private var sourceCleanupView: some View {
        switch viewModel.sourceCleanupState {
        case .hidden:
            EmptyView()
        case .available:
            VStack(alignment: .leading, spacing: 10) {
                Text("The stitched image is saved. You can now remove the original selected images from their source locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete " + selectedSourceLabel, systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    resetSelectionButton
                }
            }
            .padding(.top, 4)
        case .deleting:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Deleting selected source images…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        case .deleted:
            VStack(alignment: .leading, spacing: 10) {
                Label("Original selected images deleted.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                resetSelectionButton
            }
            .padding(.top, 4)
        case .resetOnly:
            VStack(alignment: .leading, spacing: 10) {
                if let sourceCleanupError = viewModel.sourceCleanupError {
                    Label(sourceCleanupError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Your stitched image is safe. You can reset the selected sources without deleting them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                resetSelectionButton
            }
            .padding(.top, 4)
        }
    }

    private var resetSelectionButton: some View {
        Button("Reset Selection", systemImage: "arrow.counterclockwise") {
            resetSelection()
        }
        .buttonStyle(.bordered)
    }

    private var selectedSourceLabel: String {
        let origins = Set(viewModel.sources.map(\.sourceOrigin))
        if origins == [.photos] {
            return "Photos images"
        }
        if origins == [.files] {
            return "Files images"
        }
        if origins == [.photos, .files] {
            return "Photos and Files images"
        }
        return "source images"
    }

    private func resetSelection() {
        viewModel.clearSources()
        photoItems.removeAll()
        draggedSourceID = nil
        dragTranslation = .zero
        dragInsertionIndex = nil
    }

    private func saveOptionsPopover(for preview: StitchPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save stitched image")
                .font(.headline)

            Text("Choose where to save the full-resolution PNG.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                saveDestinationButton(
                    title: "Photos",
                    systemImage: "photo",
                    color: .blue
                ) {
                    showingSaveOptions = false
                    saveToPhotos(preview)
                }

                saveDestinationButton(
                    title: "Files",
                    systemImage: "folder",
                    color: .orange
                ) {
                    showingSaveOptions = false
                    prepareExport(for: preview)
                }
            }
        }
        .padding(18)
        .frame(width: 250)
    }

    private func saveDestinationButton(
        title: String,
        systemImage: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(color)
            .frame(width: 78, height: 78)
            .background(
                Circle()
                    .fill(color.opacity(0.16))
            )
            .overlay {
                Circle()
                    .stroke(color.opacity(0.32), lineWidth: 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save to \(title)")
    }

    private func prepareExport(for preview: StitchPreview) {
        do {
            exportDocument = try StitchedImageDocument(image: preview.image)
            showingExport = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func saveToPhotos(_ preview: StitchPreview) {
        guard !isSavingToPhotos else { return }
        isSavingToPhotos = true

        Task { @MainActor in
            do {
                try await photosExporter.save(preview.image)
                isSavingToPhotos = false
                viewModel.markSaveCompleted()
                showingSaveConfirmation = true
            } catch {
                isSavingToPhotos = false
                exportError = error.localizedDescription
            }
        }
    }

    private var processingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            if case let .processing(progress) = viewModel.state {
                SmoothProgressBar(
                    progress: displayedProcessingProgress,
                    reduceMotion: reduceMotion
                )
                    .frame(maxWidth: 320)
                Text(progress.message)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(progress.message)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.state == .needsReview ? "exclamationmark.triangle" : "xmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(viewModel.state == .needsReview ? .orange : .red)
            Text(viewModel.state == .needsReview ? "Needs review" : (viewModel.state == .cancelled ? "Processing cancelled" : "Could not create preview"))
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            if let suggestion = viewModel.recoverySuggestion, !suggestion.isEmpty {
                Text(suggestion)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            if let diagnostics = viewModel.selectedJoinDiagnostics {
                Label(
                    "Similarity \(diagnostics.similarityScore, format: .number.precision(.fractionLength(2))) · overlap \(Int(diagnostics.overlapPercentage * 100))%",
                    systemImage: "waveform.path.ecg"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Join diagnostics: similarity \(diagnostics.similarityScore), overlap \(Int(diagnostics.overlapPercentage * 100)) percent")
            }
            HStack(spacing: 12) {
                if viewModel.sources.count >= 2, viewModel.state != .cancelled {
                    Button("Try Again") {
                        viewModel.stitch()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Dismiss") {
                    viewModel.dismissError()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 300)
        .accessibilityElement(children: .combine)
    }

    private func stitchingProgressOverlay(_ progress: StitchProgress) -> some View {
        ZStack {
            Color.black.opacity(0.44)

            VStack(spacing: 18) {
                Image(systemName: progressIcon(for: progress.stage))
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)

                VStack(spacing: 5) {
                    Text(progress.stageTitle)
                        .font(.headline)
                    Text(progress.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                SmoothProgressBar(
                    progress: displayedProcessingProgress,
                    reduceMotion: reduceMotion
                )
                    .frame(maxWidth: 360)

                Text("Full-resolution source pixels are being preserved for registration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button("Cancel", role: .cancel) {
                    viewModel.cancelProcessing()
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 28)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Continuo is processing the selected screenshots")
        .accessibilityValue("\(progress.stageTitle). \(progress.message)")
    }

    private func updateProcessingProgress(_ progress: StitchProgress) {
        if progress.stage == .normalizing, progress.completed == 0 {
            displayedProcessingProgress = 0
            return
        }

        let target = max(displayedProcessingProgress, progress.overallFraction)
        let distance = abs(target - displayedProcessingProgress)
        let duration = min(1.6, max(0.55, 0.45 + (distance * 2.8)))
        withAnimation(.easeInOut(duration: duration)) {
            displayedProcessingProgress = target
        }
    }

    private func progressIcon(for stage: StitchProgress.Stage) -> String {
        switch stage {
        case .importing: "arrow.down.circle"
        case .normalizing: "photo"
        case .registering: "arrow.up.and.down"
        case .rendering: "sparkles"
        case .complete: "checkmark.circle"
        }
    }

    private func startMagicReveal() {
        revealTask?.cancel()

        guard !reduceMotion else {
            isMagicRevealing = false
            magicProgress = 1
            return
        }

        isMagicRevealing = true
        magicProgress = 0
        withAnimation(.easeInOut(duration: 1.45)) {
            magicProgress = 1
        }

        revealTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_650_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                isMagicRevealing = false
            }
            revealTask = nil
        }
    }

    private func stopMagicReveal() {
        revealTask?.cancel()
        revealTask = nil
        isMagicRevealing = false
        magicProgress = 0
    }
}

private struct SmoothProgressBar: View {
    let progress: Double
    let reduceMotion: Bool
    @State private var shimmerPhase: CGFloat = -0.25

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = min(1, max(0, progress))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * clampedProgress)

                if !reduceMotion {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.72), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 76)
                        .offset(x: ((proxy.size.width + 76) * shimmerPhase) - 76)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .animation(.easeInOut(duration: 0.8), value: progress)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }
}

private struct ScreenshotThumbnail: View {
    let source: SourceImage
    let index: Int
    let magicProgress: CGFloat
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(5)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading screenshot…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Text("\(index + 1)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(7)
            }
            .frame(width: 148, height: 232)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .scaleEffect(1 - (0.025 * magicProgress))
            .offset(y: -CGFloat(index % 2) * 3 * magicProgress)

            Text("Screenshot \(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Screenshot \(index + 1), selected in position \(index + 1)")
        .task(id: source.localURL) {
            thumbnail = makeThumbnail()
        }
    }

    private func makeThumbnail() -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(source.localURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return cgImage
    }
}

private struct SourceFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SourceContainerFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

#Preview {
    ContentView()
}
