# Continuo: Screen Stitcher — Codex Project Instructions

These instructions define how Codex should plan, implement, test, and extend Continuo: Screen Stitcher.

Continuo is a native Apple-platform app that reconnects separate screenshots into their original continuous view. It supports vertical, horizontal, and eventually two-dimensional/freeform stitching. Its core promise is reliable reconstruction: automation should be fast, but uncertain joins must be visible and repairable.

The app should feel like a dependable instrument, not a black-box collage generator.

## 1. Product identity

- Product name: **Continuo: Screen Stitcher**
- Short brand name: **Continuo**
- Tagline: **From fragments to the full view.**
- Platform targets: iOS, iPadOS, and macOS
- Minimum deployment targets: iOS 26.0, iPadOS 26.0, macOS 26.0
- Build target: use the newest stable SDK available for the release
- Business model: free app with three optional tips, each under $5
- Suggested tips: $0.99, $2.99, and $4.99

Do not make the core stitching engine dependent on Apple Intelligence, a server, an account, or a network connection.

## 2. Product principles

Follow these principles in every implementation decision:

1. **No silent mistakes.** Never silently omit, reorder, or discard a source screenshot in a final result.
2. **Automation with recovery.** Automatic processing is the default, but every low-confidence result must be inspectable and repairable.
3. **Source traceability.** Every output region should be traceable to one or more source screenshots.
4. **Privacy by default.** Screenshot contents stay on-device unless the user explicitly shares or exports them.
5. **Platform-native behavior.** Use SwiftUI and Apple frameworks first. Add UIKit/AppKit adapters only where they materially improve platform integration.
6. **Correctness before polish.** Establish a tested deterministic stitching engine before adding AI, animations, or extensive customization.
7. **Progressive complexity.** Start with selected screenshot sequences, then add automatic grouping, horizontal stitching, freeform layouts, OCR, and intelligence features in measured phases.

## 3. Scope

### Required product capabilities

- Import screenshots from Photos and Files.
- Support drag-and-drop on iPadOS and macOS where appropriate.
- Stitch screenshots vertically.
- Stitch screenshots horizontally.
- Detect likely ordering and overlap relationships.
- Display confidence for each join.
- Detect insufficient overlap, duplicates, skipped screenshots, and likely wrong ordering.
- Let users reorder, exclude, retry, and adjust joins without restarting the entire project.
- Export a clean image.
- Preserve projects so they can be reopened and repaired.
- Remain responsive during processing.
- Process large batches without holding every full-resolution decoded image in memory.

### Differentiating capabilities

#### Smart Canvas

The app should eventually support:

- Vertical layouts.
- Horizontal layouts.
- Freeform two-dimensional layouts.
- A visual source map showing how screenshots relate to one another.
- Mixed-direction relationships where a source sequence genuinely requires them.

#### Proof Mode

Proof Mode is the repair and trust layer. It should:

- Show every source screenshot in the proposed sequence.
- Mark joins as high, medium, or low confidence.
- Show the overlap and proposed seam for a selected join.
- Explain failures in plain language.
- Support reorder, exclude, retry, and seam adjustment.
- Preserve the original source files and the project edit history.

#### Screenshot-to-document

Later phases should add:

- OCR and full-text search.
- Search-result navigation to the output region and source screenshot.
- Searchable PDF export.
- Markdown, plain-text, and HTML export.
- Optional section, date, URL, name, total, and action-item extraction.
- Optional Apple Intelligence summaries and titles.

### Explicit non-goals for the first implementation

- Do not capture the live screen of another app.
- Do not use private APIs.
- Do not require an account.
- Do not upload screenshots to a server.
- Do not make generative reconstruction of missing pixels part of the core result.
- Do not start by building a general-purpose photo panorama editor.
- Do not add a third-party image-processing dependency unless the native implementation is demonstrably insufficient and the dependency is justified.

## 4. Deployment and availability rules

Use iOS 26.0, iPadOS 26.0, and macOS 26.0 as the initial minimum deployment targets.

Build against the newest stable SDK available at release time. Do not raise the entire app’s minimum OS solely to use a newer optional API.

