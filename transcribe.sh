#!/bin/bash
# transcribe.sh — Audio → Transkript + Summary → Obsidian

VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
TRANSCRIPT_FOLDER="Transcripts"
AUDIO_WATCH_FOLDER="$HOME/Desktop/AudioInput"
PROCESSED_FOLDER="$HOME/Desktop/AudioInput/processed"
OUTPUT_DIR="$VAULT/$TRANSCRIPT_FOLDER"
WHISPER_MODEL="small"
COSTS_LOG="$HOME/Desktop/AudioInput/costs.csv"

# Claude Haiku Preise (USD pro Token) — bei Preisänderung hier anpassen
HAIKU_PRICE_IN=0.0000008    # $0.80 / 1M Input-Tokens
HAIKU_PRICE_OUT=0.000004    # $4.00 / 1M Output-Tokens
EUR_USD=0.92

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── Hilfsfunktionen ──────────────────────────────────────────────────────────

notify() {
  local title="$1"
  local message="$2"
  osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

get_duration() {
  local audio_file="$1"
  local seconds
  seconds=$(ffprobe -v quiet -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$audio_file" 2>/dev/null)
  if [ -n "$seconds" ]; then
    printf "%d:%02d" $(( ${seconds%.*} / 60 )) $(( ${seconds%.*} % 60 ))
  else
    echo "unknown"
  fi
}

# Whisper-Modell aus Dateiname ableiten: meeting_medium.m4a → medium
model_from_filename() {
  local basename="$1"
  if [[ "$basename" =~ _(tiny|small|medium|large)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$WHISPER_MODEL"
  fi
}

check_dependencies() {
  local missing=()
  command -v whisper &>/dev/null || missing+=("whisper (brew install openai-whisper)")
  command -v ffmpeg  &>/dev/null || missing+=("ffmpeg (brew install ffmpeg)")

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

# ── API-Aufruf ───────────────────────────────────────────────────────────────

# Schreibt Summary auf stdout, Token-Nutzung als JSON nach $2
get_summary() {
  local transcript="$1"
  local usage_file="$2"
  USAGE_FILE="$usage_file" python3 -c "
import json, urllib.request, os, sys

transcript = sys.stdin.read()
usage_file = os.environ.get('USAGE_FILE', '')
prompt = '''Du analysierst Audio-Transkripte (Gespräche, Notizen, Memos). Antworte immer in der gleichen Sprache wie das Transkript.

Erstelle eine strukturierte Zusammenfassung im folgenden Format:

## Zusammenfassung
1-3 Sätze: Worum geht es? Was ist der Kern des Gesprächs?

## Kernpunkte
- Die wichtigsten Aussagen oder Themen als Bullets
- Mindestens 2, maximal 6 Punkte

## Action Items
- Konkrete Aufgaben oder Entscheidungen (nur wenn vorhanden, sonst weglassen)

Transkript:
''' + transcript

payload = json.dumps({
    'model': 'claude-haiku-4-5-20251001',
    'max_tokens': 1024,
    'messages': [{'role': 'user', 'content': prompt}]
}).encode()

req = urllib.request.Request(
    'https://api.anthropic.com/v1/messages',
    data=payload,
    headers={
        'x-api-key': os.environ['ANTHROPIC_API_KEY'],
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json'
    }
)
with urllib.request.urlopen(req) as r:
    data = json.load(r)
    if usage_file:
        with open(usage_file, 'w') as f:
            json.dump(data.get('usage', {}), f)
    print(data['content'][0]['text'])
" <<< "$transcript" 2>/dev/null || echo "Zusammenfassung nicht verfügbar."
}

calc_cost_eur() {
  local tokens_in="$1" tokens_out="$2"
  python3 -c "
cost_usd = $tokens_in * $HAIKU_PRICE_IN + $tokens_out * $HAIKU_PRICE_OUT
print(f'{cost_usd * $EUR_USD:.4f}')
"
}

# ── Verarbeitung ─────────────────────────────────────────────────────────────

process_file() {
  local audio_file="$1"
  local filename=$(basename "$audio_file")
  local basename="${filename%.*}"
  local date=$(date +%Y-%m-%d)
  local time=$(date +%H-%M)
  local model=$(model_from_filename "$basename")
  local output_file="$OUTPUT_DIR/${date}_${basename}.md"
  local tmp_dir=$(mktemp -d)

  echo -e "${YELLOW}⏳ Verarbeite:${NC} $filename (Modell: $model)"
  mkdir -p "$OUTPUT_DIR"
  mkdir -p "$PROCESSED_FOLDER"

  # Dauer ermitteln
  local duration
  duration=$(get_duration "$audio_file")

  echo "   🎙️  Transkribiere..."
  whisper "$audio_file" \
    --model "$model" \
    --output_format txt \
    --output_dir "$tmp_dir" 2>"$tmp_dir/whisper.log"

  local txt_file
  txt_file=$(find "$tmp_dir" -name "*.txt" | head -1)

  if [ ! -f "$txt_file" ]; then
    echo -e "${RED}   ❌ Transkription fehlgeschlagen${NC}"
    notify "❌ Transkription fehlgeschlagen" "$filename"
    rm -rf "$tmp_dir"
    return 1
  fi

  local transcript
  transcript=$(cat "$txt_file")

  # Sprache aus Whisper-Log
  local language
  language=$(grep -i "detected language" "$tmp_dir/whisper.log" \
    | sed 's/.*Detected language: //' | head -1 | tr -d '\r')
  [ -z "$language" ] && language="unknown"

  # Wörter zählen
  local word_count
  word_count=$(echo "$transcript" | wc -w | tr -d ' ')

  echo "   🤖 Erstelle Zusammenfassung..."
  local summary
  summary=$(get_summary "$transcript" "$tmp_dir/usage.json")

  # Token-Nutzung + Kosten
  local tokens_in=0 tokens_out=0 cost_eur="0.0000"
  if [ -f "$tmp_dir/usage.json" ]; then
    tokens_in=$(python3  -c "import json; print(json.load(open('$tmp_dir/usage.json')).get('input_tokens',  0))")
    tokens_out=$(python3 -c "import json; print(json.load(open('$tmp_dir/usage.json')).get('output_tokens', 0))")
    cost_eur=$(calc_cost_eur "$tokens_in" "$tokens_out")
  fi

  cat > "$output_file" << EOF
---
date: $date
time: $time
type: transcript
source: $filename
model: $model
duration: "$duration"
language: $language
word_count: $word_count
tokens_in: $tokens_in
tokens_out: $tokens_out
cost_eur: $cost_eur
tags: [transcript]
---

$summary

---

## Vollständiges Transkript

$transcript
EOF

  # Kosten-Log (CSV)
  if [ ! -f "$COSTS_LOG" ]; then
    echo "date,time,source,duration,language,word_count,tokens_in,tokens_out,cost_eur" > "$COSTS_LOG"
  fi
  echo "$date,$time,$filename,$duration,$language,$word_count,$tokens_in,$tokens_out,$cost_eur" >> "$COSTS_LOG"

  echo -e "${GREEN}   ✅ Gespeichert:${NC} ${date}_${basename}.md"
  echo "      Dauer: $duration | Sprache: $language | Wörter: $word_count"
  echo "      Tokens: ${tokens_in}↑ ${tokens_out}↓ | Kosten: ${cost_eur}€"
  notify "✅ Transkript fertig" "$filename · $duration · ${cost_eur}€"

  rm -rf "$tmp_dir"

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
      if [[ "$file" != *"/processed/"* ]]; then
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

# ── Einstieg ─────────────────────────────────────────────────────────────────

check_dependencies

case "$1" in
  --costs)
    if [ ! -f "$COSTS_LOG" ]; then
      echo "Noch keine Transkripte verarbeitet."
      exit 0
    fi
    python3 - "$COSTS_LOG" << 'PYEOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    print("Log ist leer.")
    sys.exit()
total_eur  = sum(float(r['cost_eur'])   for r in rows)
total_in   = sum(int(r['tokens_in'])    for r in rows)
total_out  = sum(int(r['tokens_out'])   for r in rows)
print(f"\n{'Datum':<12} {'Datei':<35} {'Dauer':<8} {'Tokens':>10}  {'Kosten':>8}")
print("─" * 80)
for r in rows:
    tokens = f"{r['tokens_in']}↑{r['tokens_out']}↓"
    print(f"{r['date']:<12} {r['source'][:34]:<35} {r['duration']:<8} {tokens:>10}  {float(r['cost_eur']):.4f}€")
print("─" * 80)
print(f"{'Gesamt: ' + str(len(rows)) + ' Transkripte':<57} {total_in}↑{total_out}↓  {total_eur:.4f}€\n")
PYEOF
    ;;
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
    echo "  ./transcribe.sh meeting_medium.m4a   # Modell per Dateiname"
    echo "  ./transcribe.sh --watch"
    echo "  ./transcribe.sh --costs              # Kosten-Übersicht"
    exit 1
    ;;
  *)
    process_file "$1"
    ;;
esac
