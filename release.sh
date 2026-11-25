#!/bin/bash
# Release Utter to GitHub and update Homebrew tap
# Usage: ./release.sh 1.1.0

set -e

# Config
REPO="Ram902-bot/utter"
TAP_REPO="Ram902-bot/homebrew-tap"
APP_PATH="build/Release/Build/Products/Release/Utter.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check version argument
if [ -z "$1" ]; then
    echo -e "${RED}Usage: ./release.sh <version>${NC}"
    echo "Example: ./release.sh 1.1.0"
    exit 1
fi

VERSION="$1"
TAG="v$VERSION"

echo -e "${BLUE}Releasing Utter $TAG${NC}"
echo ""

# Check if app exists
if [ ! -d "$SCRIPT_DIR/$APP_PATH" ]; then
    echo -e "${RED}Error: App not found at $APP_PATH${NC}"
    echo "Build the app in Xcode first (Product > Archive or Release build)"
    exit 1
fi

# Check if tag already exists
if git tag -l | grep -q "^$TAG$"; then
    echo -e "${RED}Error: Tag $TAG already exists${NC}"
    exit 1
fi

# Create zip
echo -e "${BLUE}1. Creating zip...${NC}"
ZIP_PATH="$SCRIPT_DIR/Utter-$VERSION.zip"
cd "$SCRIPT_DIR/$(dirname "$APP_PATH")"
zip -r "$ZIP_PATH" Utter.app
cd "$SCRIPT_DIR"
echo -e "${GREEN}   Created: Utter-$VERSION.zip${NC}"

# Get SHA256
SHA256=$(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)
echo -e "${GREEN}   SHA256: $SHA256${NC}"

# Create tag and push
echo -e "${BLUE}2. Creating git tag...${NC}"
git tag "$TAG"
git push origin "$TAG"
echo -e "${GREEN}   Pushed tag $TAG${NC}"

# Create GitHub release
echo -e "${BLUE}3. Creating GitHub release...${NC}"
gh release create "$TAG" "$ZIP_PATH" \
    --repo "$REPO" \
    --title "Utter $TAG" \
    --notes "Release $VERSION"
echo -e "${GREEN}   Release created: https://github.com/$REPO/releases/tag/$TAG${NC}"

# Update Homebrew tap
echo -e "${BLUE}4. Updating Homebrew tap...${NC}"
TAP_PATH="/opt/homebrew/Library/Taps/ram902-bot/homebrew-tap"

if [ ! -d "$TAP_PATH" ]; then
    echo "   Tapping Ram902-bot/tap..."
    brew tap Ram902-bot/tap
fi

cd "$TAP_PATH"
git pull origin main

# Update cask file
CASK_FILE="$TAP_PATH/Casks/utter.rb"
sed -i '' "s/version \".*\"/version \"$VERSION\"/" "$CASK_FILE"
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" "$CASK_FILE"

git add Casks/utter.rb
git commit -m "Update utter to $VERSION"
git push origin main
echo -e "${GREEN}   Homebrew tap updated${NC}"

# Cleanup
rm "$ZIP_PATH"

echo ""
echo -e "${GREEN}Done! Utter $TAG released.${NC}"
echo ""
echo "Users can now run:"
echo "  brew upgrade --cask utter"
echo ""
echo "Or new installs:"
echo "  brew install --cask Ram902-bot/tap/utter"
