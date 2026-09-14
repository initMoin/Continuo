import Foundation
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
   private enum ExportTarget {
      case current
      case history
   }

   @State private var viewModel = ContinuoViewModel(loadsHistoryInBackground: true)
   @State private var showingPhotosPicker = false
   @State private var showingFileImporter = false
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
   @State private var exportTarget: ExportTarget?
   @State private var historyExportID: UUID?
   @State private var exportError: String?
   @State private var isSavingToPhotos = false
   @State private var isPreparingHistoryAsset = false
   @State private var showingSaveConfirmation = false
   @State private var showingHistorySettings = false
   @State private var showingIntelligenceSettings = false
   @State private var showingAbout = false
   @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
   @State private var showingOnboarding = false
#if os(macOS)
   @State private var showingMacImportPopover = false
   @State private var showingMacMorePopover = false
#endif
   @State private var hasAppeared = false
   @State private var selectedPageIndex = 0
   @Environment(\.accessibilityReduceMotion) private var reduceMotion
   @Environment(\.horizontalSizeClass) private var horizontalSizeClass
   @Environment(\.colorScheme) private var colorScheme
   @Environment(\.scenePhase) private var scenePhase
   private let photosExporter = PhotosImageExporter()

   var body: some View {
        NavigationStack {
 #if os(macOS)
            VStack(spacing: 0) {
               macHeader
               styledPreviewDetail
            }
 #else
            iosContent
 #endif
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
      .sheet(isPresented: $showingPhotosPicker) {
         OrderedPhotosPicker { results in
            viewModel.importPhotos(results)
            showingPhotosPicker = false
         }
      }
      .sheet(isPresented: $showingHistorySettings) {
         HistorySettingsView(viewModel: viewModel)
      }
      .sheet(isPresented: $showingIntelligenceSettings) {
         IntelligenceSettingsView(viewModel: viewModel)
      }
      .sheet(isPresented: $showingOnboarding) {
         OnboardingView {
            hasCompletedOnboarding = true
            showingOnboarding = false
         }
         .interactiveDismissDisabled(true)
#if os(iOS)
            .presentationDetents([.large])
#endif
      }
        .sheet(isPresented: $showingAbout) {
            AboutView()
#if os(iOS)
                .presentationDetents([.large])
#endif
        }
        .task {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.42)) {
                    hasAppeared = true
                }
            }
            if !hasCompletedOnboarding {
                showingOnboarding = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            viewModel.refreshHistoryIfNeeded()
        }
        .sensoryFeedback(.success, trigger: viewModel.state == .ready)
        .sensoryFeedback(.warning, trigger: viewModel.sourceCleanupState == .deleting)
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
            if case .current? = exportTarget {
               viewModel.markSaveCompleted()
            } else if case .history? = exportTarget, let historyExportID {
               viewModel.consumeHistoryAsset(id: historyExportID)
            }
         case let .failure(error):
            exportError = error.localizedDescription
         }
         exportDocument = nil
         exportTarget = nil
         historyExportID = nil
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
   }

   private var styledPreviewDetail: some View {
      previewDetail
         .opacity(hasAppeared || reduceMotion ? 1 : 0)
         .offset(y: hasAppeared || reduceMotion ? 0 : -8)
         .fontDesign(.rounded)
#if os(iOS)
         .navigationTitle("")
         .navigationBarTitleDisplayMode(.inline)
#endif
   }

#if os(iOS)
   private var iosContent: some View {
      styledPreviewDetail
         .toolbar {
            ToolbarItem(placement: .principal) {
               appTitle
            }
            mainToolbar
         }
   }
#endif

