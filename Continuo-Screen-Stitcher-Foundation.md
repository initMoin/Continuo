# Continuo: Screen Stitcher

Product and engineering foundation for an iOS, iPadOS, and macOS app.

## 1. Product summary

Continuo: Screen Stitcher reconnects separate screenshots into the original continuous view they came from.

Users can combine screenshots vertically, horizontally, or across a two-dimensional canvas. Continuo should make automatic stitching feel trustworthy: it should explain uncertain results, preserve the relationship between source screenshots and the final output, and let users repair a stitch without starting over.

The product should eventually go beyond a single long image. A stitched result can become a searchable, shareable document with OCR, PDF/Markdown/HTML export, annotations, redaction, and optional Apple Intelligence assistance.

### Brand

- Product name: **Continuo: Screen Stitcher**
- Short brand name: **Continuo**
- Working tagline: **From fragments to the full view.**
- Brand idea: a *basso continuo* provides the harmonic foundation that lets a larger musical composition work. Continuo provides the visual foundation that reunites screenshot fragments into a complete view.

## 2. Product principles

1. **The whole should feel inevitable.** The result should look like one original continuous view, not a collage.
2. **Never silently produce a wrong result.** Low-confidence matches must be visible and recoverable.
3. **Automation first, control always available.** Most users should get a result immediately, while advanced users can inspect and repair it.
4. **Local by default.** Screenshots may contain private conversations, receipts, account details, and health information. Processing should happen on-device unless the user explicitly chooses otherwise in a future feature.
5. **The output is more valuable than the stitch.** A long image is useful; a searchable, navigable, shareable document is better.
6. **Stable and maintainable.** The app should be built against current Apple SDKs and tested on supported OS releases rather than relying on legacy behavior.

## 3. Goals

### Primary goals

- Stitch screenshots automatically in vertical and horizontal directions.
- Support 2D/freeform layouts for maps, spreadsheets, design boards, and other large surfaces.
- Let users select exactly which screenshots to process.
- Detect likely ordering, duplicate frames, missing overlaps, and unreliable joins.
- Provide a review and repair experience for uncertain stitches.
- Process large batches without crashes or runaway memory use.
- Export clean results as images and documents.
- Support iPhone, iPad, and Mac with an adaptive interface.
- Offer a free app supported by optional tips.

### Secondary goals

- OCR and searchable stitched documents.
- Redaction and privacy-safe sharing.
- Apple Intelligence features for summaries, titles, categorization, and explanations.
- Share extension and drag-and-drop workflows.
- Project history so users can reopen and repair previous stitches.

### Non-goals for the first release

- Capturing another app's live screen directly.
- Replacing Safari's native full-page screenshot feature.
- Cloud processing or a required account.
- Generative reconstruction of missing screenshot content.
- A general-purpose photo panorama editor.

## 4. Target users and use cases

### Core users

- People preserving long conversations, articles, recipes, receipts, instructions, and comment threads.
- Developers, QA engineers, and support teams creating complete bug reports from screenshot sequences.
- Students and researchers collecting long passages or references.
- People who need to share a complete visual record without sending many separate images.

### Representative use cases

- Stitch a long iMessage, WhatsApp, Slack, or social conversation.
- Combine a web article or documentation page.
- Reconstruct a wide spreadsheet or comparison table from horizontal screenshots.
- Join multiple sections of a map, design board, diagram, or game map in 2D.
- Turn a sequence of receipts or confirmations into a searchable PDF.
- Create a bug report with the stitched view, source screenshots, annotations, and extracted text.

## 5. Differentiating product features

### 5.1 Smart Canvas

Continuo should not assume that every sequence is a vertical scroll.

The Smart Canvas:

- Detects vertical, horizontal, or 2D relationships.
- Arranges screenshots into a canvas based on overlap evidence.
- Supports mixed-direction layouts where appropriate.
- Shows a thumbnail map of the source frames and their inferred positions.
- Allows users to pan, zoom, reorder, and remove source frames before export.
- Supports output as a long image, tiled image, PDF, or sliced set of images.

