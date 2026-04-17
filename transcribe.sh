#!/bin/bash
# transcribe.sh — Audio → Transkript + Summary → Obsidian

VAULT="${VAULT:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault}"
TRANSCRIPT_FOLDER="${TRANSCRIPT_FOLDER:-Transcripts}"
AUDIO_WATCH_FOLDER="${AUDIO_WATCH_FOLDER:-$HOME/Desktop/AudioInput}"
PROCESSED_FOLDER="${PROCESSED_FOLDER:-$HOME/Desktop/AudioInput/processed}"
OUTPUT_DIR="$VAULT/$TRANSCRIPT_FOLDER"
WHISPER_MODEL="${WHISPER_MODEL:-small}"
COSTS_LOG="${COSTS_LOG:-$HOME/Desktop/AudioInput/costs.csv}"
PROCESSED_REGISTRY="${PROCESSED_REGISTRY:-$HOME/Desktop/AudioInput/.processed_registry}"

# Claude Haiku 4.5 Preise (USD pro Token) — bei Preisänderung hier anpassen
HAIKU_PRICE_IN=0.0000008         # $0.80 / 1M Input-Tokens (uncached)
HAIKU_PRICE_CACHE_WRITE=0.000001 # $1.00 / 1M Cache-Write-Tokens
HAIKU_PRICE_CACHE_READ=0.00000008 # $0.08 / 1M Cache-Read-Tokens (~90% günstiger)
HAIKU_PRICE_OUT=0.000004         # $4.00 / 1M Output-Tokens
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

diarization_available() {
  [ -n "$HF_TOKEN" ] && python3 -c "import pyannote.audio" 2>/dev/null
}

# Registry to prevent double-processing when iCloud re-triggers fswatch
is_processed() {
  [ -f "$PROCESSED_REGISTRY" ] && grep -qxF "$1" "$PROCESSED_REGISTRY"
}
mark_processed() {
  echo "$1" >> "$PROCESSED_REGISTRY"
}

check_dependencies() {
  local missing=()
  command -v whisper &>/dev/null || missing+=("whisper (brew install openai-whisper)")
  command -v ffmpeg  &>/dev/null || missing+=("ffmpeg (brew install ffmpeg)")
  python3 -c "import anthropic" 2>/dev/null || missing+=("anthropic (pip3 install anthropic)")

  if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo -e "${RED}❌ ANTHROPIC_API_KEY nicht gesetzt.${NC}"
    exit 1
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}❌ Fehlende Tools:${NC}"
    for dep in "${missing[@]}"; do echo "  - $dep"; done
    exit 1
  fi

  if diarization_available; then
    echo -e "${GREEN}   Speaker-Diarization aktiv${NC}"
  fi
}

# ── Speaker-Diarization ──────────────────────────────────────────────────────

# Gibt Speaker-annotierten Transkript-Text aus.
# Erwartet Whisper-JSON ($1) und Audio-Datei ($2).
# Fällt auf Plain-Text zurück wenn Diarization fehlschlägt.
build_speaker_transcript() {
  local whisper_json="$1"
  local audio_file="$2"

  python3 - "$whisper_json" "$audio_file" "$HF_TOKEN" << 'PYEOF'
import json, sys, re

whisper_json, audio_file, hf_token = sys.argv[1], sys.argv[2], sys.argv[3]

with open(whisper_json) as f:
    whisper_data = json.load(f)
segments = whisper_data.get("segments", [])

# Ohne Diarization: Plain-Text aus Segmenten zusammensetzen
def plain_text():
    return " ".join(s["text"].strip() for s in segments)

if not hf_token:
    print(plain_text())
    sys.exit(0)

try:
    from pyannote.audio import Pipeline
    import torch
except ImportError:
    print(plain_text())
    sys.exit(0)

try:
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=hf_token
    ).to(torch.device(device))

    diarization = pipeline(audio_file)
except Exception as e:
    print(plain_text(), file=sys.stderr)
    print(plain_text())
    sys.exit(0)

# Speaker-Segmente einlesen
spk_segments = [
    (turn.start, turn.end, spk)
    for turn, _, spk in diarization.itertracks(yield_label=True)
]

