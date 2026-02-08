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

echo "Creating GitHub release '$VERSION'..."
gh release create "$VERSION" WEFT.zip \
    --title "WEFT $VERSION" \
    --notes "Install with: \`curl -fsSL https://raw.githubusercontent.com/leo-levin/WEFT-SWIFT/master/install.sh | bash\`"

echo ""
echo "Done! Release published."
echo "Install command: curl -fsSL https://raw.githubusercontent.com/leo-levin/WEFT-SWIFT/master/install.sh | bash"