The core implementation should model screenshots as nodes and possible overlaps as weighted edges. A final layout is a high-confidence arrangement of those nodes, not simply the original picker order.

### 5.2 Self-healing stitching and Proof Mode

Continuo should make its reasoning inspectable without exposing unnecessary technical details.

Proof Mode should:

- Show the source screenshot sequence.
- Mark each join as high, medium, or low confidence.
- Preview the overlap and proposed seam.
- Detect likely skipped screenshots, duplicates, reversed order, and insufficient overlap.
- Offer actions such as **Try another match**, **Move before**, **Move after**, **Exclude**, and **Adjust seam**.
- Allow users to mark repeated headers, footers, status bars, or dynamic regions as ignorable.
- Preserve a non-destructive mapping from every output region back to its source screenshot.

The app should prefer a partial result with a clear warning over a complete-looking but incorrect result.

### 5.3 Screenshot-to-document

Every stitch should be eligible to become a useful document.

Capabilities:

- OCR text extraction from source screenshots and the final result.
- Search within the stitched result.
- Jump from a search result to the relevant output region and source screenshot.
- Detect likely headings, dates, names, totals, URLs, and action items.
- Export a long image, searchable PDF, Markdown, plain text, or HTML.
- Optional annotations and redaction before export.
- Include a source manifest in project data so the user can understand how the result was created.

Apple Intelligence should be optional and layered on top of deterministic OCR and stitching. Potential uses include naming a project, summarizing a conversation, extracting action items, organizing sections, and explaining why a join was rejected. The app must remain useful when Apple Intelligence is unavailable.

## 6. User experience

### First-run experience

1. Explain the product in one sentence: “Reconnect screenshots into one complete view.”
2. Offer **Select Screenshots**, **Import Files**, and **Try Sample Project**.
3. Explain that overlapping screenshots produce the best results.
4. Make privacy behavior clear: processing is on-device by default.

### Primary flow: selected screenshots

1. User selects screenshots from Photos or Files.
2. Continuo loads lightweight previews first.
3. The app detects orientation, ordering, and candidate overlaps.
4. A progress view shows “Mapping your screenshots…” rather than a generic spinner.
5. The Smart Canvas opens with the proposed layout.
6. The app highlights uncertain joins.
7. User accepts, repairs, or removes problem frames.
8. Continuo renders the final output and presents export/share options.

### Primary screens

#### Home / Projects

- Recent projects.
- New stitch button.
- Import from Photos, Files, or Share Extension.
- Project status: complete, needs review, or export available.

#### Source selection

- Multi-select thumbnails.
- Sort by picker order, capture time, or filename.
- Filter to screenshots where possible.
- Select all / clear all.
- Visible count and estimated output size.

#### Smart Canvas

- Main canvas with zoom and pan.
- Source thumbnail strip or map.
- Direction indicator: vertical, horizontal, or 2D.
- Confidence badges on joins.
- Reorder and exclude controls.

#### Proof Mode

- Pair-by-pair join review.
- Overlap overlay.
- Proposed seam.
- Confidence explanation in plain language.
- Drag-to-adjust seam.
- Retry with high-precision matching.

#### Export

- Long image.
- Sliced images.
- Searchable PDF.
- Markdown/plain text/HTML when OCR is available.
- Share Sheet.
- Save to Photos or Files.
- Copy image or text.

#### Settings

- Default export format.
- Maximum output dimensions.
- Automatic Photos cleanup: off by default.
- Appearance and accessibility.
- Apple Intelligence availability and controls.
- Tip jar.
- Privacy information.

## 7. Platform strategy

### Shared technology

- Swift and SwiftUI for the application layer.
- Swift concurrency for background processing, cancellation, and progress reporting.
- A shared `ContinuoCore` package for image loading, matching, layout, seams, rendering, OCR orchestration, and project persistence.
- Platform adapters for Photos, Files, Share Extension, drag-and-drop, and menus.

### iOS and iPadOS

- `PhotosPicker` for user-selected Photos assets.
- File importer for Files and external storage.
- Share Extension for sending screenshots into Continuo from Photos and other apps.
- Adaptive split-view interface on iPad.
- Multitasking-aware memory and cancellation behavior.