Use availability checks for APIs or behaviors introduced after the minimum target, including OS-27-specific features.

Foundation Models is optional. It starts at OS 26.0, but model availability also depends on device eligibility, region, settings, and model readiness. Always provide a non-Foundation-Models fallback.

When prompts or structured generation behavior changes across OS releases, version the prompt and test the output for each supported model range. Do not use Apple Intelligence output for pixel-level geometry, seam coordinates, transforms, or other correctness-critical calculations.

## 5. Technical stack

Prefer the following native frameworks:

- **Swift / Swift Concurrency:** application and engine implementation.
- **SwiftUI:** shared interface and state presentation.
- **Vision:** image registration, feature prints, and OCR.
- **Image I/O:** lazy decoding, metadata access, thumbnails, orientation handling, and subsampling.
- **Accelerate / vImage / vDSP:** image conversion, correlation, resampling, blending, and numerical operations.
- **Core Graphics:** cross-platform image contexts, transforms, and rendering.
- **Core Image:** compositing, masks, and perspective transforms where useful.
- **PDFKit:** searchable PDF creation and preview where appropriate.
- **PhotosUI:** user-selected Photos assets through `PhotosPicker`.
- **UniformTypeIdentifiers:** supported imports and exports.
- **StoreKit 2:** consumable tip purchases.
- **App Intents:** future Shortcuts integration.
- **Foundation Models:** optional summaries, titles, extraction, and explanations.

The shared engine should avoid `UIImage` and `NSImage` in core domain code. Prefer `CGImage`, `CIImage`, `Data`, image-provider abstractions, and platform-neutral value types. Keep UIKit/AppKit image conversion in platform adapters or UI layers.

## 6. Architecture

Use a layered architecture that keeps the stitching engine testable without SwiftUI.

Suggested structure:

```text
Continuo/
  App/
    ContinuoApp.swift
    AppEnvironment.swift
    AppCommands.swift
  Features/
    Home/
    SourceSelection/
    SmartCanvas/
    ProofMode/
    Export/
    Settings/
    Tips/
  ContinuoCore/
    Domain/
    ImageLoading/
    ImageNormalization/
    CandidateGraph/
    Registration/
    CorrelationFallback/
    Confidence/
    SeamSelection/
    CanvasLayout/
    Rendering/
    OCR/
    ProjectStore/
  Platform/
    Photos/
    Files/
    Sharing/
    iOS/
    iPadOS/
    macOS/
  ShareExtension/
  Tests/
    Fixtures/
    RegistrationTests/
    CandidateGraphTests/
    SeamTests/
    LayoutTests/
    RenderingTests/
    PersistenceTests/
    PerformanceTests/
    UITests/
```

### Layer responsibilities

#### Domain

Contains pure data models and value types:

- Source image metadata.
- Candidate relationships.
- Transforms.
- Overlap regions.
- Seam definitions.
- Confidence and diagnostics.
- Canvas layouts.
- Export settings.
- OCR document structures.

No SwiftUI, UIKit, AppKit, PhotosUI, or StoreKit code should appear in the domain layer.

#### Engine

Contains the processing pipeline:

- Image loading and downsampling.
- Orientation and color normalization.
- Candidate grouping and ordering.
- Pairwise registration.
- Fallback matching.
- Confidence scoring.
- Seam selection.
- Layout solving.
- Preview rendering.
- Final rendering.

#### Platform adapters

Handle:

- PhotosPicker and Photos asset loading.
- Files and drag-and-drop.
- Share Extension input.
- App sandbox storage.
- StoreKit 2.
- Mac menus and document/file behavior.

#### UI

Presents state from the engine. UI code should not implement image matching or manipulate large image buffers directly.

## 7. Concurrency and memory rules

Use Swift concurrency deliberately.

