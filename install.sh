#!/bin/bash
# WEFT Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/leo-levin/WEFT-SWIFT/master/install.sh | bash

set -e

echo "Installing WEFT..."

# Check for Swift
if ! command -v swift &> /dev/null; then
    echo "Error: Swift is required. Install Xcode or Xcode Command Line Tools."
    echo "Run: xcode-select --install"
    exit 1
fi

# Create temp directory
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "Downloading source..."
curl -fsSL https://github.com/leo-levin/WEFT-SWIFT/archive/refs/heads/master.tar.gz | tar xz

cd WEFT-SWIFT-master

echo "Building WEFT (this may take a minute)..."
./build-app.sh

echo "Installing to /Applications..."
rm -rf /Applications/WEFT.app
mv WEFT.app /Applications/

# Cleanup
cd /
rm -rf "$TMPDIR"

echo ""
echo "Done! WEFT installed to /Applications/WEFT.app"
echo "Run with: open /Applications/WEFT.app"
