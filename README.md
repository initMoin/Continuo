# Continuo

Continuo reconnects selected screenshots into one continuous view. Processing is local to the device and the shared stitching engine is designed for iOS, iPadOS, and macOS.

## Requirements

- Xcode 27 or newer
- Swift 6 language mode
- iOS, iPadOS, and macOS 26.0 minimum deployment targets

## Build and test

```sh
xcodebuild -scheme Continuo -sdk iphonesimulator build
xcodebuild -scheme Continuo -destination 'platform=macOS' test
```

The repository currently contains the initial vertical-stitching milestone. The engine is separated from SwiftUI and platform adapters so registration, confidence, rendering, and image-processing behavior can be tested independently.

## Structure

- `Continuo/ContinuoCore` — platform-neutral domain, normalization, registration, processing, cropping, and rendering.
- `Continuo/Features` — SwiftUI presentation and view-model state.
- `Continuo/Platform` — Photos, Files, export, and source-deletion adapters.
- `ContinuoTests` — engine and platform behavior tests.

See the project foundation and implementation documents for the product direction and milestone boundaries.