- Keep UI state on `@MainActor`.
- Run image analysis and rendering off the main actor.
- Use `actor` types for mutable processing sessions and project stores where appropriate.
- Make engine models `Sendable` when possible.
- Support cancellation through `Task` cancellation checks between expensive stages and between source pairs.
- Report progress as structured values, not only strings.
- Do not create an unbounded task per source image.
- Limit simultaneous full-resolution work.
- Use an `autoreleasepool` around large image decode/render loops where applicable.
- Avoid retaining `UIImage`, `NSImage`, `CGImage`, and decompressed pixel buffers longer than necessary.
- Never decode all source images to full resolution before matching.
- Use thumbnail or subsampled representations for candidate discovery and registration.
- Render previews at the required display size.
- Render final output only after the layout and joins are accepted.
- Use tiled or segmented intermediate rendering for very large outputs.
- Enforce maximum pixel count, width, height, and file-size policies before rendering.

The app must remain cancellable and responsive if the user leaves a project or starts a new import.

## 8. Core domain model

Use a model similar to the following. Names may change, but the relationships must remain explicit.

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
    var filename: String?
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

The project must retain enough information to:

- Reopen and re-render a result.
- Show which source images were used.
- Identify excluded images.
- Inspect and adjust individual joins.
- Recompute a join without discarding the rest of the project.
- Navigate from output regions back to source images.

## 9. Stitching engine requirements

### 9.1 Input normalization

For each source:

1. Read metadata without fully decoding the image.
2. Normalize orientation.
3. Normalize the working color space.
4. Record pixel dimensions and scale.
5. Preserve the original source URL or copied project-local source.
6. Generate a reduced-size matching representation.
7. Make all later coordinate conversions explicit between working and source resolutions.

Do not assume all imported images have the same orientation, scale, color profile, or file encoding.

### 9.2 Source grouping and ordering

Use multiple signals:

- User selection order.
- Capture time and file creation time.
- Image dimensions and aspect ratio.
- Screenshot-like metadata where available.
- Global feature-print similarity.
- Local overlap score.
- Plausible translation direction and magnitude.

Do not trust any one signal. Build a candidate graph:

- Each source screenshot is a node.
- A plausible overlap is an edge.
- The edge stores direction, transform, overlap, confidence, and diagnostics.
- The final sequence/layout is selected from the highest-confidence coherent graph structure.

For the first vertical/horizontal implementation, it is acceptable to start from the user’s selection order and validate adjacent pairs. Do not hide this simplification; make the engine interfaces capable of graph-based ordering later.

### 9.3 Pairwise alignment

Primary path:

- Use translational image registration for normal scrolling screenshots.
- Constrain the expected movement to the selected direction.
- Permit small cross-axis drift.
- Use homographic registration only when perspective or scale differences are plausible, especially for freeform layouts.

Fallback path:

- Convert the reduced images to grayscale or edge maps.
- Search for candidate translations with normalized correlation or phase correlation.
- Compare several possible overlap windows.
- Return diagnostics explaining why a candidate was rejected.

The engine must distinguish:

- No match found.
- Match found but insufficient overlap.
- Match found with excessive cross-axis drift.
- Match found but low visual agreement.
- Match found with ambiguous/repetitive content.
- Match accepted.

### 9.4 Confidence scoring

Confidence should be a structured result, not a single opaque boolean.

At minimum, record:

- Similarity score.
- Overlap size and percentage.
- Translation magnitude.
- Cross-axis drift.
- Residual error after alignment.
- Whether the match was produced by the primary or fallback algorithm.
- Whether multiple candidate matches were close in score.
- Any masking or ignored regions used.

Define thresholds in one place and make them testable. Do not scatter magic numbers through the engine.

Suggested levels:

- `high`: safe to include automatically.
- `medium`: include but show in Proof Mode.
- `low`: do not silently commit; request review.
- `rejected`: no usable join.

Thresholds must be tuned against fixture data, not guessed only from a single sample.

### 9.5 Seam selection

For each accepted overlap:

1. Build an error map between aligned source regions.
2. Penalize strong disagreements.
3. Prefer seams through stable, low-error content.
4. Avoid cutting through text, icons, faces, and high-contrast UI elements where possible.
5. Prefer a simple single-cut seam for screenshots unless testing proves a path seam is necessary.
6. Store the seam in source/output coordinates.
7. Allow manual adjustment in Proof Mode.

The first implementation should prioritize clean, predictable results over an elaborate seam optimizer.

### 9.6 Dynamic-content handling

Account for:

- Status bars and clocks.
- Navigation bars and tab bars.
- Scrollbars.
- Animated backgrounds.
- Ads.
- Video thumbnails.
- Typing indicators and live presence states.

Mitigations:

- Mask known system chrome where reliably detectable.
- Compare structural edges and luminance instead of only raw RGB values.
- Down-weight small volatile areas.
- Use OCR/text-line stability when available.
- Let users define an ignored region in Proof Mode.

Do not claim that the engine can infer missing content when there is no visual evidence.

### 9.7 Layout solving

For vertical and horizontal modes:

- Produce a monotonic sequence.
- Reject cycles and contradictory placements.
- Keep cross-axis drift within configured tolerance.
- Detect gaps and overlaps.

For freeform mode:

- Solve placements from the candidate graph.
- Detect disconnected components.
- Show disconnected components separately rather than inventing positions.
- Allow users to drag a source into the canvas and re-run local matching.

### 9.8 Rendering

Separate preview rendering from final rendering.

Preview rendering:

- Uses reduced sources.
- Is fast and cancellable.
- Shows seams, confidence, and source boundaries.

Final rendering:

- Uses original sources where practical.
- Respects export dimensions and color profile.
- Preserves orientation.
- Supports PNG/JPEG and future PDF/HTML/Markdown outputs.
- Uses tiled or segmented work for oversized results.

If a single image exceeds safe limits, do not crash or silently downscale. Explain the issue and offer downscaled, sliced, or PDF output.

## 10. Import and platform integration

### iOS and iPadOS

- Use `PhotosPicker` for user-selected Photos assets.
- Prefer selected-item access rather than requesting full photo-library permission in v1.
- Use `fileImporter` for Files.
- Add a Share Extension for screenshots and supported image inputs.
- Support multi-selection.
- Show import progress when Photos needs to retrieve assets from iCloud.
- Preserve source identifiers where available.

### macOS

- Use file importer/open panel as a primary workflow.
- Support drag-and-drop onto the project window.
- Support Finder-style file URLs where sandbox rules allow.
- Add native menu commands for import, export, undo, redo, zoom, and Proof Mode.
- Use a resizable inspector for source and join details.

### Share Extension

The Share Extension should:

- Accept supported image types.
- Copy or hand off source data safely to the containing app.
- Avoid performing the complete expensive stitch in the extension process.
- Open or create a Continuo project in the main app for processing.
- Preserve user-selected order when the source provides it.

## 11. User interface requirements

### Home

- Recent projects.
- New stitch/import action.
- Clear project status.
- No automatic scan of the entire photo library by default.

### Source selection

- Multi-select thumbnails.
- Sort by picker order, capture time, filename, or inferred sequence.
- Show count and estimated memory/output size.
- Make the source list editable before processing.

### Smart Canvas

- Pan and zoom.
- Source thumbnails or map.
- Vertical/horizontal/freeform mode indicator.
- Confidence badges.
- Join selection.
- Proof Mode entry point.

### Proof Mode

- Pairwise join inspector.
- Overlay of source regions.
- Seam preview.
- Retry action.
- Reorder actions.
- Exclude action.
- Manual seam adjustment.
- Plain-language diagnostics.

### Export

- Long image.
- Sliced images.
- Searchable PDF when OCR exists.
- Markdown/plain text/HTML when requested.
- Share Sheet.
- Save to Photos or Files.
- Copy to clipboard where practical.

### Accessibility

Required:

- VoiceOver labels and actions for every source and join.
- Dynamic Type support.
- Sufficient contrast for seams and confidence states.
- Reduce Motion support.
- Keyboard navigation and shortcuts on iPadOS and macOS.
- Do not communicate confidence only by color.
- Make processing, cancellation, and failure states accessible.

## 12. Persistence and storage

Use a project directory or equivalent local document representation that can hold:

- Project metadata.
- Source references or project-local copies.
- Cached thumbnails.
- Join results and diagnostics.
- Seam definitions.
- OCR data.
- Export history if needed.

Rules:

- Do not modify or delete original Photos assets without explicit user action.
- Do not automatically delete source screenshots after export.
- If a source becomes unavailable, show a repairable missing-source state.
- Keep caches disposable and reconstructable.
- Avoid storing duplicate full-resolution copies unless needed for sandbox stability.

