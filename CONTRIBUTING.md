<p align="center">
  <img src="assets/branding/continuo.png" alt="Continuo logo" width="300">
</p>

<h1 align="center">Contributing to Continuo</h1>

Thank you for helping improve Continuo. Read the project instruction documents
in the repository before changing shared architecture or the stitching pipeline.

## Requirements

- Xcode 27 or a compatible toolchain
- iOS, iPadOS, or macOS 26 SDKs
- An Apple development team for signed device and iCloud testing

## Build and Test

Run the unit and UI tests on an installed iPhone simulator:

```sh
xcodebuild test \
  -scheme Continuo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

Run the same UI tests on an installed iPad simulator when changing adaptive
layout or navigation:

```sh
xcodebuild test \
  -scheme Continuo \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4),OS=latest' \
  -only-testing:ContinuoUITests
```

Capture App Store screenshots for iPhone, iPad, and Mac with:

```sh
Scripts/capture-app-store-screenshots.sh
```

The runner writes separate device folders under `AppStoreScreenshots/` and
captures the workflow, action menu, Intelligence, and About views. The PNGs
are exported from XCTest result attachments and are ignored by Git. Mac
capture requires an available macOS UI automation session.

Build the Mac target separately:

```sh
xcodebuild build \
  -scheme Continuo \
  -destination 'generic/platform=macOS'
```

Simulator tests do not reproduce real Photos permissions, iCloud Drive
propagation, or full-resolution asset downloads. Validate those workflows on a
signed physical device before release.

## Changes

- Keep platform-independent logic in `ContinuoCore`.
- Keep Photos, Files, history, and source deletion behavior in `Platform`.
- Keep SwiftUI presentation state in the feature layer.
- Add focused tests for changes to registration, rendering, persistence, or
  source-selection behavior.
- Do not commit derived data, test result bundles, device exports, or personal
  screenshots.

Continuo is distributed under the terms in [LICENSE.md](LICENSE.md). By
submitting a contribution, you agree to those terms.

<p align="center">
  <a href="https://iamshift.dev">
    <img src="assets/branding/iamshift-logo.png" alt="iamshift logo" width="96">
    <br>
    <img src="assets/branding/moin.shift.png" alt="moin.shift() logo" width="180">
  </a>
</p>