#if os(macOS)
   private var macHeader: some View {
      HStack(spacing: 16) {
         appTitle
         Spacer(minLength: 20)
//         Button("Snap") {
//             if let window = NSApp.windows.first {
//                 window.setContentSize(NSSize(width: 2880, height: 1800))
//                 window.center()
//             }
//         }
         GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
               macImportAction
                  .glassEffect(.regular.interactive(), in: Circle())
               autoSelectButton
                  .glassEffect(.regular.interactive(), in: Circle())
               macMoreOptionsAction
                  .glassEffect(.regular.interactive(), in: Circle())
            }
         }
         .buttonStyle(.plain)
         .controlSize(.large)
         .foregroundStyle(colorScheme == .dark ? ContinuoDesign.wordmarkDark : ContinuoDesign.wordmarkLight)
      }
      .padding(.horizontal, ContinuoDesign.Layout.macHeaderHorizontalPadding)
      .padding(.vertical, 12)
      .overlay(alignment: .bottom) {
         Divider()
            .opacity(0.35)
      }
   }
#endif

#if os(macOS)
   private var macImportAction: some View {
      Button {
         showingMacImportPopover.toggle()
      } label: {
         Label("Add screenshots", systemImage: "photo.on.rectangle.angled")
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
      }
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .help("Add screenshots")
      .accessibilityLabel("Add screenshots")
      .accessibilityHint("Choose screenshots from Photos or Files")
      .disabled(isProcessing || isPreparing)
      .popover(
         isPresented: $showingMacImportPopover,
         attachmentAnchor: .rect(.bounds),
         arrowEdge: .bottom
      ) {
         MacActionPopover {
            MacActionRow(title: "Photos", systemImage: "photo.on.rectangle.angled") {
               showingMacImportPopover = false
               presentAfterMacPopoverDismissal {
                  showingPhotosPicker = true
               }
            }
            MacActionRow(title: "Files", systemImage: "folder") {
               showingMacImportPopover = false
               presentAfterMacPopoverDismissal {
                  showingFileImporter = true
               }
            }
         }
      }
   }

   private var macMoreOptionsAction: some View {
      Button {
         showingMacMorePopover.toggle()
      } label: {
         Image(systemName: "ellipsis.circle")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
      }
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .help("More options")
      .accessibilityLabel("More options")
      .accessibilityHint("Open history sync, intelligence, and app information")
      .disabled(isProcessing || isPreparing)
      .popover(
         isPresented: $showingMacMorePopover,
         attachmentAnchor: .rect(.bounds),
         arrowEdge: .bottom
      ) {
         MacActionPopover {
            MacActionRow(title: "History & Sync", systemImage: "icloud") {
               showingMacMorePopover = false
               presentAfterMacPopoverDismissal {
                  showingHistorySettings = true
               }
            }
            MacActionRow(title: "Intelligence", systemImage: "sparkles.rectangle.stack") {
               showingMacMorePopover = false
               presentAfterMacPopoverDismissal {
                  showingIntelligenceSettings = true
               }
            }
            MacActionRow(title: "About Continuo", systemImage: "info.circle") {
               showingMacMorePopover = false
               presentAfterMacPopoverDismissal {
                  showingAbout = true
               }
            }
         }
      }
   }
#endif

   private var appTitle: some View {
      Text("continuo")
         .font(
            ContinuoDesign.Typography.title(
               size: ContinuoDesign.Typography.titleSize(
                  isCompact: horizontalSizeClass == .regular
               )
            )
         )
         .foregroundStyle(colorScheme == .dark ? ContinuoDesign.wordmarkDark : ContinuoDesign.wordmarkLight)
   }

#if os(macOS)
   private func presentAfterMacPopoverDismissal(_ presentation: @escaping @MainActor () -> Void) {
      Task { @MainActor in
         try? await Task.sleep(for: .milliseconds(20))
         guard !Task.isCancelled else { return }
         presentation()
      }
   }
#endif

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
#if os(iOS)
      ToolbarItemGroup(placement: .topBarTrailing) {
         toolbarItems
      }
#else
      ToolbarItemGroup {
         toolbarItems
      }
