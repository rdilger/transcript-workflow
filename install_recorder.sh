#!/bin/bash
# Kompiliert und installiert die Recorder Menüleisten-App

APP_NAME="Recorder"
APP_DIR="$HOME/Applications/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "⏳ Kompiliere App..."

mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Entitlements für Audio-Zugriff
cat > /tmp/recorder.entitlements << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

# Swift kompilieren
swiftc ~/Downloads/RecorderMenuBar.swift \
    -o "$MACOS/$APP_NAME" \
    -framework AppKit \
    -framework UserNotifications \
    2>&1

if [ $? -ne 0 ]; then
    echo "❌ Kompilierung fehlgeschlagen"
    exit 1
fi

# Entitlements anwenden
codesign --force --sign - --entitlements /tmp/recorder.entitlements "$MACOS/$APP_NAME"

# Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Recorder</string>
    <key>CFBundleIdentifier</key>
    <string>com.rapha.recorder</string>
    <key>CFBundleName</key>
    <string>Recorder</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Recorder benötigt Audio-Zugriff für Aufnahmen.</string>
</dict>
</plist>
PLIST

echo "✅ Fertig. Starten mit:"
echo "   open ~/Applications/Recorder.app"
