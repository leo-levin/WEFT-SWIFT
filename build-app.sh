#!/bin/bash
# Build SWeft as a macOS .app bundle

set -e

APP_NAME="SWeft"
BUILD_DIR=".build/release"
APP_BUNDLE="WEFT.app"
ICON_SVG="weft.icon/Assets/Image.svg"
ICONSET="AppIcon.iconset"

echo "Building release binary..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy bundle resources (JS files)
if [ -d "$BUILD_DIR/SWeft_SWeftLib.bundle" ]; then
    cp -r "$BUILD_DIR/SWeft_SWeftLib.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

# Create icon from PNG if it exists
ICON_PNG="icon.png"
if [ -f "$ICON_PNG" ]; then
    echo "Creating app icon from $ICON_PNG..."
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"

    # Generate all required sizes from the source PNG
    sips -z 16 16 "$ICON_PNG" --out "$ICONSET/icon_16x16.png" > /dev/null
    sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" > /dev/null
    sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_32x32.png" > /dev/null
    sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" > /dev/null
    sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" > /dev/null
    sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
    sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" > /dev/null
    sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
    sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" > /dev/null
    sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" > /dev/null

    # Convert to icns
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    echo "Icon created successfully"
else
    echo "No icon.png found. Place a 1024x1024 PNG named 'icon.png' in this folder to add an app icon."
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SWeft</string>
    <key>CFBundleIdentifier</key>
    <string>com.weft.weft</string>
    <key>CFBundleName</key>
    <string>WEFT</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>SWeft uses the camera for real-time visual effects.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>SWeft uses the microphone for audio input.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>WEFT Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.weft.weft-source</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.weft.weft-source</string>
            <key>UTTypeDescription</key>
            <string>WEFT Source File</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.source-code</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>weft</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# Ad-hoc code sign the app (allows running without "damaged" errors)
echo "Code signing app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done! App bundle created at: $APP_BUNDLE"
echo "You can double-click it or run: open $APP_BUNDLE"
echo ""
echo "Note: Recipients may need to run: xattr -cr $APP_BUNDLE"
