#!/bin/bash
# transcribe.sh — Audio → Transkript + Summary → Obsidian

VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
TRANSCRIPT_FOLDER="Transcripts"
AUDIO_WATCH_FOLDER="$HOME/Desktop/AudioInput"
PROCESSED_FOLDER="$HOME/Desktop/AudioInput/processed"
OUTPUT_DIR="$VAULT/$TRANSCRIPT_FOLDER"
WHISPER_MODEL="small"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check_dependencies() {
  local missing=()
  command -v whisper &>/dev/null || missing+=("whisper (brew install openai-whisper)")
  command -v ffmpeg &>/dev/null  || missing+=("ffmpeg (brew install ffmpeg)")

  if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo -e "${RED}❌ ANTHROPIC_API_KEY nicht gesetzt.${NC}"
    exit 1
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}❌ Fehlende Tools:${NC}"
    for dep in "${missing[@]}"; do echo "  - $dep"; done
    exit 1
  fi
}

get_summary() {
  local transcript="$1"
  local response
  response=$(curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{
      \"model\": \"claude-haiku-4-5-20251001\",
      \"max_tokens\": 1024,
      \"messages\": [{
        \"role\": \"user\",
        \"content\": \"Analysiere dieses Transkript und erstelle eine strukturierte Zusammenfassung. Antworte in der gleichen Sprache wie das Transkript.\n\nFormat:\n## Zusammenfassung\nKurze Übersicht in 2-3 Sätzen.\n\n## Kernpunkte\n- Wichtigste Punkte als Bullets\n\n## Action Items\n- Konkrete Aufgaben oder nächste Schritte (falls vorhanden)\n\nTranskript:\n$transcript\"
      }]
    }")

  echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'content' in data:
    print(data['content'][0]['text'])
else:
    print('Zusammenfassung nicht verfügbar.')
"
}

process_file() {
  local audio_file="$1"
  local filename=$(basename "$audio_file")
  local basename="${filename%.*}"
  local date=$(date +%Y-%m-%d)
  local time=$(date +%H-%M)
  local output_file="$OUTPUT_DIR/${date}_${basename}.md"
  local tmp_dir=$(mktemp -d)

  echo -e "${YELLOW}⏳ Verarbeite:${NC} $filename"
  mkdir -p "$OUTPUT_DIR"
  mkdir -p "$PROCESSED_FOLDER"

  echo "   🎙️  Transkribiere..."
  whisper "$audio_file" \
    --model "$WHISPER_MODEL" \
    --output_format txt \
    --output_dir "$tmp_dir" 2>&1

  local txt_file=$(find "$tmp_dir" -name "*.txt" | head -1)

  if [ ! -f "$txt_file" ]; then
    echo -e "${RED}   ❌ Transkription fehlgeschlagen${NC}"
    rm -rf "$tmp_dir"
    return 1
  fi

  local transcript=$(cat "$txt_file")

  echo "   🤖 Erstelle Zusammenfassung..."
  local summary=$(get_summary "$transcript")

  cat > "$output_file" << EOF
---
date: $date
time: $time
type: transcript
source: $filename
model: $WHISPER_MODEL
tags: [transcript]
---

$summary

---

## Vollständiges Transkript

$transcript
EOF

  # Verarbeitete Datei verschieben (mit Retry für iCloud)
  local retries=5
  local moved=false
  while [ $retries -gt 0 ]; do
    if mv "$audio_file" "$PROCESSED_FOLDER/$filename" 2>/dev/null; then
      moved=true
      break
    fi
    sleep 2
    retries=$((retries - 1))
  done

  if [ "$moved" = true ]; then
    echo -e "${GREEN}   📁 Archiviert:${NC} processed/$filename"
  else
    echo -e "${RED}   ⚠️ Verschieben fehlgeschlagen:${NC} $filename"
  fi
}

start_watch() {
  mkdir -p "$AUDIO_WATCH_FOLDER"
  mkdir -p "$PROCESSED_FOLDER"
  echo -e "${GREEN}👁️  Watch-Modus aktiv${NC}"
  echo "   Überwache: $AUDIO_WATCH_FOLDER"
  echo "   Output:    $OUTPUT_DIR"
  echo "   Archiv:    $PROCESSED_FOLDER"
  echo "   (Ctrl+C zum Beenden)"
  echo ""

  fswatch -0 "$AUDIO_WATCH_FOLDER" | while IFS= read -r -d '' file; do
    if [[ "$file" =~ \.(mp3|mp4|m4a|wav|ogg|flac|webm|opus)$ ]]; then
      # Nur Dateien im Hauptordner verarbeiten, nicht im processed/ Unterordner
      if [[ "$file" != *"/processed/"* ]]; then
        # Warten bis Datei fertig geschrieben ist (Größe stabil)
        sleep 2
        prev_size=0
        curr_size=$(stat -f%z "$file" 2>/dev/null || echo 0)
        while [ "$curr_size" != "$prev_size" ]; do
          sleep 1
          prev_size=$curr_size
          curr_size=$(stat -f%z "$file" 2>/dev/null || echo 0)
        done
        [ -f "$file" ] && process_file "$file"
      fi
    fi
  done
}

check_dependencies

case "$1" in
  --watch)
    command -v fswatch &>/dev/null || {
      echo -e "${RED}❌ fswatch fehlt. Installieren mit: brew install fswatch${NC}"
      exit 1
    }
    start_watch
    ;;
  "")
    echo "Usage:"
    echo "  ./transcribe.sh audio.mp3"
    echo "  ./transcribe.sh --watch"
    exit 1
    ;;
  *)
    process_file "$1"
    ;;
esac
