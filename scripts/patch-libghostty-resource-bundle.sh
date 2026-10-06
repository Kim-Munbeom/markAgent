#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: patch-libghostty-resource-bundle.sh <libghostty-spm-checkout>" >&2
    exit 64
fi

CHECKOUT_DIR="$1"
EXPECTED_REVISION="356f730bec03281fc7b83666a129b0246137ea26"
PATCHED_SOURCE="$(cd "$(dirname "$0")" && pwd)/patches/GhosttyRuntimeResources.swift"
TARGET_SOURCE="$CHECKOUT_DIR/Sources/GhosttyTerminal/Configuration/GhosttyRuntimeResources.swift"
PATCH_DIR="$(dirname "$PATCHED_SOURCE")"
SEARCH_PATCH="$PATCH_DIR/libghostty-search-callbacks.patch"
OPEN_URL_PATCH="$PATCH_DIR/libghostty-open-url-handled.patch"
MOUSE_SHAPE_PATCH="$PATCH_DIR/libghostty-mouse-shape-callback.patch"
ACTUAL_REVISION="$(git -C "$CHECKOUT_DIR" rev-parse HEAD)"

if [ "$ACTUAL_REVISION" != "$EXPECTED_REVISION" ]; then
    echo "error: unsupported libghostty-spm revision: $ACTUAL_REVISION" >&2
    exit 1
fi

# 동일 리비전에서만 적용하고, 반복 번들 빌드에서는 이미 적용된 패치를 유지한다.
if ! git -C "$CHECKOUT_DIR" apply --reverse --check "$SEARCH_PATCH" 2>/dev/null; then
    git -C "$CHECKOUT_DIR" apply --check "$SEARCH_PATCH"
    git -C "$CHECKOUT_DIR" apply "$SEARCH_PATCH"
fi
if ! git -C "$CHECKOUT_DIR" apply --reverse --check "$OPEN_URL_PATCH" 2>/dev/null; then
    git -C "$CHECKOUT_DIR" apply --check "$OPEN_URL_PATCH"
    git -C "$CHECKOUT_DIR" apply "$OPEN_URL_PATCH"
fi
if ! git -C "$CHECKOUT_DIR" apply --reverse --check "$MOUSE_SHAPE_PATCH" 2>/dev/null; then
    git -C "$CHECKOUT_DIR" apply --check "$MOUSE_SHAPE_PATCH"
    git -C "$CHECKOUT_DIR" apply "$MOUSE_SHAPE_PATCH"
fi
cp -f "$PATCH_DIR/TerminalSurfaceMouseShapeDelegate.swift" \
    "$CHECKOUT_DIR/Sources/GhosttyTerminal/Surface/TerminalSurfaceMouseShapeDelegate.swift"
cp -f "$PATCH_DIR/TerminalSurfaceSearchDelegate.swift" \
    "$CHECKOUT_DIR/Sources/GhosttyTerminal/Surface/TerminalSurfaceSearchDelegate.swift"
cp -f "$PATCH_DIR/AppTerminalView+MouseCapture.swift" \
    "$CHECKOUT_DIR/Sources/GhosttyTerminal/Platform/AppKit/AppTerminalView+MouseCapture.swift"
cp -f "$PATCHED_SOURCE" "$TARGET_SOURCE"
