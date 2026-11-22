#!/bin/sh
set -eu

command -v realpath >/dev/null 2>&1 || realpath() {
    [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
}
BASEDIR="$(dirname "$(realpath "$0")")"
ROOTDIR="$(realpath "$BASEDIR/..")"
PATCHES_DIR="$ROOTDIR/patches"

source "$PATCHES_DIR/sources"

SYSROOT_DIR="${1:-sysroot-iOS-arm64}"
WORK_DIR="${2:-}"
CLEANUP_WORK=0
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d -t utm-stikjit)"
    CLEANUP_WORK=1
fi
trap 'if [ "$CLEANUP_WORK" -eq 1 ]; then rm -rf "$WORK_DIR"; fi' EXIT

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required to build StikJIT.framework (install with: brew install xcodegen)" >&2
    exit 1
fi

mkdir -p "$SYSROOT_DIR/Frameworks"
SYSROOT_ABS="$(realpath "$SYSROOT_DIR")"

STIKJIT_SRC="$WORK_DIR/StikJIT"
rm -rf "$STIKJIT_SRC"
git clone --depth 1 --branch "$STIKJIT_TAG" "$STIKJIT_REPO" "$STIKJIT_SRC"
git -C "$STIKJIT_SRC" apply "$PATCHES_DIR/stikjit-$STIKJIT_TAG.patch"

(
    cd "$STIKJIT_SRC"
    xcodegen generate
    xcodebuild archive \
        -project StikJIT.xcodeproj \
        -scheme StikJIT \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath build/StikJIT-iOS \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        CODE_SIGNING_ALLOWED=NO \
        -quiet
)

DST="$SYSROOT_ABS/Frameworks/StikJIT.framework"
rm -rf "$DST"
ditto "$STIKJIT_SRC/build/StikJIT-iOS.xcarchive/Products/Library/Frameworks/StikJIT.framework" "$DST"
