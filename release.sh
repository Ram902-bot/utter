#!/bin/bash
# Build, package and (optionally) publish an Utter release.
#
#   ./release.sh 3.0.0            build + zip + checks only (nothing published)
#   ./release.sh 3.0.0 --publish  also tag, create the GitHub release and update the Homebrew tap
#
# The tap gets two casks pointing at the same zip:
#   utter     the real cask for new installs
#   evertalk  bridge for people who installed Evertalk: their in-app updater reads this cask,
#             so bumping it moves them to Utter. Kept in sync on every release.

set -e

REPO="Ram902-bot/utter"
TAP_REPO="Ram902-bot/homebrew-tap"
TAP_PATH="$(brew --repository 2>/dev/null)/Library/Taps/ram902-bot/homebrew-tap"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/release"
APP="$BUILD_DIR/Build/Products/Release/Utter.app"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "${BLUE}$1${NC}"; }
ok()   { echo -e "${GREEN}   $1${NC}"; }
fail() { echo -e "${RED}Error: $1${NC}"; exit 1; }

VERSION="$1"
PUBLISH="$2"
[ -z "$VERSION" ] && fail "usage: ./release.sh <version> [--publish]"
TAG="v$VERSION"
ZIP="$SCRIPT_DIR/build/Utter-$VERSION.zip"
cd "$SCRIPT_DIR"

# --- Checks -------------------------------------------------------------
step "1. Checks"
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Utter/Info.plist)
[ "$PLIST_VERSION" = "$VERSION" ] || fail "Info.plist says $PLIST_VERSION, not $VERSION"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "release from main"
git diff --quiet && git diff --cached --quiet || fail "uncommitted changes"
if [ "$PUBLISH" = "--publish" ] && git ls-remote --tags origin | grep -q "refs/tags/$TAG$"; then
    fail "tag $TAG already exists on GitHub"
fi
ok "version $VERSION, clean main"

# --- Build --------------------------------------------------------------
step "2. Building Release"
xcodebuild -project Utter.xcodeproj -scheme Utter -configuration Release \
    -derivedDataPath "$BUILD_DIR" clean build >/dev/null 2>&1 || fail "build failed (run xcodebuild without >/dev/null to see why)"
codesign --verify --deep --strict "$APP" || fail "signature check failed"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "audio-input" || fail "microphone entitlement missing"
strings "$APP/Contents/MacOS/Utter" | grep -q "UTTER_DOCS_RENDER" && fail "debug render mode found in Release build"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$BUILT_VERSION" = "$VERSION" ] || fail "built app is $BUILT_VERSION"
ok "built, signed, mic entitlement present, no debug code"

# --- Package ------------------------------------------------------------
step "3. Packaging"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
ok "$(basename "$ZIP") ($(du -h "$ZIP" | cut -f1)), sha256 $SHA256"

write_casks() {
    local dir="$1"
    cat > "$dir/utter.rb" <<EOF
cask "utter" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/Utter-#{version}.zip"
  name "Utter"
  desc "Private on-device voice-to-text (formerly Evertalk)"
  homepage "https://github.com/$REPO"

  conflicts_with cask: "evertalk"

  app "Utter.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Utter.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Utter",
    "~/Library/Preferences/com.ram902.utter.plist",
  ]
end
EOF
    cat > "$dir/evertalk.rb" <<EOF
# Evertalk is now Utter. This cask stays so existing Evertalk installs see the update
# in their menu bar and move to Utter. New installs: brew install --cask $(echo "$TAP_REPO" | tr '[:upper:]' '[:lower:]' | sed 's#/homebrew-#/#')/utter
cask "evertalk" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/Utter-#{version}.zip"
  name "Utter (formerly Evertalk)"
  desc "Private on-device voice-to-text, now called Utter"
  homepage "https://github.com/$REPO"

  conflicts_with cask: "utter"

  app "Utter.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Utter.app"],
                   sudo: false
    # Evertalk's updater tries to reopen Evertalk.app, which is gone, so open Utter instead
    system_command "/usr/bin/open",
                   args: ["-a", "#{appdir}/Utter.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Evertalk",
    "~/Library/Application Support/Utter",
    "~/Library/Preferences/com.ram902.evertalk.plist",
    "~/Library/Preferences/com.ram902.utter.plist",
  ]
end
EOF
}

STAGE="$SCRIPT_DIR/build/casks"
mkdir -p "$STAGE"
write_casks "$STAGE"
ok "casks written to build/casks for review"

if [ "$PUBLISH" != "--publish" ]; then
    echo ""
    echo "Dry run done. Nothing was published. Review build/casks/*.rb, then run:"
    echo "  ./release.sh $VERSION --publish"
    exit 0
fi

# --- Publish ------------------------------------------------------------
step "4. Tagging $TAG"
git tag "$TAG"
git push -q origin "$TAG"
ok "pushed tag"

step "5. GitHub release"
NOTES="$SCRIPT_DIR/build/release-notes.md"
[ -f "$SCRIPT_DIR/RELEASE_NOTES.md" ] && cp "$SCRIPT_DIR/RELEASE_NOTES.md" "$NOTES" || echo "Utter $VERSION" > "$NOTES"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Utter $VERSION" --notes-file "$NOTES"
ok "https://github.com/$REPO/releases/tag/$TAG"

# Wait until the download URL serves the exact file Homebrew will check
for i in $(seq 1 12); do
    REMOTE_SHA=$(curl -sL "https://github.com/$REPO/releases/download/$TAG/Utter-$VERSION.zip" | shasum -a 256 | cut -d' ' -f1)
    [ "$REMOTE_SHA" = "$SHA256" ] && break
    sleep 5
done
[ "$REMOTE_SHA" = "$SHA256" ] || fail "download URL doesn't serve the uploaded zip yet; tap NOT updated"
ok "download verified"

step "6. Homebrew tap"
[ -d "$TAP_PATH" ] || brew tap Ram902-bot/tap
cd "$TAP_PATH"
git pull -q origin main
write_casks "$TAP_PATH/Casks"
# Only the postflight style note is allowed: postflight_steps needs a recent Homebrew and runs sandboxed
STYLE=$(brew style --cask Casks/utter.rb Casks/evertalk.rb 2>&1 | grep -E "^Casks/" | grep -v -E "InstallSteps|OSDependsOn" || true)
[ -z "$STYLE" ] || { echo "$STYLE"; git checkout -q -- Casks; rm -f Casks/utter.rb; fail "brew style issues; tap NOT pushed"; }
git add Casks/utter.rb Casks/evertalk.rb
git commit -q -m "Utter $VERSION (evertalk cask now installs Utter)"
# Homebrew taps over HTTPS, which has no saved login; push over SSH like the main repo
git remote set-url --push origin "git@github.com:$TAP_REPO.git"
git push -q origin main || fail "tap commit made but NOT pushed. Fix access, then: cd \"$TAP_PATH\" && git push origin main"
ok "tap updated"

echo ""
echo -e "${GREEN}Done. Utter $TAG released.${NC}"
echo "  New installs:      brew trust --tap ram902-bot/tap && brew install --cask ram902-bot/tap/utter"
echo "  Evertalk users:    Update to $VERSION in the menu bar, or brew upgrade --cask evertalk"