# Sprecherzuweisung per Segment-Mittelpunkt
def speaker_at(start, end):
    mid = (start + end) / 2
    for s, e, spk in spk_segments:
        if s <= mid <= e:
            return spk
    # Fallback: nächstes Segment
    best = min(spk_segments, key=lambda x: min(abs(x[0]-mid), abs(x[1]-mid)), default=None)
    return best[2] if best else "Speaker"

# Beschriftungen: SPEAKER_00 → "Sprecher A", SPEAKER_01 → "Sprecher B" ...
labels = {}
counter = 0
def label(spk):
    global counter
    if spk not in labels:
        labels[spk] = f"Sprecher {chr(65 + counter)}"
        counter += 1
    return labels[spk]

# Segmente zusammenführen — gleicher Sprecher in Folge wird verbunden
result = []
cur_spk, cur_text = None, []
for seg in segments:
    spk = speaker_at(seg["start"], seg["end"])
    if spk != cur_spk:
        if cur_text:
            result.append(f"**{label(cur_spk)}**: {' '.join(cur_text)}")
        cur_spk, cur_text = spk, [seg["text"].strip()]
    else:
        cur_text.append(seg["text"].strip())
if cur_text:
    result.append(f"**{label(cur_spk)}**: {' '.join(cur_text)}")

print("\n\n".join(result))
PYEOF
}

# ── API-Aufruf ───────────────────────────────────────────────────────────────

