#!/bin/bash
# WEFT Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/leo-levin/WEFT-SWIFT/master/install.sh | bash

set -e

echo "Installing WEFT..."

# Create temp directory
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "Downloading WEFT..."
curl -fsSL -o WEFT.zip https://github.com/leo-levin/WEFT-SWIFT/releases/latest/download/WEFT.zip

echo "Extracting..."
unzip -q WEFT.zip

echo "Removing quarantine..."
xattr -cr WEFT.app

echo "Installing to /Applications..."
rm -rf /Applications/WEFT.app
mv WEFT.app /Applications/

# Cleanup
cd /
rm -rf "$TMPDIR"

echo ""
echo "Done! WEFT installed to /Applications/WEFT.app"
echo "Run with: open /Applications/WEFT.app"