#endif
   }

   @ViewBuilder
   private var toolbarItems: some View {
      addScreenshotsMenu
      autoSelectButton
      moreOptionsMenu
   }

   private var addScreenshotsMenu: some View {
      Menu {
         Button {
            showingPhotosPicker = true
         } label: {
            Label("Photos", systemImage: "photo.on.rectangle.angled")
         }

         Button {
            showingFileImporter = true
         } label: {
            Label("Files", systemImage: "folder")
         }
      } label: {
         Label("Add screenshots", systemImage: "photo.on.rectangle.angled")
            .labelStyle(.iconOnly)
      }
      .help("Add screenshots")
      .accessibilityLabel("Add screenshots")
      .accessibilityHint("Choose screenshots from Photos or Files")
      .disabled(isProcessing || isPreparing)
   }

   private var autoSelectButton: some View {
      Button {
         viewModel.autoSelectScreenshots()
      } label: {
         Label("Auto-select", systemImage: "wand.and.stars")
            .labelStyle(.iconOnly)
#if os(macOS)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
#endif
      }
#if os(macOS)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
#endif
      .help("Auto-select screenshots")
      .accessibilityHint("Find nearby Photos screenshots that appear to fit together")
      .disabled(isProcessing || isPreparing)
   }

   private var moreOptionsMenu: some View {
      Menu {
         Button {
            showingHistorySettings = true
         } label: {
            Label("History & Sync", systemImage: "icloud")
         }

         Button {
            showingIntelligenceSettings = true
         } label: {
            Label("Intelligence", systemImage: "sparkles.rectangle.stack")
         }

         Button {
            showingAbout = true
         } label: {
            Label("About Continuo", systemImage: "info.circle")
         }
      } label: {
         Image(systemName: "ellipsis.circle")
      }
      .help("More options")
      .accessibilityLabel("More options")
      .accessibilityHint("Open history sync, intelligence, and app information")
      .disabled(isProcessing || isPreparing)
   }

   private var previewDetail: some View {
      GeometryReader { viewport in
         let pageWidth = max(1, viewport.size.width)
         let pageHeight = max(1, viewport.size.height)

         ZStack {
            Group {
#if os(iOS)
            TabView(selection: $selectedPageIndex) {
               workflowPage
                  .frame(width: pageWidth, height: pageHeight, alignment: .top)
                  .tag(0)

               ForEach(Array(viewModel.completedStitches.enumerated()), id: \.element.id) { index, stitch in
                  HistoryPageView(
                     stitch: stitch,
                     isPreparingHistoryAsset: isPreparingHistoryAsset,
                     historyAssetPreparationProgress: viewModel.historyAssetPreparationProgress,
                     isSavingToPhotos: isSavingToPhotos,
                     onSaveToPhotos: { saveHistoryToPhotos(id: stitch.id) },
                     onSaveToFiles: { prepareHistoryExport(for: stitch) },
                     onDeleteHistory: { scope in
                        await viewModel.deleteHistoryStitch(id: stitch.id, scope: scope)
                     }
                  )
                     .frame(width: pageWidth, height: pageHeight, alignment: .top)
                     .tag(index + 1)
               }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
#else
            ScrollView(.horizontal) {
               LazyHStack(alignment: .top, spacing: 0) {
                  workflowPage
                     .frame(width: pageWidth, height: pageHeight, alignment: .top)

                  ForEach(viewModel.completedStitches) { stitch in
                     HistoryPageView(
                        stitch: stitch,
                        isPreparingHistoryAsset: isPreparingHistoryAsset,
                        historyAssetPreparationProgress: viewModel.historyAssetPreparationProgress,
                        isSavingToPhotos: isSavingToPhotos,
                        onSaveToPhotos: { saveHistoryToPhotos(id: stitch.id) },
                        onSaveToFiles: { prepareHistoryExport(for: stitch) },
                        onDeleteHistory: { scope in
                           await viewModel.deleteHistoryStitch(id: stitch.id, scope: scope)
                        }
                     )
                        .frame(width: pageWidth, height: pageHeight, alignment: .top)
                  }
               }
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
#endif
            }
            .onChange(of: viewModel.completedStitches.count) { _, count in
               selectedPageIndex = min(selectedPageIndex, count)
            }

         }
      }
   }

   private let stitchedOutputAnchor = "stitched-output"

   private var workflowPage: some View {
      ScrollViewReader { scrollProxy in
         ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: ContinuoDesign.Spacing.section) {
               if let preparationStatus = viewModel.preparationStatus {
                  preparationView(status: preparationStatus)
               }

               if shouldShowSourceStrip {
                  sourceStrip(
                     magicProgress: isMagicRevealing ? magicProgress : 0,
                     isLocked: isSourceInteractionLocked
                  )
                  .transition(.move(edge: .top).combined(with: .opacity))
               }

               if viewModel.sources.count >= 2 {
                  stitchDirectionPicker
                     .transition(.opacity.combined(with: .scale(scale: 0.98)))
               }

               if isPreparing {
                  EmptyView()
               } else if isProcessing {
                  processingView
               } else if let errorMessage = viewModel.errorMessage {
                  failureView(message: errorMessage)
               } else if let preview = viewModel.preview {
                  Color.clear
                     .frame(height: 1)
                     .id(stitchedOutputAnchor)
                  stitchedPreviewView(preview)
                     .transition(.opacity.combined(with: .scale(scale: 0.98)))
               } else if viewModel.sources.count >= 2 {
                  stitchActionView
               } else {
                  ContentUnavailableView(
                     "Select screenshots",
                     systemImage: "photo.on.rectangle.angled",
                     description: Text("Choose at least two still images from Photos or Files to begin.")
                  )
                  .frame(maxWidth: .infinity, minHeight: 300)
               }
            }
            .frame(maxWidth: ContinuoDesign.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, ContinuoDesign.Layout.pageHorizontalPadding)
            .padding(.top, ContinuoDesign.Layout.pageTopPadding)
            .padding(.bottom, ContinuoDesign.Layout.pageBottomPadding)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: viewModel.state)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: viewModel.sources.count)
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
   }

   private var shouldShowSourceStrip: Bool {
      !viewModel.sources.isEmpty && viewModel.sourceCleanupState != .deleted
   }

   private func preparationView(status: String) -> some View {
      HStack(spacing: 12) {
         ProgressView()
            .controlSize(.small)

         VStack(alignment: .leading, spacing: 3) {
            Text("Preparing screenshots for stitching…")
               .font(.subheadline.weight(.semibold))
            if status != "Preparing screenshots for stitching…" {
               Text(status)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .contentTransition(.opacity)
            }
         }

         Spacer(minLength: 0)
      }
      .padding(14)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ContinuoDesign.Radius.panel, style: .continuous))
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
         Text("Ready to stitch")
            .font(.headline)

         Text("Stitch the screenshots in the order shown above.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)

         Button {
            viewModel.stitch()
         } label: {
            Label("Stitch", systemImage: "wand.and.stars")
               .frame(minWidth: 140)
         }
         .buttonStyle(.borderedProminent)
         .controlSize(.large)
         .tint(ContinuoDesign.primaryAction)
         .accessibilityHint("Register adjacent screenshots and render the stitched preview")
      }
      .frame(maxWidth: .infinity, minHeight: 170)
      .padding(24)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ContinuoDesign.Radius.action, style: .continuous))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Ready to stitch the selected screenshots")
   }

   private var stitchDirectionPicker: some View {
      let direction = viewModel.stitchDirection
        return Button {
         let nextDirection: StitchDirection = direction == .vertical ? .horizontal : .vertical
         withAnimation(.snappy(duration: 0.35)) {
            viewModel.setStitchDirection(nextDirection)
        }
      } label: {
         Image(systemName: "distribute.vertical.fill")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: ContinuoDesign.Control.directionButton, height: ContinuoDesign.Control.directionButton)
            .rotationEffect(direction == .horizontal ? .degrees(90) : .zero)
            .animation(.easeInOut(duration: 0.28), value: direction)
      }
      .buttonStyle(.plain)
        .disabled(isPreparing || isProcessing)
        .sensoryFeedback(.selection, trigger: direction)
        .glassEffect(.regular, in: Circle())
      .accessibilityLabel("Stack direction: \(direction.title)")
      .accessibilityHint("Tap to switch between vertical and horizontal stacking")
      .help("Stack \(direction.title.lowercased())")
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
            ? "Order locked after stitching."
            : "Drag to reorder before stitching."
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
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .offset(sourceOffset(for: source.id))
                        .scaleEffect(draggedSourceID == source.id ? 1.04 : 1)
                        .shadow(
                           color: draggedSourceID == source.id ? ContinuoDesign.logoGreen.opacity(0.22) : .clear,
                           radius: draggedSourceID == source.id ? 14 : 0,
                           y: draggedSourceID == source.id ? 8 : 0
                        )
                        .animation(
                           reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.84),
                           value: dragInsertionIndex
                        )
                     }
                     .contentShape(Rectangle())
                     .zIndex(draggedSourceID == source.id ? 10 : 0)
                     .background {
                        GeometryReader { proxy in
                           if proxy.size.width > 0, proxy.size.height > 0 {
                              Color.clear.preference(
                                 key: SourceFramePreferenceKey.self,
                                 value: [source.id: proxy.frame(in: .named("sourceStrip"))]
                              )
                           } else {
                              Color.clear
                           }
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
         .frame(minHeight: 270)
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
      }
      .padding(16)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ContinuoDesign.Radius.panel, style: .continuous))
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
                  .tint(ContinuoDesign.destructive)
               }
            }

            Divider()

            Button("Clear all images", role: .destructive) {
               viewModel.clearSources()
            }
            .tint(ContinuoDesign.destructive)
         }
      } label: {
         Label("\(viewModel.sources.count) images selected", systemImage: "checkmark.circle")
            .font(.caption)
      }
      .accessibilityLabel("\(viewModel.sources.count) images selected")
      .accessibilityHint("Open the menu to deselect individual images or clear the selection")
      .tint(ContinuoDesign.primaryAction)
      .disabled(isLocked)
   }

   private func magicBeam(in size: CGSize) -> some View {
      let beamX = ((size.width + 72) * magicProgress) - 36
      return ZStack(alignment: .leading) {
         Capsule()
            .fill(
               LinearGradient(
                  colors: [.clear, ContinuoDesign.logoGreen.opacity(0.18), .white.opacity(0.78), ContinuoDesign.logoGreen.opacity(0.24), .clear],
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
                  colors: [ContinuoDesign.logoGreen.opacity(0.72), .white.opacity(0.54)],
                  startPoint: .leading,
                  endPoint: .trailing
               ),
               lineWidth: 2
            )
            .opacity(0.45 + (0.35 * sin(Double(magicProgress) * .pi)))
      }
   }

   private func screenshotDeviceShape(for size: CGSize) -> RoundedRectangle {
      let shortEdge = max(1, min(size.width, size.height))
      let cornerRadius = min(shortEdge / 2, max(10, shortEdge * 0.06))
      return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
   }

   private func framedScreenshot<Content: View>(
      size: CGSize,
      @ViewBuilder content: () -> Content
   ) -> some View {
      let deviceShape = screenshotDeviceShape(for: size)

      return content()
         .clipShape(deviceShape)
         .overlay {
            deviceShape
               .strokeBorder(Color.primary.opacity(0.30), lineWidth: 1)
         }
   }

   private func stitchedPreviewView(_ preview: StitchPreview) -> some View {
      let pixelWidth = max(CGFloat(1), CGFloat(preview.pixelSize.width))
      let pixelHeight = max(CGFloat(1), CGFloat(preview.pixelSize.height))
      let maximumDisplayWidth: CGFloat = horizontalSizeClass == .compact ? 350 : 760
      let maximumDisplayHeight: CGFloat = horizontalSizeClass == .compact ? 760 : 900
      let displayScale = min(
         1,
         maximumDisplayWidth / pixelWidth,
         maximumDisplayHeight / pixelHeight
      )
      let displayWidth = max(1, pixelWidth * displayScale)
      let displayHeight = max(1, pixelHeight * displayScale)

      return VStack(alignment: .center, spacing: 12) {
         HStack {
            Text("Stitched result")
               .font(.headline)
            Spacer()
            Text("\(preview.pixelSize.width) × \(preview.pixelSize.height) px")
               .font(ContinuoDesign.Typography.metadata())
               .fontDesign(.monospaced)
               .foregroundStyle(.secondary)
         }

         ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
               .fill(ContinuoDesign.logoGreen.opacity(0.08))
               .frame(width: displayWidth + 20, height: displayHeight + 20)
               .blur(radius: 18)

            Circle()
               .fill(.white.opacity(isMagicRevealing ? 0.76 : 0))
               .frame(width: 10, height: 10)
               .shadow(color: ContinuoDesign.logoGreen.opacity(0.55), radius: 8)
               .offset(x: (displayWidth / 2) + 20)
               .opacity(isMagicRevealing ? 0.8 : 0)

            framedScreenshot(size: CGSize(width: displayWidth, height: displayHeight)) {
               Image(preview.image, scale: 1, orientation: .up, label: Text("Stitched screenshot preview"))
                  .resizable()
                  .interpolation(.high)
                  .frame(width: displayWidth, height: displayHeight)
                  .accessibilityLabel("Stitched result, \(preview.pixelSize.width) by \(preview.pixelSize.height) pixels")
            }
         }
         .padding(.vertical, 8)
         .frame(maxWidth: .infinity, alignment: .center)

         HStack {
            Button {
               showingSaveOptions = true
               exportTarget = .current
            } label: {
               Image(systemName: "arrow.down.circle.fill")
                  .font(.system(size: 28, weight: .semibold))
                  .frame(width: ContinuoDesign.Control.shareButton, height: ContinuoDesign.Control.shareButton)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ContinuoDesign.primaryAction)
            .disabled(isSavingToPhotos)
            .accessibilityLabel("Save stitched image")
            .accessibilityHint("Choose Photos or Files for the full-resolution stitched image")
            .help("Save stitched image")

            if isSavingToPhotos {
               ProgressView()
                  .controlSize(.small)
            }

            Spacer()
         }

         sourceCleanupView
      }
      .confirmationDialog(
         "Save stitched image",
         isPresented: $showingSaveOptions,
         titleVisibility: .visible
      ) {
         Button("Save to Photos") {
            saveToPhotos(preview.image, target: .current)
         }
         Button("Save to Files") {
            prepareExport(for: preview.image, target: .current)
         }
         Button("Cancel", role: .cancel) {}
      } message: {
         Text("Choose where to save the full-resolution PNG.")
      }
   }

   @ViewBuilder
   private var sourceCleanupView: some View {
      switch viewModel.sourceCleanupState {
      case .hidden:
         EmptyView()
      case .available:
         VStack(alignment: .leading, spacing: 10) {
            Text("Saved. You can remove the original selected images or reset this workflow.")
               .font(.caption)
               .foregroundStyle(.secondary)

            HStack(spacing: 12) {
               Button {
                  Task { await viewModel.deleteSelectedSources() }
               } label: {
                  Label("Delete " + selectedSourceLabel, systemImage: "trash")
               }
               .buttonStyle(ContinuoDestructiveButtonStyle())

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
            Label("Original images deleted.", systemImage: "checkmark.circle.fill")
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
      withAnimation(.easeInOut(duration: 0.45)) {
         viewModel.resetActiveWorkflow()
      }
      draggedSourceID = nil
      dragTranslation = .zero
      dragInsertionIndex = nil
   }

   private func prepareExport(for image: CGImage, target: ExportTarget) {
      do {
         exportDocument = try StitchedImageDocument(image: image)
         exportTarget = target
         historyExportID = nil
         showingExport = true
      } catch {
         exportError = error.localizedDescription
      }
   }

   private func prepareHistoryExport(for stitch: CompletedStitch) {
      guard !isPreparingHistoryAsset else { return }
      isPreparingHistoryAsset = true

      Task { @MainActor in
         defer {
            isPreparingHistoryAsset = false
            viewModel.clearHistoryAssetPreparation(id: stitch.id)
         }
         do {
            let fileURL = try await viewModel.historyExportURL(for: stitch.id)
            exportDocument = try StitchedImageDocument(fileURL: fileURL)
            exportTarget = .history
            historyExportID = stitch.id
            showingExport = true
         } catch {
            exportError = error.localizedDescription
         }
      }
   }

   private func saveToPhotos(_ image: CGImage, target: ExportTarget) {
      guard !isSavingToPhotos else { return }
      isSavingToPhotos = true

      Task { @MainActor in
         do {
            try await photosExporter.save(image)
            isSavingToPhotos = false
            if case .current = target {
               viewModel.markSaveCompleted()
            }
            showingSaveConfirmation = true
         } catch {
            isSavingToPhotos = false
            exportError = error.localizedDescription
         }
      }
   }

   private func saveHistoryToPhotos(id: UUID) {
      guard !isSavingToPhotos, !isPreparingHistoryAsset else { return }
      isPreparingHistoryAsset = true
      Task { @MainActor in
         do {
            let fileURL = try await viewModel.historyExportURL(for: id)
            isPreparingHistoryAsset = false
            viewModel.clearHistoryAssetPreparation(id: id)
            isSavingToPhotos = true
            try await photosExporter.save(fileURL: fileURL)
            viewModel.consumeHistoryAsset(id: id)
            isSavingToPhotos = false
            showingSaveConfirmation = true
         } catch {
            isPreparingHistoryAsset = false
            viewModel.clearHistoryAssetPreparation(id: id)
            isSavingToPhotos = false
            exportError = error.localizedDescription
         }
      }
   }

   private var processingView: some View {
      VStack(spacing: 16) {
         if case let .processing(progress) = viewModel.state {
            Image(systemName: progressIcon(for: progress.stage))
               .font(.system(size: 28, weight: .semibold))
               .symbolRenderingMode(.hierarchical)
               .foregroundStyle(ContinuoDesign.logoGreen)

            Text(progress.stageTitle)
               .font(.headline)

            Text(progress.message)
               .font(.subheadline)
               .foregroundStyle(.secondary)
               .multilineTextAlignment(.center)
               .frame(maxWidth: 420)
         }

         ProgressView()
            .tint(ContinuoDesign.logoGreen)
         SmoothProgressBar(
            progress: displayedProcessingProgress,
            reduceMotion: reduceMotion
         )
         .frame(maxWidth: 320)

         Text("Full-resolution source pixels are being preserved for registration.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

         Button("Cancel", role: .cancel) {
            viewModel.cancelProcessing()
         }
         .buttonStyle(.bordered)
         .tint(colorScheme == .dark ? ContinuoDesign.wordmarkDark : ContinuoDesign.wordmarkLight)
      }
      .padding(24)
      .frame(maxWidth: 520, minHeight: 320)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ContinuoDesign.Radius.overlay, style: .continuous))
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Continuo is processing the selected screenshots")
   }

   private func failureView(message: String) -> some View {
      VStack(spacing: 12) {
         Image(systemName: viewModel.state == .needsReview ? "exclamationmark.triangle" : "xmark.circle")
            .font(.system(size: 36))
            .foregroundStyle(viewModel.state == .needsReview ? .orange : ContinuoDesign.destructive)
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
            .font(ContinuoDesign.Typography.metadata())
            .fontDesign(.monospaced)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Join diagnostics: similarity \(diagnostics.similarityScore), overlap \(Int(diagnostics.overlapPercentage * 100)) percent")
         }
         HStack(spacing: 12) {
            if viewModel.sources.count >= 2, viewModel.state != .cancelled {
               Button("Try Again") {
                  viewModel.stitch()
               }
               .buttonStyle(.borderedProminent)
               .tint(ContinuoDesign.primaryAction)
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
      withAnimation(.easeInOut(duration: 1.15)) {
         magicProgress = 1
      }

      revealTask = Task { @MainActor in
         do {
            try await Task.sleep(nanoseconds: 1_300_000_000)
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

#if os(macOS)
private struct MacActionPopover<Content: View>: View {
   private let content: Content

   init(@ViewBuilder content: () -> Content) {
      self.content = content()
   }

   var body: some View {
      GlassEffectContainer(spacing: 8) {
         VStack(spacing: 8) {
            content
         }
      }
      .padding(10)
      .frame(minWidth: 220)
      .presentationBackground(.clear)
   }
}

private struct MacActionRow: View {
   let title: String
   let systemImage: String
   let action: () -> Void

   var body: some View {
      Button(action: action) {
         Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
   }
}
#endif

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