# Analysiert Transkript via Claude (Anthropic SDK, Prompt Caching aktiv).
# Schreibt Markdown-Summary auf stdout.
# Schreibt erweiterte Metadaten (tokens + title + topics) als JSON nach $2.
# Args: $1=transcript $2=usage_file $3=duration $4=language $5=word_count $6=has_speakers (0|1)
get_summary() {
  local transcript="$1"
  local usage_file="$2"

  # Write Python to a temp file so stdin stays free for the transcript
  local py_script
  py_script=$(mktemp /tmp/transcribe_summary_XXXXXX.py)

  cat > "$py_script" <<'PYEOF'
import json, os, sys, re
import anthropic

transcript = sys.stdin.read()
usage_file    = os.environ.get('USAGE_FILE', '')
duration      = os.environ.get('DURATION', 'unknown')
language      = os.environ.get('LANGUAGE', 'unknown')
word_count    = int(os.environ.get('WORD_COUNT', '0'))
has_speakers  = os.environ.get('HAS_SPEAKERS', '0') == '1'

# Quality signal: flag thin/noisy transcripts
low_quality = word_count < 50 or transcript.lower().count('[inaudible]') > 3

# Build context header for the user prompt
context_parts = [f'Aufnahmedauer: {duration}', f'Sprache: {language}', f'Wörter: {word_count}']
if has_speakers:
    context_parts.append('Mehrere Sprecher erkannt (Sprecher A / B / C…)')
if low_quality:
    context_parts.append('Hinweis: Transkriptqualität niedrig (kurz oder unverständliche Stellen)')
context_block = ' | '.join(context_parts)

# Per-speaker summary instruction (only when diarization was active)
speaker_instruction = (
    '\n- speaker_summaries: Objekt mit einem Eintrag pro Sprecher (z.B. {"Sprecher A": "...", "Sprecher B": "..."}) — '
    'nur wenn mehrere Sprecher vorhanden, sonst weglassen\n'
    if has_speakers else ''
)
speaker_json_field = (
    '\n  "speaker_summaries": {"Sprecher A": "Beitrag in 1 Satz", "Sprecher B": "Beitrag in 1 Satz"},'
    if has_speakers else ''
)

client = anthropic.Anthropic()

try:
    response = client.messages.create(
        model='claude-haiku-4-5-20251001',
        max_tokens=1500,
        system=[{
            'type': 'text',
            'text': (
                'Du bist ein präziser Assistent für Audio-Transkript-Analyse.\n'
                'Regeln:\n'
                '- Antworte immer in der Sprache des Transkripts\n'
                '- Schreibe nur was tatsächlich im Transkript steht — keine Ergänzungen\n'
                '- Bei sehr kurzem oder unklarem Inhalt: beschreibe kurz die Einschränkung in der Zusammenfassung\n'
                '- Passe die Ausführlichkeit der Aufnahmedauer an: kurze Aufnahmen → knappe Zusammenfassung'
            ),
            'cache_control': {'type': 'ephemeral'}
        }],
        messages=[{
            'role': 'user',
            'content': (
                f'Kontext: {context_block}\n\n'
                'Analysiere das folgende Transkript und antworte ausschließlich mit einem '
                'JSON-Objekt in diesem Format:\n\n'
                '{\n'
                '  "title": "Aussagekräftiger Titel (max 60 Zeichen, keine Sonderzeichen außer Bindestrich)",'
                + speaker_json_field + '\n'
                '  "topics": ["thema1", "thema2"],\n'
                '  "summary": "1-3 Sätze: Kern des Gesprächs",\n'
                '  "key_points": ["Wichtigster Punkt", "Zweiter Punkt"],\n'
                '  "action_items": ["Aufgabe 1"]\n'
                '}\n\n'
                'Hinweise:\n'
                '- topics: 2-5 Schlagworte, kleingeschrieben, auf Englisch oder Deutsch\n'
                '- key_points: mindestens 2, maximal 6 Punkte\n'
                '- action_items: nur wenn konkrete Aufgaben/Entscheidungen vorhanden, sonst leeres Array []\n'
                + speaker_instruction +
                '- Antworte NUR mit dem JSON, kein Text davor oder danach\n\n'
                f'Transkript:\n{transcript}'
            )
        }]
    )
except anthropic.APIStatusError as e:
    print(f'API-Fehler: HTTP {e.status_code} — {e.message}', file=sys.stderr)
    sys.exit(1)
except anthropic.APIConnectionError as e:
    print(f'API nicht erreichbar: {e}', file=sys.stderr)
    sys.exit(1)

usage = response.usage
raw = response.content[0].text.strip()

# JSON aus Antwort extrahieren (falls Claude doch Text drumherum schreibt)
match = re.search(r'\{.*\}', raw, re.DOTALL)
parsed = json.loads(match.group()) if match else {}

title            = parsed.get('title', '')
topics           = parsed.get('topics', [])
summary          = parsed.get('summary', '')
points           = parsed.get('key_points', [])
actions          = parsed.get('action_items', [])
speaker_summaries = parsed.get('speaker_summaries', {})

# Metadaten für Bash (inkl. Cache-Token-Counts)
if usage_file:
    with open(usage_file, 'w') as f:
        json.dump({
            'input_tokens':                usage.input_tokens,
            'output_tokens':               usage.output_tokens,
            'cache_creation_input_tokens': getattr(usage, 'cache_creation_input_tokens', 0) or 0,
            'cache_read_input_tokens':     getattr(usage, 'cache_read_input_tokens', 0) or 0,
            'title':  title,
            'topics': topics,
        }, f)

# Markdown-Body ausgeben
md = f'## Zusammenfassung\n{summary}\n\n## Kernpunkte\n'
md += '\n'.join(f'- {p}' for p in points)
if speaker_summaries:
    md += '\n\n## Sprecher\n'
    md += '\n'.join(f'- **{spk}**: {desc}' for spk, desc in speaker_summaries.items())
if actions:
    md += '\n\n## Action Items\n' + '\n'.join(f'- {a}' for a in actions)
print(md)
PYEOF

  USAGE_FILE="$usage_file" DURATION="$3" LANGUAGE="$4" WORD_COUNT="$5" HAS_SPEAKERS="$6" \
    python3 "$py_script" <<< "$transcript" 2>&1
  local exit_code=$?
  rm -f "$py_script"
  [ $exit_code -ne 0 ] && echo "Zusammenfassung nicht verfügbar."
  return $exit_code
}

calc_cost_eur() {
  local tokens_in="$1" tokens_out="$2" cache_write="${3:-0}" cache_read="${4:-0}"
  python3 -c "
cost_usd = ($tokens_in * $HAIKU_PRICE_IN
          + $tokens_out * $HAIKU_PRICE_OUT
          + $cache_write * $HAIKU_PRICE_CACHE_WRITE
          + $cache_read * $HAIKU_PRICE_CACHE_READ)
print(f'{cost_usd * $EUR_USD:.4f}')
"
}

# ── Archivierung ─────────────────────────────────────────────────────────────