## 13. Privacy

Default behavior:

- No account.
- No cloud requirement.
- No screenshot uploads.
- No ads.
- No analytics in the first release.
- No OCR text sent anywhere.
- No model prompts containing screenshot contents unless the user explicitly enables a future external service.

If diagnostics are added later, never include screenshot pixels, OCR text, filenames, or personal identifiers by default.

Document this clearly in the app’s privacy screen and App Store metadata.

## 14. Monetization with StoreKit 2

The app is free and core functionality is not paywalled.

Use three consumable tip products:

- `com.continuo.tip.small` — $0.99
- `com.continuo.tip.medium` — $2.99
- `com.continuo.tip.large` — $4.99

Implementation rules:

- Load products asynchronously.
- Handle StoreKit failures without affecting stitching.
- Finish successful transactions.
- Do not show tip prompts during import, processing, repair, or export.
- Make the tip sheet dismissible.
- Do not imply that tips unlock correctness, privacy, or core features.
- Do not build entitlement logic for consumable tips.

Keep product identifiers configurable until App Store Connect products are finalized.

## 15. Apple Intelligence integration

Apple Intelligence is an enhancement layer, not the stitcher.

Potential features:

- Generate a project title.
- Summarize a conversation or article.
- Extract dates, totals, names, URLs, and action items.
- Suggest document sections.
- Explain a failed or ambiguous join using engine diagnostics.
- Generate a short bug-report summary.

Do not ask the model to:

- Calculate pixel transforms.
- Choose a seam coordinate directly.
- Invent missing screenshot content.
- Decide correctness from raw images without deterministic engine evidence.

Use structured inputs generated by the engine, such as:

- Source count.
- Candidate relationships.
- Confidence values.
- OCR text snippets when the user has enabled the feature.
- Export/document context.

Always check Foundation Models availability and provide a non-AI fallback. Apple Intelligence features must be independently disableable.

## 16. Testing requirements

Create a fixture corpus before declaring the engine reliable.

Include:

- Short and long vertical conversations.
- Horizontal web pages and spreadsheets.
- Repeated headers and footers.
- Light and dark mode.
- Animated or changing backgrounds.
- Ads and scrollbars.
- Low-overlap pairs.
- Skipped screenshots.
- Duplicate screenshots.
- Reversed order.
- Different device sizes.
- Images with different encodings and orientations.
- 50–100-image batches.
- Very tall and very wide outputs.

### Unit tests

Test:

- Orientation normalization.
- Thumbnail/downsample behavior.
- Candidate edge scoring.
- Ordering and graph selection.
- Transform validation.
- Confidence thresholds.
- Seam selection.
- Canvas placement.
- Source/output coordinate conversion.
- Project persistence and migration.

### Integration tests

Test:

- Vertical stitching end-to-end.
- Horizontal stitching end-to-end.
- Failure and retry behavior.
- Exclusion and reorder behavior.
- Large-batch cancellation.
- Export output dimensions and orientation.
- OCR/search navigation.

### UI tests

Test:

- Import flow.
- Source editing.
- Smart Canvas navigation.
- Proof Mode repair.
- Export/share flow.
- Missing-source recovery.
- Tip sheet presentation and dismissal.

### Performance tests

Measure:

- Time to first preview.
- Time to first confidence result.
- Total processing time.
- Peak memory.
- Cancellation latency.
- Final export time.
- Energy impact where practical.

Do not optimize for one hand-picked fixture. Use a representative corpus.

## 17. Error handling

Use typed errors and user-facing diagnostics.

Examples:

- Unsupported image type.
- Source unavailable.
- Could not decode image.
- Insufficient overlap.
- Ambiguous overlap.
- Direction conflict.
- Disconnected canvas component.
- Output too large.
- Export unavailable.
- OCR unavailable.
- Apple Intelligence unavailable.
- Processing cancelled.

Every error should include:

- A stable internal error code.
- A user-facing explanation.
- A recovery action when possible.
- Logging details through `OSLog` without logging image contents or OCR text.

## 18. Logging and diagnostics

Use structured `OSLog` categories such as:

