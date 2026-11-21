#!/bin/zsh
# Construit Etagere.app et l'installe dans ~/Applications
set -e
cd "$(dirname "$0")"
APP=build/Etagere.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O main.swift ../Canyon/Canyon.swift -o "$APP/Contents/MacOS/Etagere"

# Icône Liquid Glass : AppIcon.icon (format Icon Composer) compilé par actool de Xcode
[ -d AppIcon.icon ] || swift icon.swift AppIcon.icon
/Applications/Xcode.app/Contents/Developer/usr/bin/actool "$PWD/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon \
  --platform macosx --target-device mac --minimum-deployment-target 26.0 --output-partial-info-plist "$PWD/build/icon.plist" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Étagère</string>
  <key>CFBundleDisplayName</key><string>Étagère</string>
  <key>CFBundleIdentifier</key><string>fr.roman.etagere</string>
  <key>CFBundleExecutable</key><string>Etagere</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
pkill -x Etagere 2>/dev/null || true
rm -rf ~/Applications/Etagere.app
cp -R "$APP" ~/Applications/
echo "OK : ~/Applications/Etagere.app"
