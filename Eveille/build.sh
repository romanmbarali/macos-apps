#!/bin/zsh
# Compile l'app et l'installe dans ~/Applications
set -e
cd "$(dirname "$0")"
NAME="Éveillé"; EXE=Eveille; ID=com.roman.eveille
APP="build/$NAME.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library main.swift ../Canyon/Canyon.swift -o "$APP/Contents/MacOS/$EXE"
# icône Liquid Glass : AppIcon.icon (format Icon Composer) compilé par actool de Xcode
[ -d AppIcon.icon ] || swift icon.swift AppIcon.icon
/Applications/Xcode.app/Contents/Developer/usr/bin/actool "$PWD/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon \
  --platform macosx --target-device mac --minimum-deployment-target 26.0 --output-partial-info-plist "$PWD/build/icon.plist" >/dev/null
cp installer-garde.sh "$APP/Contents/Resources/"
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
	<key>CFBundleShortVersionString</key><string>1.1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP"
rm -rf ~/Applications/"$NAME.app" && cp -R "$APP" ~/Applications/
rm -rf build   # sinon Spotlight voit une 2e copie de l'app

# règle sudo (une seule fois) : pmset disablesleep 0/1 sans mot de passe
if [ ! -f /etc/sudoers.d/eveille ]; then
  osascript -e "do shell script \"/bin/sh '$PWD/installer-garde.sh' '$USER'\" with administrator privileges"
fi

# garde : toutes les 15 s, si l'app n'est pas lancée et que la veille est bloquée, on la remet
AGENT=~/Library/LaunchAgents/com.roman.eveille.garde.plist
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.roman.eveille.garde</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string><string>-c</string>
		<string>/usr/bin/pgrep -xq Eveille || ! /usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>15</integer>
</dict>
</plist>
PLIST
launchctl bootout gui/$(id -u)/com.roman.eveille.garde 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$AGENT"
echo "OK -> ~/Applications/$NAME.app"
