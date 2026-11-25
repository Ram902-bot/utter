#!/bin/bash
# Install the latest Debug build of Utter for local testing.
# Replaces the app's contents in place so it works without admin rights on /Applications.

set -e

BUILD=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Utter-*/Build/Products/Debug/Utter.app 2>/dev/null | head -1)
if [ -z "$BUILD" ]; then
    echo "Error: Build not found. Run 'xcodebuild -scheme Utter build' first."
    exit 1
fi

if [ -w /Applications ] || [ -d /Applications/Utter.app ]; then
    DEST="/Applications/Utter.app"
else
    mkdir -p "$HOME/Applications"
    DEST="$HOME/Applications/Utter.app"
fi

pkill -x Utter 2>/dev/null || true
sleep 0.5

mkdir -p "$DEST"
rm -rf "$DEST/Contents"
cp -R "$BUILD/Contents" "$DEST/"

echo "Installed to $DEST"
echo "Note: debug builds are ad-hoc signed, so macOS asks for Accessibility again after each install."
open "$DEST"
