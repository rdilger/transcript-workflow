#!/bin/bash
# Erstellt eine macOS Menüleisten-App für die Aufnahme

APP_DIR="$HOME/Applications/Recorder.app"
SCRIPT_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

mkdir -p "$SCRIPT_DIR"
mkdir -p "$RESOURCES_DIR"

# Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>recorder</string>
    <key>CFBundleIdentifier</key>
    <string>com.rapha.recorder</string>
    <key>CFBundleName</key>
    <string>Recorder</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Haupt-Script
cat > "$SCRIPT_DIR/recorder" << 'RECORDER'
#!/bin/bash

source ~/.zshrc

AUDIO_DEVICE="8"
AUDIO_INPUT="$HOME/Desktop/AudioInput"
PID_FILE="/tmp/recorder.pid"
MODEL_FILE="/tmp/recorder_model"

# Standard-Modell
[ -f "$MODEL_FILE" ] || echo "small" > "$MODEL_FILE"

get_model() { cat "$MODEL_FILE"; }

is_recording() { [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; }

start_recording() {
    DATE=$(date +%Y-%m-%d_%H-%M)
    OUTPUT="$AUDIO_INPUT/recording_${DATE}.m4a"
    /opt/homebrew/bin/ffmpeg -f avfoundation -i ":${AUDIO_DEVICE}" "$OUTPUT" &>/tmp/ffmpeg.log &
    echo $! > "$PID_FILE"
}

stop_recording() {
    if [ -f "$PID_FILE" ]; then
        kill -INT $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
        # Modell in transcribe.sh aktualisieren
        MODEL=$(get_model)
        sed -i '' "s/WHISPER_MODEL=.*/WHISPER_MODEL=\"$MODEL\"/" ~/scripts/transcribe.sh
    fi
}

# AppleScript Menü
while true; do
    MODEL=$(get_model)

    if is_recording; then
        CHOICE=$(osascript << EOF
tell application "System Events"
    set choice to button returned of (display dialog "🔴 Aufnahme läuft..." buttons {"⏹ Stoppen", "Abbrechen"} default button "⏹ Stoppen" with title "Recorder")
end tell
choice
EOF
)
        if [ "$CHOICE" = "⏹ Stoppen" ]; then
            stop_recording
            osascript -e 'display notification "Wird transkribiert..." with title "✅ Aufnahme gespeichert"'
        fi
    else
        CHOICE=$(osascript << EOF
tell application "System Events"
    set choice to button returned of (display dialog "Modell: $MODEL" buttons {"▶️ Aufnahme starten", "⚙️ Modell ändern", "Beenden"} default button "▶️ Aufnahme starten" with title "🎙 Recorder")
end tell
choice
EOF
)
        case "$CHOICE" in
            "▶️ Aufnahme starten")
                start_recording
                osascript -e 'display notification "Aufnahme läuft..." with title "🔴 REC"'
                ;;
            "⚙️ Modell ändern")
                NEW_MODEL=$(osascript << EOF
tell application "System Events"
    set choice to button returned of (display dialog "Whisper Modell wählen:" buttons {"tiny", "small", "medium"} default button "$MODEL" with title "⚙️ Modell")
end tell
choice
EOF
)
                echo "$NEW_MODEL" > "$MODEL_FILE"
                ;;
            "Beenden")
                stop_recording
                exit 0
                ;;
        esac
    fi
    sleep 0.5
done
RECORDER

chmod +x "$SCRIPT_DIR/recorder"

echo "✅ App erstellt: $APP_DIR"
echo "   Öffne Finder → Programme → Recorder.app"
echo "   Oder im Terminal: open ~/Applications/Recorder.app"
