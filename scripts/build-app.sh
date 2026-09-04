#!/bin/zsh
# Builds AutoQuit.app WITHOUT Xcode — Command Line Tools only.
#
# The repo's .xcodeproj needs full Xcode; this script reproduces the essential
# parts of the Xcode build by hand:
#   1. swiftc compiles the two Swift files (target: macOS 13.3, Swift 5 mode).
#   2. Resources: since CLT has no actool, asset-catalog images are shipped as
#      loose files (NSImage(named:) finds those too) — the menu-bar SVG is
#      rasterized with CoreGraphics, the app icon becomes an .icns via iconutil.
#   3. Localizable.xcstrings is converted into per-language Localizable.strings.
#   4. Info.plist mirrors the target's INFOPLIST_KEY_* build settings.
#   5. Ad-hoc codesign (the entitlements file is empty), so it runs locally.
#
# Usage: scripts/build-app.sh   →  build/AutoQuit.app

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/AutoQuit.app"
VERSION="1.1.4"
BUILD="1"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling Swift (macOS 13.3 target)"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.3 \
    -o "$APP/Contents/MacOS/AutoQuit" \
    AutoQuit/ContentView.swift AutoQuit/AutoQuitApp.swift

echo "==> Copying asset images (loose files; CLT has no actool)"
cp AutoQuit/Assets.xcassets/Image.imageset/512.png "$APP/Contents/Resources/Image.png"

# Menu-bar icon: the imageset only contains an SVG (an X with round caps).
# Rasterize it exactly with CoreGraphics at 18pt × 4x, black on transparent —
# the app marks it as a template image, so only the alpha matters.
cat > /tmp/aq_menubar_icon.swift << 'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 72                       // 18pt at 4x
let scale = size / 18
let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.setLineWidth(2.6 * scale)
ctx.setLineCap(.round)
ctx.beginPath()
// SVG coordinates (origin top-left), flipped into CG's bottom-left origin.
ctx.move(to: CGPoint(x: 4.5 * scale, y: size - 4.5 * scale))
ctx.addLine(to: CGPoint(x: 13.5 * scale, y: size - 13.5 * scale))
ctx.move(to: CGPoint(x: 13.5 * scale, y: size - 4.5 * scale))
ctx.addLine(to: CGPoint(x: 4.5 * scale, y: size - 13.5 * scale))
ctx.strokePath()
let image = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
SWIFT
xcrun swiftc -O /tmp/aq_menubar_icon.swift -o /tmp/aq_menubar_icon
/tmp/aq_menubar_icon "$APP/Contents/Resources/MenuBarIcon.png"
rm -f /tmp/aq_menubar_icon.swift /tmp/aq_menubar_icon

# App icon: map the appiconset PNGs onto an iconset, then iconutil → .icns.
echo "==> Building AppIcon.icns"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
cp AutoQuit/Assets.xcassets/AppIcon.appiconset/16.png      "$ICONSET/icon_16x16.png"
cp AutoQuit/Assets.xcassets/AppIcon.appiconset/32.png      "$ICONSET/icon_16x16@2x.png"
cp "AutoQuit/Assets.xcassets/AppIcon.appiconset/32 1.png"  "$ICONSET/icon_32x32.png"
cp AutoQuit/Assets.xcassets/AppIcon.appiconset/64.png      "$ICONSET/icon_32x32@2x.png"
cp AutoQuit/Assets.xcassets/AppIcon.appiconset/128.png     "$ICONSET/icon_128x128.png"
cp AutoQuit/Assets.xcassets/AppIcon.appiconset/256.png     "$ICONSET/icon_128x128@2x.png"
cp "AutoQuit/Assets.xcassets/AppIcon.appiconset/256 1.png" "$ICONSET/icon_256x256.png"
cp AutoQuit/Assets.xcassets/AppIcon.appiconset/512.png     "$ICONSET/icon_256x256@2x.png"
cp "AutoQuit/Assets.xcassets/AppIcon.appiconset/512 1.png" "$ICONSET/icon_512x512.png"
cp AutoQuit/Assets.xcassets/AppIcon.appiconset/1024.png    "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Localizable.xcstrings → one Localizable.strings per language. Xcode compiles
# the catalog into these at build time; without actool we generate them direct.
echo "==> Generating Localizable.strings (en, nl, zh-Hans)"
python3 - "$APP/Contents/Resources" << 'PYTHON'
import json, sys, os

resources = sys.argv[1]
catalog = json.load(open('AutoQuit/Localizable.xcstrings'))['strings']

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def write_strings(lang, entries):
    path = os.path.join(resources, f'{lang}.lproj')
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, 'Localizable.strings'), 'w', encoding='utf-16') as f:
        for key, value in sorted(entries.items()):
            f.write(f'"{esc(key)}" = "{esc(value)}";\n')

for lang in ('en', 'nl', 'zh-Hans'):
    entries = {}
    for key, entry in catalog.items():
        if lang == 'en':
            entries[key] = key                      # source language: key is the text
            continue
        unit = entry.get('localizations', {}).get(lang, {}).get('stringUnit')
        if unit is not None:                        # omit untranslated → falls back to en
            entries[key] = unit['value']
    write_strings(lang, entries)
    print(f'    {lang}.lproj/Localizable.strings: {len(entries)} entries')
PYTHON

echo "==> Writing Info.plist and PkgInfo"
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>AutoQuit</string>
	<key>CFBundleExecutable</key>
	<string>AutoQuit</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.AutoQuit</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>AutoQuit</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.3</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Needed to close apps</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
du -sh "$APP"