- `import`
- `decode`
- `registration`
- `confidence`
- `seam`
- `render`
- `ocr`
- `export`
- `storeKit`

Log metadata such as counts, durations, dimensions, and error codes. Do not log screenshot pixels, OCR text, file contents, or sensitive filenames.

Add signposts around expensive phases so performance can be measured in Instruments.

## 19. Implementation sequence

Do not implement every feature in one pass. Work in vertical milestones.

### Milestone 0: workspace and architecture

- Inspect the workspace before editing.
- Determine whether an Apple-platform project already exists.
- Preserve unrelated user changes.
- Create or adapt the multiplatform project.
- Establish shared core, platform adapters, and test targets.
- Add a minimal SwiftUI shell.
- Confirm iOS/iPadOS/macOS 26.0 deployment targets.

### Milestone 1: technical stitching spike

Deliver a working engine that:

1. Accepts a manually selected set of images.
2. Normalizes orientation.
3. Creates reduced matching representations.
4. Estimates pairwise vertical translations.
5. Calculates confidence and diagnostics.
6. Produces a basic vertical preview.
7. Shows an explicit failure state for unreliable joins.
8. Includes fixture and performance tests.

Do not build the full production UI before this milestone works.

### Milestone 2: dependable vertical and horizontal stitching

- Add horizontal mode.
- Add source ordering controls.
- Add seam selection.
- Add retry and exclusion.
- Add cancellation and progress.
- Add PNG/JPEG export.
- Test large batches.

### Milestone 3: Proof Mode

- Add source map.
- Add confidence badges.
- Add pairwise join inspector.
- Add seam adjustment.
- Add reorder and exclude actions.
- Add source/output traceability.

### Milestone 4: Smart Canvas

- Add freeform two-dimensional placement.
- Add graph-based layout solving.
- Add disconnected-component handling.
- Add canvas editing and export slicing.

### Milestone 5: Screenshot-to-document

- Add OCR.
- Add search.
- Add source-location navigation.
- Add searchable PDF.
- Add Markdown/plain text/HTML export.

### Milestone 6: platform integration and monetization

- Add Share Extension.
- Add macOS drag-and-drop and menu commands.
- Add iPad keyboard support.
- Add accessibility audit.
- Add StoreKit 2 tips.

### Milestone 7: optional intelligence

- Add availability checks.
- Add title and summary generation.
- Add extraction features.
- Add diagnostics explanations.
- Add prompt versioning and fixture-based AI evaluations.

## 20. Codex working rules

When working on this project:

1. Inspect the current repository and relevant files before editing.
2. Preserve existing user changes and do not reset unrelated work.
3. Use `apply_patch` for source edits where practical.
4. Keep commits or changes focused by milestone.
5. Do not add dependencies casually.
6. Prefer native Apple frameworks for image processing.
7. Do not use private APIs or undocumented behavior.
8. Do not add network calls to the core processing path.
9. Write tests with each engine capability.
10. Run the narrowest relevant tests after each change, then run the broader suite at milestone boundaries.
11. Treat compiler warnings and concurrency warnings as actionable.
12. Do not hide failing tests by weakening assertions or deleting fixtures.
13. When an assumption is necessary, record it in the project notes and keep the implementation reversible.
14. If the workspace has no project yet, scaffold the smallest working structure and stop at the first demonstrable milestone rather than generating a speculative full application.
15. Report what changed, what was tested, and what remains uncertain.

## 21. Definition of done for the first buildable milestone

The first buildable milestone is complete when:

- A user can select at least two screenshots.
- Continuo creates a reduced working representation without eagerly decoding all full-resolution sources.
- The engine can estimate a vertical relationship between overlapping screenshots.
- The engine returns structured confidence and diagnostics.
- A valid pair produces a preview with no obvious duplicate overlap.
- An invalid pair produces a visible review/failure state rather than a silent bad result.
- Processing runs off the main actor and can be cancelled.
- Tests cover normalization, registration, confidence, and basic rendering.
- The app builds for iOS, iPadOS, and macOS with 26.0 as the minimum target.

Do not begin Apple Intelligence, 2D layout, or monetization work until this milestone is working and tested.

