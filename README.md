<p align="center">
  <img src="assets/branding/continuo.png" alt="Continuo logo" width="360">
</p>

<h1 align="center">Continuo</h1>

<p align="center">
  Native, on-device screenshot stitching for iPhone, iPad, and Mac.
</p>

Continuo is a native screenshot-stitching app for iPhone, iPad, and Mac. It
reconstructs overlapping screenshots into one continuous, full-resolution
image while keeping matching deterministic and on-device.

## Status

Continuo has a working iOS, iPadOS, and macOS implementation. The current
release focus is vertical and horizontal screenshot stitching,
confidence-aware pair registration, pixel-space composition, lightweight
history previews, and local or iCloud Drive history storage.

## Platform feasibility

The Xcode target declares iOS, iPadOS, and macOS 26 as supported platforms, and
the SwiftUI feature layer uses adaptive size classes rather than phone-only
layout assumptions. The shared workflow is validated on iPhone and iPad
simulators, while macOS has a signed build path and platform-specific Files,
PhotosUI, history, and Liquid Glass presentation. Physical-device validation
is still required for Photos permissions and real iCloud propagation.

Landscape sources can participate in vertical stitching, and the workflow now
exposes a Vertical/Horizontal direction control. Horizontal movement is
implemented through a directional adapter that rotates sources into the
renderer’s proven vertical coordinate system, then rotates the finished canvas
back. This keeps seam selection and pixel ownership deterministic while the
direction-specific path receives broader device validation.

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
concurrency. Selected screenshots first use a 640-pixel deterministic mapping
pass; only uncertain pairs are decoded again at higher detail with Vision.
Automatic selection hands its accepted joins directly to stitching instead of
scanning the chosen sequence twice. Full-resolution images are decoded
sequentially only when the final compositor requests them, limiting peak memory
as source counts grow.

## Intelligence assistance

The Intelligence setting offers three explicit modes:

- Automatic uses deterministic pixel matching only.
- Vision-assisted enables Apple Vision as a fallback for ambiguous pair
  alignment.
- Foundation Models-assisted uses the on-device Foundation Models framework,
  when available, to narrow candidate metadata before the normal Vision and
  pixel-matching pipeline runs.

Foundation Models receives candidate identifiers, capture dates, and pixel
dimensions only. Screenshot pixels remain on-device, and every model result is
treated as an optional hint: deterministic matching remains the authority and
the app falls back automatically when a model is unavailable or inconclusive.

## Requirements

- Xcode 27 or a compatible toolchain
- iOS, iPadOS, or macOS 26+
- An Apple development team for signed device builds and iCloud testing

Open `Continuo.xcodeproj`, select the `Continuo` scheme, and build for a
supported destination.

Run the automated tests on an available simulator with:

```sh
xcodebuild test \
  -scheme Continuo \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

The same test target can be run against an iPad simulator by replacing the
destination name with an installed iPad model. Build the Mac target with:

```sh
xcodebuild build \
  -scheme Continuo \
  -destination 'generic/platform=macOS'
```

For a signing-independent compile check:

```sh
xcodebuild -scheme Continuo \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Privacy

Stitching runs on-device. Continuo does not require an account or upload
screenshot contents to a server. Users can keep stitch history on the device
or enable the **Sync history across devices** option to store it in their
private iCloud Drive container. When enabled, lightweight history records are
refreshed when the app becomes active; full-resolution PNGs remain on-demand
assets and are downloaded only when exported.

See the [Privacy Policy](PRIVACY.md), [Support Policy](SUPPORT.md), and [Terms
of Service](TERMS.md) for the App's current policies.

## Support purchases

Continuo's optional support purchases are consumables handled by StoreKit 2:

| Product ID | Display name | App Store Connect price tier |
| --- | --- | --- |
| `support.lemon-cookie` | Lemon Cookie | $2.99 |
| `support.caramel-latte` | Caramel Latte | $4.99 |
| `support.philly-cheesesteak` | Philly Cheesesteak | $9.99 |

For local testing, select `Continuo.storekit` in the scheme's Run options under
StoreKit Configuration. Production products must be created with the same IDs
in App Store Connect before submitting the app.

## License

Continuo is available under the terms in [LICENSE.md](LICENSE.md).

<p align="center">
  <a href="https://iamshift.dev">
    <img src="assets/branding/iamshift-logo.png" alt="iamshift logo" width="96">
    <br>
    <img src="assets/branding/moin.shift.png" alt="moin.shift() logo" width="180">
  </a>
</p>
