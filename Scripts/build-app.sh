#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST_TEMPLATE="$ROOT_DIR/Resources/Info.plist"
PRODUCT_NAME="SqueakyClean"
APP_NAME="$PRODUCT_NAME.app"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

validate_plist() {
    local plist="$1"
    local expected_minimum="${2:-}"
    local executable
    local identifier
    local package_type
    local short_version
    local build_version
    local minimum_system

    plutil -lint "$plist" >/dev/null || fail "Invalid property list: $plist"

    executable="$(plist_value "$plist" CFBundleExecutable)" || fail "CFBundleExecutable is missing from $plist"
    identifier="$(plist_value "$plist" CFBundleIdentifier)" || fail "CFBundleIdentifier is missing from $plist"
    package_type="$(plist_value "$plist" CFBundlePackageType)" || fail "CFBundlePackageType is missing from $plist"
    short_version="$(plist_value "$plist" CFBundleShortVersionString)" || fail "CFBundleShortVersionString is missing from $plist"
    build_version="$(plist_value "$plist" CFBundleVersion)" || fail "CFBundleVersion is missing from $plist"
    minimum_system="$(plist_value "$plist" LSMinimumSystemVersion)" || fail "LSMinimumSystemVersion is missing from $plist"

    [[ "$executable" == "$PRODUCT_NAME" ]] || fail "CFBundleExecutable must be $PRODUCT_NAME"
    [[ "$package_type" == "APPL" ]] || fail "CFBundlePackageType must be APPL"
    [[ "$identifier" =~ ^[A-Za-z0-9-]+([.][A-Za-z0-9-]+)+$ ]] || fail "Invalid CFBundleIdentifier: $identifier"
    [[ "$short_version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || fail "Invalid CFBundleShortVersionString: $short_version"
    [[ "$build_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "Invalid CFBundleVersion: $build_version"
    [[ "$minimum_system" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || fail "Invalid LSMinimumSystemVersion: $minimum_system"

    if [[ -n "$expected_minimum" && "$minimum_system" != "$expected_minimum" ]]; then
        fail "LSMinimumSystemVersion ($minimum_system) does not match the build target ($expected_minimum)"
    fi
}

version_is_at_least() {
    local candidate="$1"
    local minimum="$2"
    local candidate_major candidate_minor candidate_patch
    local minimum_major minimum_minor minimum_patch

    IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$candidate"
    IFS=. read -r minimum_major minimum_minor minimum_patch <<< "$minimum"
    candidate_minor="${candidate_minor:-0}"
    candidate_patch="${candidate_patch:-0}"
    minimum_minor="${minimum_minor:-0}"
    minimum_patch="${minimum_patch:-0}"

    if (( 10#$candidate_major != 10#$minimum_major )); then
        (( 10#$candidate_major > 10#$minimum_major ))
        return
    fi
    if (( 10#$candidate_minor != 10#$minimum_minor )); then
        (( 10#$candidate_minor > 10#$minimum_minor ))
        return
    fi
    (( 10#$candidate_patch >= 10#$minimum_patch ))
}

require_command swift
require_command plutil
require_command codesign
require_command lipo
[[ -x /usr/libexec/PlistBuddy ]] || fail "Required command not found: /usr/libexec/PlistBuddy"
[[ "$(uname -s)" == "Darwin" ]] || fail "App packaging is supported only on macOS"
[[ -f "$INFO_PLIST_TEMPLATE" ]] || fail "Missing Info.plist template at $INFO_PLIST_TEMPLATE"

validate_plist "$INFO_PLIST_TEMPLATE"

DEFAULT_DEPLOYMENT_TARGET="$(plist_value "$INFO_PLIST_TEMPLATE" LSMinimumSystemVersion)"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$DEFAULT_DEPLOYMENT_TARGET}"
[[ "$MACOSX_DEPLOYMENT_TARGET" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || fail "Invalid MACOSX_DEPLOYMENT_TARGET: $MACOSX_DEPLOYMENT_TARGET"
version_is_at_least "$MACOSX_DEPLOYMENT_TARGET" "$DEFAULT_DEPLOYMENT_TARGET" || fail "MACOSX_DEPLOYMENT_TARGET cannot be lower than $DEFAULT_DEPLOYMENT_TARGET"

BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
if [[ "$BUILD_DIR" != /* ]]; then
    BUILD_DIR="$ROOT_DIR/$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
[[ "$BUILD_DIR" != "/" ]] || fail "BUILD_DIR cannot be the filesystem root"

ARCHS_INPUT="${ARCHS:-$(uname -m)}"
ARCHS_INPUT="${ARCHS_INPUT//,/ /}"
read -r -a REQUESTED_ARCHITECTURES <<< "$ARCHS_INPUT"
[[ "${#REQUESTED_ARCHITECTURES[@]}" -gt 0 ]] || fail "ARCHS must contain at least one architecture"

ARCHITECTURES=()
ARCHITECTURES_SEEN=" "
for architecture in "${REQUESTED_ARCHITECTURES[@]}"; do
    case "$architecture" in
        arm64|x86_64) ;;
        *) fail "Unsupported architecture '$architecture'. Supported values: arm64 x86_64" ;;
    esac

    if [[ "$ARCHITECTURES_SEEN" != *" $architecture "* ]]; then
        ARCHITECTURES+=("$architecture")
        ARCHITECTURES_SEEN+="$architecture "
    fi
done

WARNINGS_AS_ERRORS="${WARNINGS_AS_ERRORS:-0}"
case "$WARNINGS_AS_ERRORS" in
    0|false|no) WARNINGS_AS_ERRORS=0 ;;
    1|true|yes) WARNINGS_AS_ERRORS=1 ;;
    *) fail "WARNINGS_AS_ERRORS must be 0 or 1" ;;
esac

BINARIES=()
for architecture in "${ARCHITECTURES[@]}"; do
    triple="${architecture}-apple-macosx${MACOSX_DEPLOYMENT_TARGET}"
    scratch_path="$BUILD_DIR/swiftpm/$architecture"
    build_command=(
        swift build
        --package-path "$ROOT_DIR"
        --scratch-path "$scratch_path"
        --configuration release
        --triple "$triple"
        --product "$PRODUCT_NAME"
    )
    if [[ "$WARNINGS_AS_ERRORS" == 1 ]]; then
        build_command+=(-Xswiftc -warnings-as-errors)
    fi

    printf 'Building %s for %s...\n' "$PRODUCT_NAME" "$architecture"
    "${build_command[@]}"
    binary_directory="$("${build_command[@]}" --show-bin-path)"
    binary="$binary_directory/$PRODUCT_NAME"
    [[ -x "$binary" ]] || fail "Built executable not found at $binary"
    lipo "$binary" -verify_arch "$architecture" || fail "Built executable does not contain $architecture"
    BINARIES+=("$binary")
done

STAGING_ROOT="$(mktemp -d "$BUILD_DIR/.squeakyclean-package.XXXXXX")"
STAGING_APP="$STAGING_ROOT/$APP_NAME"
APP_DIR="$BUILD_DIR/$APP_NAME"

cleanup() {
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$INFO_PLIST_TEMPLATE" "$STAGING_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MACOSX_DEPLOYMENT_TARGET" "$STAGING_APP/Contents/Info.plist"

if [[ "${#BINARIES[@]}" -eq 1 ]]; then
    cp "${BINARIES[0]}" "$STAGING_APP/Contents/MacOS/$PRODUCT_NAME"
else
    lipo -create "${BINARIES[@]}" -output "$STAGING_APP/Contents/MacOS/$PRODUCT_NAME"
fi
chmod +x "$STAGING_APP/Contents/MacOS/$PRODUCT_NAME"

validate_plist "$STAGING_APP/Contents/Info.plist" "$MACOSX_DEPLOYMENT_TARGET"

PACKAGED_ARCHITECTURES="$(lipo -archs "$STAGING_APP/Contents/MacOS/$PRODUCT_NAME")"
read -r -a ACTUAL_ARCHITECTURES <<< "$PACKAGED_ARCHITECTURES"
[[ "${#ACTUAL_ARCHITECTURES[@]}" -eq "${#ARCHITECTURES[@]}" ]] || fail "Unexpected packaged architectures: $PACKAGED_ARCHITECTURES"
for architecture in "${ARCHITECTURES[@]}"; do
    lipo "$STAGING_APP/Contents/MacOS/$PRODUCT_NAME" -verify_arch "$architecture" || fail "Packaged executable is missing $architecture"
done

CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-"-"}"
sign_arguments=(--force --sign "$CODE_SIGN_IDENTITY")
if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
    sign_arguments+=(--options runtime --timestamp)
fi

# Sign only after the bundle is complete. Any later mutation invalidates the seal.
codesign "${sign_arguments[@]}" "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

rm -rf "$APP_DIR"
mv "$STAGING_APP" "$APP_DIR"

printf 'Built and verified %s\n' "$APP_DIR"
printf 'Architectures: %s\n' "$PACKAGED_ARCHITECTURES"
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    printf 'Signature: ad hoc\n'
else
    printf 'Signature: %s (hardened runtime)\n' "$CODE_SIGN_IDENTITY"
fi