### macOS

- File importer and drag-and-drop as primary input.
- Optional Photos picker/library integration.
- Native menu commands and keyboard shortcuts.
- Resizable inspector and canvas layout.
- Support for large images using tiled previews and background rendering.

### Deployment target recommendation

Recommended initial deployment targets:

- iOS 26.0
- iPadOS 26.0
- macOS 26.0

Build with the newest stable SDK available at release time, but do not make OS 27 the minimum unless a genuinely required OS-27-only API appears during implementation.

Reasons:

- The core stitching stack does not need Apple Intelligence or an OS-27-only API.
- Foundation Models is documented as starting at OS 26.0, so Apple Intelligence features can be included behind availability and device/region checks.
- Apple’s on-device model changes across OS releases, so prompts and AI behavior should be tested and versioned rather than used as a reason to raise the minimum OS.
- Apple’s release channel currently identifies OS 27 as beta, making it a poor minimum target for the first production release.
- A 26 minimum gives the app access to the modern platform while allowing it to reach users who have not moved to 27 yet.

Use `#available` checks for any 26.4 or 27-specific APIs or model behavior. If a later feature truly requires OS 27, keep the core app available on 26 and gate that feature rather than raising the entire app’s minimum deployment target.

References:

- [Apple Foundation Models availability and prompt versioning](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions)
- [Apple Foundation Models availability and fallback guidance](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models)
- [Apple platform release status](https://developer.apple.com/news/releases/)

### Apple frameworks

- **Vision:** translational and homographic image registration; OCR; image feature prints; optional contours or other image analysis.
- **Image I/O:** lazy image decoding, thumbnails, orientation normalization, and subsampling.
- **Accelerate / vImage / vDSP:** fast grayscale conversion, correlation, resampling, blending, and image calculations.
- **Core Graphics / Core Image:** transforms, compositing, masks, and export rendering.
- **PDFKit:** searchable PDF assembly and preview where appropriate.
- **PhotosUI / UniformTypeIdentifiers:** Photos and Files workflows.
- **ShareLink / Share Extension APIs:** sharing completed results.
- **App Intents:** future Shortcuts support.
- **Foundation Models:** optional Apple Intelligence features with a deterministic fallback.

## 8. Stitching engine design

### 8.1 Input normalization

For every source image:

- Read metadata without fully decoding the image.
- Normalize orientation.
- Normalize the working color space.
- Record pixel dimensions, scale, creation time, filename, and source identifier.
- Generate a small matching representation.
- Preserve the original source for final rendering.

### 8.2 Candidate grouping and ordering

Use several signals together:

- User selection order.
- Capture time or file creation time.
- Image dimensions and aspect ratio.
- Screenshot-like metadata where available.
- Global feature-print similarity.
- Local overlap score.
- Plausible translation direction and magnitude.

Do not rely on a single signal. Build candidate edges between images and score the edges. Select a coherent path or 2D arrangement with the highest combined confidence.

### 8.3 Alignment

Primary path:

- Use translational image registration for normal screenshot scrolling.
- Constrain expected movement based on the selected direction.
- Use homographic registration only when scaling or perspective differences are plausible.

Fallback path:

- Convert matching representations to grayscale or edge maps.
- Search for the best translation using normalized correlation or phase correlation.
- Compare several candidate overlap windows.
- Reject matches that do not satisfy confidence and geometry thresholds.

### 8.4 Seam selection

For a valid overlap:

- Build a difference/error map.
- Penalize areas with strong disagreement.
- Prefer seams between stable content lines or UI regions.
- Avoid cutting through text, icons, or faces where possible.
- Support a simple single-cut seam first; add more advanced seam paths only if fixture testing justifies them.
- Preserve the seam and confidence metadata for Proof Mode.

### 8.5 Dynamic-content handling

Potentially unstable content includes:

- Clocks and status indicators.
- Scrollbars.
- Animated backgrounds.
- Ads and rotating content.
- Video thumbnails.
- Typing indicators and live presence states.

Mitigations:

- Mask known system chrome.
- Compare structural edges and luminance, not only raw color.
- Down-weight small volatile regions.
- Use OCR/text-line stability when available.
- Permit user-defined ignore regions in Proof Mode.

### 8.6 Rendering and memory

- Match on reduced-size representations.
- Decode full-resolution sources only when needed for final rendering.
- Process one or a small number of pairs at a time.
- Use `autoreleasepool` around large decode/render operations where applicable.
- Keep the UI responsive and support cancellation.
- Render previews at display resolution.
- Render final outputs using tiled or incremental intermediate buffers.
- Apply configurable limits for maximum width, height, pixel count, and file size.
- Offer sliced output or PDF when a single bitmap would be impractical.

## 9. Data model

The model should be platform-independent and Codable where practical.

```swift
struct StitchProject: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sources: [SourceImage]
    var layout: CanvasLayout
    var joins: [JoinResult]
    var exportSettings: ExportSettings
    var ocrDocument: OCRDocument?
}

struct SourceImage: Identifiable, Codable, Sendable {
    var id: UUID
    var localURL: URL
    var sourceIdentifier: String?
    var pixelSize: CGSize
    var orientation: ImageOrientation
    var captureDate: Date?
    var position: CGPoint?
    var excluded: Bool
}

struct JoinResult: Identifiable, Codable, Sendable {
    var id: UUID
    var fromSourceID: UUID
    var toSourceID: UUID
    var transform: AffineTransformData
    var overlapRect: CGRect
    var seam: SeamDefinition
    var confidence: ConfidenceLevel
    var diagnostics: JoinDiagnostics
}

enum CanvasLayout: Codable, Sendable {
    case vertical
    case horizontal
    case freeform
}
```

The exact model can change during implementation, but source-to-output traceability should remain a first-class concern.

## 10. Suggested module structure

```text
Continuo/
  App/
    ContinuoApp.swift
    AppEnvironment.swift
  Features/
    Home/
    SourceSelection/
    SmartCanvas/
    ProofMode/
    Export/
    Settings/
  ContinuoCore/
    ImageLoading/
    ImageNormalization/
    CandidateGraph/
    Registration/
    CorrelationFallback/
    SeamSelection/
    CanvasLayout/
    Rendering/
    OCR/
    ProjectStore/
  Platform/
    Photos/
    Files/
    Sharing/
    Mac/
  ShareExtension/
  Resources/
  Tests/
    StitchFixtures/
    RegistrationTests/
    LayoutTests/
    RenderingTests/
    PerformanceTests/
```

Keep the stitching engine independent from SwiftUI so it can be tested from fixtures, used by iOS/iPadOS/macOS, and eventually exposed to a Share Extension or App Intents.

## 11. Privacy and monetization

### Privacy defaults

Working product assumption:

- No account required.
- No ads.
- No analytics by default.
- No screenshot uploads.
- No server required for core functionality.
- Projects remain local unless the user explicitly shares or exports them.

If analytics are ever added, they should be opt-in and avoid image contents, OCR text, filenames, and personal identifiers.

### Tip jar

The app is free. Tips are optional and do not unlock core functionality.

Suggested three levels, all under $5:

- Small tip: **$0.99**
- Medium tip: **$2.99**
- Large tip: **$4.99**

Use simple, appreciative language. Avoid guilt, streaks, repeated prompts, or paywalls. The tip sheet should be easy to dismiss and should not interrupt stitching or export.

## 12. Quality bar

### Functional quality

- Correctly stitch common vertical screenshot sequences.
- Correctly stitch common horizontal sequences.
- Detect and display uncertain joins.
- Never discard a source screenshot without showing the user.
- Recover from individual pair failures.
- Export results without blocking the UI.
- Preserve image quality and orientation.

### Performance quality

- Matching should begin quickly after import.
- UI should remain responsive during processing.
- Large batches should show progress and support cancellation.
- Memory use should be measured with realistic high-resolution fixtures.
- No single giant in-memory canvas should be required for preview.

### Accessibility quality

- Full VoiceOver support for source lists, confidence states, and repair actions.
- Dynamic Type support.
- Sufficient contrast for seam and confidence overlays.
- Keyboard navigation and shortcuts on iPad with keyboard and macOS.
- Reduce Motion support.

## 13. Test corpus and evaluation

Create a local fixture corpus before polishing the UI. Include:

- Short and long vertical conversations.
- Horizontal web pages and spreadsheets.
- 2D maps or design boards.
- Light and dark mode.
- Repeated headers and footers.
- Animated backgrounds.
- Ads and changing content.
- Low-overlap pairs.
- Skipped screenshots.
- Duplicates and reversed order.
- Screenshots from different device sizes.
- 50–100-image batches.
- Very tall outputs.

Track at least:

- Pair-order accuracy.
- Correct inclusion of first and last screenshots.
- Join/seam error rate.
- False-positive stitch rate.
- Processing time.
- Peak memory.
- Export success rate.
- User repair rate.

The app should be allowed to say “needs review.” A high-confidence incorrect output is worse than a low-confidence result that asks for help.

## 14. Implementation phases

### Phase 0: technical spike

- Build a small shared engine target.
- Load manually selected images.
- Normalize and downsample them.
- Run translational registration on adjacent pairs.
- Render a basic vertical result.
- Log confidence and memory use.
- Validate against the first fixture corpus.

### Phase 1: dependable core stitcher

- Add horizontal mode.
- Add ordering and candidate scoring.
- Add seam selection.
- Add error handling and cancellation.
- Add basic export to PNG/JPEG.

### Phase 2: Smart Canvas and Proof Mode

- Add source map and confidence badges.
- Add manual reorder/exclude.
- Add seam adjustment.
- Add freeform 2D layout.
- Add tiled previews and large-output safeguards.

### Phase 3: document layer

- Add OCR.
- Add searchable result view.
- Add PDF export.
- Add Markdown/plain text/HTML export.
- Add source-location navigation.

### Phase 4: platform polish

- Add Share Extension.
- Add Mac drag-and-drop and menus.
- Add iPad split view and keyboard shortcuts.
- Add accessibility audit.
- Add App Intents/Shortcuts where useful.

### Phase 5: optional intelligence and delight

- Add Apple Intelligence availability checks.
- Add title and summary generation.
- Add action-item/date/entity extraction.
- Add natural-language explanations for failed joins.
- Add optional screen-recording import if the core experience is stable.

## 15. Open decisions

These can remain defaults during the first implementation pass, but should be resolved before release:

1. Minimum supported OS versions for iOS, iPadOS, and macOS.
2. Whether screen-recording import is included in v1 or deferred.
3. Whether OCR/search is part of v1 or the first major update.
4. Whether projects should sync through iCloud or remain local-only initially.
5. Whether PDF/Markdown/HTML export is included in the free app.
6. Final tip names, prices, and localized pricing.
7. Maximum output dimensions and behavior for oversized results.
8. Whether to support arbitrary photos in addition to screenshots.
9. Whether the first target audience is general consumers or developers/support/QA teams.

Recommended defaults:

- iOS/iPadOS/macOS 26.0 minimum deployment targets, built with the newest stable SDK.
- Manual screenshot selection in v1.
- Vertical and horizontal stitching in v1.
- Freeform 2D canvas in the first major update unless the technical spike proves it inexpensive.
- OCR/search in v1.5 or v2.
- No required account or cloud sync in the first release.
- No arbitrary photos until screenshot reliability is strong.

## 16. Initial instruction to Codex

Start by inspecting the existing workspace and determining whether an Apple platform project already exists. Do not overwrite unrelated work.

If no app project exists, scaffold a multiplatform SwiftUI application with shared code for iOS, iPadOS, and macOS. Establish the module boundaries above, then implement the Phase 0 technical spike before building the complete interface.

The first demonstrable milestone should be:

1. Import a manually selected set of screenshots.
2. Normalize and downsample them without loading unnecessary full-resolution images.
3. Estimate pairwise translation and confidence.
4. Produce a basic vertical stitched preview.
5. Display a clear failure state when a join is unreliable.
6. Run the fixture and performance tests.

Do not add Apple Intelligence before the deterministic pipeline has reliable diagnostics and fallback behavior. Do not hide failed joins or silently omit screenshots.
