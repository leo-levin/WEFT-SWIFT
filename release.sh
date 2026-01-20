#!/bin/bash
# Build and publish a new WEFT release to GitHub
# Usage: ./release.sh [version]
# Example: ./release.sh 1.0.1

set -e

VERSION=${1:-"latest"}

echo "Building WEFT..."
./build-app.sh

echo "Creating zip..."
rm -f WEFT.zip
zip -r WEFT.zip WEFT.app

echo "Deleting previous 'latest' release if it exists..."
gh release delete latest --yes 2>/dev/null || true
git push origin :refs/tags/latest 2>/dev/null || true

echo "Creating GitHub release..."
gh release create latest WEFT.zip \
    --title "WEFT $VERSION" \
    --notes "Install with: \`curl -fsSL https://raw.githubusercontent.com/leo-levin/WEFT-SWIFT/master/install.sh | bash\`"

echo ""
echo "Done! Release published."
echo "Install command: curl -fsSL https://raw.githubusercontent.com/leo-levin/WEFT-SWIFT/master/install.sh | bash"
