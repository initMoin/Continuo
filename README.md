# Continuo

Continuo is a native screenshot-stitching app for iPhone, iPad, and Mac. It
reconstructs overlapping screenshots into one continuous, full-resolution
image while keeping matching deterministic and on-device.

## Status

Continuo is under active development. The current implementation focuses on
vertical screenshot sequences, confidence-aware pair registration, pixel-space
composition, lightweight history previews, and local or iCloud Drive history
storage.

## Architecture

```text
Continuo/
  ContinuoCore/   Platform-independent domain and stitching pipeline
  Features/       SwiftUI features and observable presentation state
  Platform/       Photos, Files, history, and source-deletion adapters
```

The core pipeline is:

```text
Import -> reduced matching rasters -> pair registration -> seam selection
       -> on-demand full-resolution decode -> deterministic composition
```

Candidate discovery and registration use bounded images and bounded
concurrency. Full-resolution images are decoded sequentially only when the
final compositor requests them, limiting peak memory as source counts grow.

## Requirements

- Xcode 27 or a compatible toolchain
- iOS, iPadOS, or macOS 26+
- An Apple development team for signed device builds and iCloud testing

Open `Continuo.xcodeproj`, select the `Continuo` scheme, and build for a
supported destination.

For a signing-independent compile check:

```sh
xcodebuild -scheme Continuo \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Privacy

Stitching runs on-device. Continuo does not require an account or upload
screenshot contents to a server. Users explicitly choose whether stitch
history is stored on the device or in their private iCloud Drive container.

## License

Continuo is available under the terms in [LICENSE.md](LICENSE.md).
