import CoreGraphics
import SwiftUI

struct HistoryPageView: View {
   let stitch: CompletedStitch
   let isPreparingHistoryAsset: Bool
   let historyAssetPreparationProgress: HistoryAssetPreparationProgress?
   let isSavingToPhotos: Bool
   let onSaveToPhotos: () -> Void
   let onSaveToFiles: () -> Void
   let onDeleteHistory: (HistoryDeletionScope) async -> String?
   @Environment(\.horizontalSizeClass) private var horizontalSizeClass
   @State private var showingDeleteHistoryConfirmation = false
   @State private var isDeletingHistory = false
   @State private var deleteHistoryError: String?

   var body: some View {
      ScrollView(.vertical) {
         VStack(alignment: .center, spacing: 16) {
            historyCard
         }
         .frame(maxWidth: ContinuoDesign.Layout.contentMaximumWidth, alignment: .center)
         .padding(.horizontal, ContinuoDesign.Layout.pageHorizontalPadding)
         .padding(.top, ContinuoDesign.Layout.historyTopPadding)
         .padding(.bottom, ContinuoDesign.Layout.pageBottomPadding)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .scrollIndicators(.hidden)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Saved stitched image history item")
      .confirmationDialog(
         "Delete this stitch from history?",
         isPresented: $showingDeleteHistoryConfirmation,
         titleVisibility: .visible
      ) {
         Button("Remove from this device", role: .destructive) {
            deleteHistory(scope: .currentDevice)
         }
         Button("Delete everywhere", role: .destructive) {
            deleteHistory(scope: .everywhere)
         }
         Button("Cancel", role: .cancel) {}
      } message: {
         Text("Delete only this device's copy, or remove the stitch from iCloud Drive and all devices using this history.")
      }
      .alert(
         "Couldn’t delete stitch",
         isPresented: Binding(
            get: { deleteHistoryError != nil },
            set: { if !$0 { deleteHistoryError = nil } }
         )
      ) {
         Button("OK", role: .cancel) {}
      } message: {
         Text(deleteHistoryError ?? "Continuo could not delete this stitch from history.")
      }
   }

   private var historyCard: some View {
      let maximumDisplayWidth: CGFloat = horizontalSizeClass == .compact ? 350 : 900
      let sourceWidth = max(1, CGFloat(stitch.pixelSize.width))
      let sourceHeight = max(1, CGFloat(stitch.pixelSize.height))
      let frameSize = CGSize(
         width: maximumDisplayWidth,
         height: maximumDisplayWidth * sourceHeight / sourceWidth
      )

      return VStack(alignment: .center, spacing: 10) {
         VStack(spacing: ContinuoDesign.Spacing.standard) {
            framedScreenshot(size: frameSize) {
               Image(
                  stitch.thumbnail,
                  scale: 1,
                  orientation: .up,
                  label: Text("Saved stitched screenshot")
               )
               .resizable()
               .interpolation(.high)
               .aspectRatio(sourceWidth / sourceHeight, contentMode: .fit)
               .frame(maxWidth: maximumDisplayWidth)
               .accessibilityLabel(
                  "Saved stitched result, \(stitch.pixelSize.width) by \(stitch.pixelSize.height) pixels"
               )
            }

            historyActionButtons
         }
         .frame(maxWidth: .infinity, alignment: .center)

         Text("\(stitch.pixelSize.width) × \(stitch.pixelSize.height) px")
            .font(ContinuoDesign.Typography.metadata())
            .fontDesign(.monospaced)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)

         if isPreparingHistoryAsset, let historyAssetPreparationProgress {
            historyAssetPreparationView(historyAssetPreparationProgress)
         }

         if stitch.sourceDeletionInProgress {
            HStack(spacing: 8) {
               ProgressView()
                  .controlSize(.small)
               Text("Deleting source images…")
                  .font(.caption)
                  .foregroundStyle(.secondary)
            }
         } else if let sourceDeletionError = stitch.sourceDeletionError {
            Label(sourceDeletionError, systemImage: "exclamationmark.triangle")
               .font(.caption)
               .foregroundStyle(.orange)
         }
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .accessibilityElement(children: .contain)
   }

   private var historyActionButtons: some View {
      HStack(spacing: 20) {
         historyActionButton(
            systemImage: "photo",
            title: "Save to Photos",
            tint: ContinuoDesign.primaryAction,
            isDisabled: stitch.fullResolutionURL == nil || isPreparingHistoryAsset || isSavingToPhotos,
            action: onSaveToPhotos
         )
         historyActionButton(
            systemImage: "folder",
            title: "Save to Files",
            tint: ContinuoDesign.primaryAction,
            isDisabled: stitch.fullResolutionURL == nil || isPreparingHistoryAsset || isSavingToPhotos,
            action: onSaveToFiles
         )
         historyActionButton(
            systemImage: "trash",
            title: "Delete stitch from history",
            tint: ContinuoDesign.destructive,
            isDisabled: isDeletingHistory || isPreparingHistoryAsset || isSavingToPhotos,
            action: { showingDeleteHistoryConfirmation = true }
         )
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 4)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Actions for saved stitched image")
   }

   private func historyActionButton(
      systemImage: String,
      title: String,
      tint: Color,
      isDisabled: Bool,
      action: @escaping () -> Void
   ) -> some View {
      Button {
         guard !isDisabled else { return }
         action()
      } label: {
         let buttonColor = isDisabled ? Color.secondary : tint
         Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: ContinuoDesign.Control.shareButton, height: ContinuoDesign.Control.shareButton)
            .background(buttonColor, in: Circle())
            .overlay {
               Circle()
                  .stroke(.white.opacity(isDisabled ? 0.12 : 0.22), lineWidth: 1)
            }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .help(title)
   }

   private func deleteHistory(scope: HistoryDeletionScope) {
      isDeletingHistory = true
      Task { @MainActor in
         deleteHistoryError = await onDeleteHistory(scope)
         isDeletingHistory = false
      }
   }

   private func historyAssetPreparationView(
      _ progress: HistoryAssetPreparationProgress
   ) -> some View {
      VStack(spacing: 7) {
         Label(
            progress.message,
            systemImage: progress.phase == .ready ? "checkmark.icloud" : "icloud.and.arrow.down"
         )
         .font(.caption)
         .foregroundStyle(.secondary)

         if let fraction = progress.fraction {
            ProgressView(value: fraction)
         } else {
            ProgressView()
               .progressViewStyle(.linear)
         }
      }
      .frame(maxWidth: 350)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(progress.message)
   }

   private func framedScreenshot<Content: View>(
      size: CGSize,
      @ViewBuilder content: () -> Content
   ) -> some View {
      let shortEdge = max(1, min(size.width, size.height))
      let cornerRadius = min(shortEdge / 2, max(10, shortEdge * 0.06))
      let deviceShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      return content()
         .clipShape(deviceShape)
         .overlay {
            deviceShape
               .strokeBorder(Color.primary.opacity(0.30), lineWidth: 1)
         }
   }
}
