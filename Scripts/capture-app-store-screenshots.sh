#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/AppStoreScreenshots}"
BUILD_ROOT="${TMPDIR:-/tmp}/ContinuoAppStoreScreenshotBuilds"
failed_destinations=()

mkdir -p "$OUTPUT_DIR" "$BUILD_ROOT"

capture_destination() {
    local name="$1"
    local destination="$2"
    local output="$OUTPUT_DIR/$name"
    local derived_data="$BUILD_ROOT/$name"
    local result_bundle="$output/$name.xcresult"

    mkdir -p "$output"
    rm -rf "$result_bundle" "$output/attachments"
    echo "Capturing $name ($destination)"
    if ! xcodebuild test \
        -scheme Continuo \
        -configuration Debug \
        -destination "$destination" \
        -derivedDataPath "$derived_data" \
        -resultBundlePath "$result_bundle" \
        -only-testing:ContinuoUITests/ContinuoUITests/testCaptureAppStoreViews; then
        echo "Capture failed for $name; continuing with remaining destinations." >&2
        failed_destinations+=("$name")
        return
    fi

    if ! xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$output/attachments" \
        --filter '*.png'; then
        echo "Attachment export failed for $name; continuing with remaining destinations." >&2
        failed_destinations+=("$name")
        return
    fi

    if command -v jq >/dev/null 2>&1; then
        while IFS=$'\t' read -r exported suggested; do
            stable_name="${suggested%%_0_*}.png"
            cp "$output/attachments/$exported" "$output/$stable_name"
        done < <(
            jq -r '.[].attachments[] | [.exportedFileName, .suggestedHumanReadableName] | @tsv' \
                "$output/attachments/manifest.json"
        )
    fi
}

capture_destination "iPhone" "platform=iOS Simulator,name=iPhone 17"
capture_destination "iPad" "platform=iOS Simulator,name=iPad Air 11-inch (M4)"
capture_destination "Mac" "platform=macOS"

echo "Screenshots written to $OUTPUT_DIR"

if (( ${#failed_destinations[@]} > 0 )); then
    echo "Failed destinations: ${failed_destinations[*]}" >&2
    exit 1
fi
