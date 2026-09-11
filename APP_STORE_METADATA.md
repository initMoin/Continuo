# Continuo App Store Metadata

Draft for the first App Store submission. The primary storefront language is English (U.S.).

Apple currently limits the app name and subtitle to 30 characters, promotional text to 170 characters, the description to 4,000 characters, and keywords to 100 bytes. Verify the limits in App Store Connect before submission. See Apple's [App Information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) and [product page guidance](https://developer.apple.com/app-store/product-page/).

## App Information

**Name**

Continuo

**Subtitle**

Stitch screenshots together

**Primary category**

Photo & Video

**Secondary category**

Utilities

**Copyright**

Copyright 2026 Moinuddin Ahmad

**Age rating recommendation**

4+. Continuo contains no user-generated social features, advertising, gambling, violence, or mature themes. Complete Apple's questionnaire directly rather than relying on this recommendation.

**Privacy Policy URL**

Publish the repository's `PRIVACY.md` on the GitHub Pages site, then enter the final public URL here:

`https://initmoin.github.io/Continuo/privacy/`

**Support URL**

`https://initmoin.github.io/Continuo/support/`

**Marketing URL**

`https://iamshift.dev`

## Product Page

### Promotional Text

For those moments when one screenshot just doesn't do the trick. Continuo turns a run of screenshots into one clean, continuous image.

### Description

Turn a run of screenshots into one clean, continuous image.

Continuo is built for those moments when one screenshot just doesn't do the trick. Choose screenshots from Photos or Files, choose the direction they should stack, and let Continuo handle the tedious overlap and alignment work.

WHAT CONTINUO DOES

- Stitch screenshots vertically or horizontally.
- Find nearby screenshots automatically when you do not want to pick them one by one.
- Preserve the order you chose and make the final result easy to review.
- Export a full-resolution PNG to Photos or Files.
- Keep lightweight history on this device by default.
- Optionally sync history through your private iCloud Drive across Apple devices using the same Apple Account.
- Remove a history stitch from this device while keeping it elsewhere, or delete it everywhere.
- Delete original selected Photos items only after you explicitly choose that action following a successful save.

PRIVATE BY DEFAULT

Stitching runs on your device. Continuo does not require an account. Optional history sync uses your private iCloud Drive storage, controlled by Apple's iCloud services and your own settings.

CHOOSE YOUR LEVEL OF ASSISTANCE

Use deterministic on-device matching, enable Vision-assisted alignment, or choose Foundation Models-assisted hints when Apple's on-device frameworks are available. Continuo keeps deterministic matching authoritative and does not send full-resolution screenshot pixels to a model.

Built for iPhone, iPad, and Mac.

For those moments when one screenshot just doesn't do the trick.

### Keywords

`scrolling capture,merge images,combine screenshots,panorama,photo collage,screen capture`

Do not add `app`, `Continuo`, or competing app names. Apple says the app is already searchable by its name and company name, and keywords should remain relevant and non-duplicative.

### What's New - Version 1.0

Welcome to Continuo.

Stitch screenshots vertically or horizontally, keep history on this device or in private iCloud Drive, and export a clean PNG to Photos or Files. Continuo is made for the moments when one screenshot just does not do the trick.

## Screenshot Order and Suggested Overlay Copy

Use the same story order for iPhone, iPad, and Mac. Keep the copy short and place it in the screenshot composition rather than inside the app UI.

1. **Workflow**

   Headline: `Bring screenshots together.`

   Supporting line: `Choose your images. Continuo handles the overlap.`

2. **More options**

   Headline: `The controls stay close.`

   Supporting line: `Import, automate, sync, and adjust assistance when you need it.`

3. **Intelligence**

   Headline: `Choose how much help you want.`

   Supporting line: `On-device matching, Vision assistance, and optional Foundation Models hints.`

4. **About**

   Headline: `For those moments when one screenshot just doesn't do the trick.`

   Supporting line: `Built to get out of your way.`

The capture harness is `Scripts/capture-app-store-screenshots.sh`. It exports the five views above for iPhone and iPad and attempts the same Mac run. Capture Mac screenshots on a host with a functioning XCTest UI automation session.

## App Review Information

### Contact

**Name:** Moinuddin Ahmad
**Email:** support@iamshift.dev
**Phone:** `[ADD REVIEW CONTACT PHONE]`

### Demo Account

No account is required. Leave username and password blank.

### Review Notes

Continuo is an on-device screenshot stitching utility for iPhone, iPad, and Mac.

1. Launch the app and complete the short onboarding flow.
2. Tap Add Screenshots and choose Photos or Files. The review build can use any two or more sample images available to the reviewer.
3. Alternatively, tap Auto-select to find a nearby screenshot sequence in Photos.
4. Choose the vertical or horizontal stacking direction, then tap Stitch.
5. Tap Save and choose Photos or Files to create the history entry.
6. After a successful save, the active result offers an explicit action to delete the selected original Photos items. This is separate from deleting the saved stitch from history.
7. History is local by default. History & Sync can move it to private iCloud Drive. The same Apple Account and iCloud Drive must be available on any second device used to test sync.
8. In history, the trash action offers Remove from this device and Delete everywhere. The first keeps an iCloud copy available on other devices; the second removes the history assets from the shared iCloud location.

No subscription or account is required. Optional support purchases are not required to stitch, save, export, or sync history.

### Review Contact Note

If Photos or iCloud behavior cannot be tested in Apple's review environment, please review the core workflow with Files or the provided sample images. We can be reached at support@iamshift.dev for questions.

## Privacy Questionnaire Preparation

This is a preparation checklist, not a substitute for completing Apple's current questionnaire.

- **Developer-collected data:** Continuo is designed not to collect analytics, advertising identifiers, contact data, or screenshot contents.
- **Photos and Files:** User-selected images are processed on-device at the user's request.
- **iCloud:** If the user enables history sync, history records and assets are written to Continuo's private iCloud container. Apple operates the underlying iCloud service.
- **Support purchases:** StoreKit transactions are processed by Apple. The app receives the transaction information needed to verify purchases.
- **Diagnostics:** On-device logs may contain dimensions, durations, operation types, and generated identifiers, but not screenshot pixels by design.

Confirm the final answers against the shipped binary and Apple's privacy questionnaire before submission.

## Optional Support Purchases

These product names match `Continuo.storekit`:

- **Lemon Cookie** - A small optional way to support Continuo's development.
- **Caramel Latte** - A little more support for continued maintenance and improvements.
- **Philly Cheesesteak** - A larger optional show of support for Continuo's development.

Do not mention prices in the product description; App Store Connect and the App Store display localized pricing.

## Legal and Support Links

Publish these files on the GitHub Pages site before submission:

- `PRIVACY.md` -> `https://initmoin.github.io/Continuo/privacy/`
- `TERMS.md` -> `https://initmoin.github.io/Continuo/terms/`
- `SUPPORT.md` -> `https://initmoin.github.io/Continuo/support/`
- Email -> `support@iamshift.dev`

Replace the jurisdiction placeholders in Section 14 of `TERMS.md` before submitting the app for review.
