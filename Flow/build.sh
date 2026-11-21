#!/bin/zsh
# Compile l'app et l'installe dans ~/Applications
set -e
cd "$(dirname "$0")"
NAME="Flow"; EXE=Flow; ID=com.roman.flow
APP="build/$NAME.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O main.swift ../Canyon/Canyon.swift -o "$APP/Contents/MacOS/$EXE"
# icône Liquid Glass : AppIcon.icon (format Icon Composer) compilé par actool de Xcode
[ -d AppIcon.icon ] || swift icon.swift AppIcon.icon
/Applications/Xcode.app/Contents/Developer/usr/bin/actool "$PWD/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon \
  --platform macosx --target-device mac --minimum-deployment-target 26.0 --output-partial-info-plist "$PWD/build/icon.plist" >/dev/null
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key><string>$NAME</string>
	<key>CFBundleExecutable</key><string>$EXE</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$ID</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP"
rm -rf ~/Applications/"$NAME.app" && cp -R "$APP" ~/Applications/
rm -rf build   # sinon Spotlight voit une 2e copie de l'app
echo "OK -> ~/Applications/$NAME.app"