archive_file() {
  local audio_file="$1"
  local filename=$(basename "$audio_file")
  local dest="$PROCESSED_FOLDER/$filename"

  # Bereits archiviert (Doppelverarbeitung durch fswatch)?
  if [ ! -f "$audio_file" ]; then
    echo -e "${YELLOW}   ↩ Bereits archiviert:${NC} $filename"
    return 0
  fi

  # Warten bis kein Prozess die Datei mehr offen hält (ffmpeg Finalisierung)
  local waited=0
  while lsof "$audio_file" &>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [ $waited -ge 30 ]; then
      echo -e "${RED}   ⚠️ Timeout: Datei wird noch von einem Prozess gehalten:${NC} $filename"
      return 1
    fi
  done

  # Gleichnamige Datei im Ziel: Präfix mit Zeitstempel
  if [ -f "$dest" ]; then
    dest="$PROCESSED_FOLDER/$(date +%H%M%S)_$filename"
  fi

  # cp + Größenprüfung + rm — robuster als mv bei async Dateisystem-Ops
  local src_size
  src_size=$(stat -f%z "$audio_file" 2>/dev/null || echo 0)

  local copy_err
  copy_err=$(cp "$audio_file" "$dest" 2>&1)
  if [ $? -ne 0 ]; then
    echo -e "${RED}   ⚠️ Archivierung fehlgeschlagen:${NC} $filename"
    echo "      Grund: $copy_err"
    return 1
  fi

  local dst_size
  dst_size=$(stat -f%z "$dest" 2>/dev/null || echo 0)
  if [ "$src_size" != "$dst_size" ]; then
    echo -e "${RED}   ⚠️ Größe stimmt nicht überein nach Kopieren — Original behalten${NC}"
    rm -f "$dest"
    return 1
  fi

  rm -f "$audio_file"
  echo -e "${GREEN}   📁 Archiviert:${NC} processed/$(basename "$dest")"
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

  # Guard against double-processing (iCloud re-triggers fswatch after archiving)
  if is_processed "$filename"; then
    echo -e "${YELLOW}   ↩ Bereits verarbeitet:${NC} $filename"
    return 0
  fi

  echo -e "${YELLOW}⏳ Verarbeite:${NC} $filename (Modell: $model)"
  mkdir -p "$OUTPUT_DIR"
  mkdir -p "$PROCESSED_FOLDER"

  # Dauer ermitteln
  local duration
  duration=$(get_duration "$audio_file")

  echo "   🎙️  Transkribiere..."
  whisper "$audio_file" \
    --model "$model" \
    --output_format json \
    --output_dir "$tmp_dir" > "$tmp_dir/whisper.log" 2>&1

  local json_file
  json_file=$(find "$tmp_dir" -name "*.json" | head -1)

  if [ ! -f "$json_file" ]; then
    echo -e "${RED}   ❌ Transkription fehlgeschlagen${NC}"
    cat "$tmp_dir/whisper.log" | tail -5 | sed 's/^/      /'
    notify "❌ Transkription fehlgeschlagen" "$filename"
    rm -rf "$tmp_dir"
    return 1
  fi

  # Sprache direkt aus Whisper-JSON
  local language
  language=$(python3 -c "import json,sys; print(json.load(open('$json_file')).get('language','unknown'))" 2>/dev/null || echo "unknown")

  # Speaker-Diarization wenn verfügbar, sonst Text aus JSON
  local transcript
  if diarization_available; then
    echo "   🗣️  Erkenne Sprecher..."
    transcript=$(build_speaker_transcript "$json_file" "$audio_file")
  else
    transcript=$(python3 -c "import json,sys; print(json.load(open('$json_file')).get('text','').strip())" 2>/dev/null)
  fi

  # Wörter zählen
  local word_count
  word_count=$(echo "$transcript" | wc -w | tr -d ' ')

  # Detect if diarization produced speaker labels
  local has_speakers=0
  echo "$transcript" | grep -q '\*\*Sprecher [A-Z]\*\*' && has_speakers=1

  echo "   🤖 Erstelle Zusammenfassung..."
  local summary
  summary=$(get_summary "$transcript" "$tmp_dir/usage.json" "$duration" "$language" "$word_count" "$has_speakers")

  # Token-Nutzung, Kosten, Titel und Topics aus usage.json
  local tokens_in=0 tokens_out=0 cache_write=0 cache_read=0 cost_eur="0.0000"
  local title="" topics_yaml="[transcript]"
  if [ -f "$tmp_dir/usage.json" ]; then
    IFS=$'\t' read -r tokens_in tokens_out cache_write cache_read title topics_yaml < <(python3 - "$tmp_dir/usage.json" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
tin   = d.get('input_tokens', 0)
tout  = d.get('output_tokens', 0)
tcw   = d.get('cache_creation_input_tokens', 0)
tcr   = d.get('cache_read_input_tokens', 0)
title = d.get('title', '').replace('\t', ' ')
tags  = '[' + ', '.join(['transcript'] + [t.lower().replace(' ', '-') for t in d.get('topics', [])]) + ']'
print(f"{tin}\t{tout}\t{tcw}\t{tcr}\t{title}\t{tags}")
PYEOF
    )
    cost_eur=$(calc_cost_eur "$tokens_in" "$tokens_out" "$cache_write" "$cache_read")
  fi

  # Dateiname: Titel wenn vorhanden, sonst Audio-Basename
  local slug=""
  if [ -n "$title" ]; then
    slug=$(echo "$title" | sed 's/[/\\:*?"<>|]/-/g' | sed 's/  */ /g' | tr ' ' '-')
  else
    slug="$basename"
  fi
  output_file="$OUTPUT_DIR/${date}_${slug}.md"

  # Count distinct speakers for frontmatter
  local speakers=""
  if [ "$has_speakers" -eq 1 ]; then
    speakers=$(echo "$transcript" | grep -o '\*\*Sprecher [A-Z]\*\*' | sort -u | wc -l | tr -d ' ')
  fi

  # Frontmatter zusammenbauen — keine Leerzeilen, sauberes YAML
  {
    echo "---"
    echo "date: $date"
    echo "time: $time"
    echo "type: transcript"
    echo "source: $filename"
    echo "title: \"$title\""
    echo "model: $model"
    echo "duration: \"$duration\""
    echo "language: $language"
    echo "word_count: $word_count"
    [ -n "$speakers" ] && echo "speakers: $speakers"
    echo "tokens_in: $tokens_in"
    echo "tokens_out: $tokens_out"
    echo "cost_eur: $cost_eur"
    echo "tags: $topics_yaml"
    echo "---"
    echo ""
    echo "$summary"
    echo ""
    echo "---"
    echo ""
    echo "## Vollständiges Transkript"
    echo ""
    echo "$transcript"
  } > "$output_file"

  # Register as processed before archiving — prevents iCloud-triggered re-runs
  # even if the subsequent archive step fails
  mark_processed "$filename"

  # Kosten-Log (CSV)
  if [ ! -f "$COSTS_LOG" ]; then
    echo "date,time,source,title,duration,language,word_count,tokens_in,tokens_out,cost_eur" > "$COSTS_LOG"
  fi
  echo "$date,$time,$filename,\"$title\",$duration,$language,$word_count,$tokens_in,$tokens_out,$cost_eur" >> "$COSTS_LOG"

  local outname=$(basename "$output_file")
  echo -e "${GREEN}   ✅ Gespeichert:${NC} $outname"
  [ -n "$title" ] && echo "      Titel: $title"
  echo "      Dauer: $duration | Sprache: $language | Wörter: $word_count"
  local cache_info=""
  [ "$cache_read" -gt 0 ] 2>/dev/null && cache_info=" (cache hit: ${cache_read} tokens)"
  echo "      Tokens: ${tokens_in}↑ ${tokens_out}↓${cache_info} | Kosten: ${cost_eur}€"
  notify "✅ Transkript fertig" "${title:-$filename} · $duration · ${cost_eur}€"

  rm -rf "$tmp_dir"

  archive_file "$audio_file"
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

  # Bereits vorhandene Dateien beim Start verarbeiten
  for file in "$AUDIO_WATCH_FOLDER"/*.{mp3,mp4,m4a,wav,ogg,flac,webm,opus}; do
    [ -f "$file" ] && process_file "$file"
  done

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
