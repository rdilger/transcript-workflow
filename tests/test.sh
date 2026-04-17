#!/bin/bash
# tests/test.sh — Prüft ob das Transcript-Workflow korrekt eingerichtet ist

VAULT="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
TRANSCRIPT_FOLDER="Transcripts"
AUDIO_WATCH_FOLDER="$HOME/Desktop/AudioInput"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}~${NC} $1"; WARN=$((WARN+1)); }

echo ""
echo "=== Transcript Workflow — System Check ==="
echo ""

# ── 1. TOOLS ────────────────────────────────────────────────────────────────
echo "[ Tools ]"

command -v whisper &>/dev/null \
  && pass "whisper installiert ($(whisper --version 2>&1 | head -1))" \
  || fail "whisper fehlt → brew install openai-whisper"

command -v ffmpeg &>/dev/null \
  && pass "ffmpeg installiert" \
  || fail "ffmpeg fehlt → brew install ffmpeg"

command -v fswatch &>/dev/null \
  && pass "fswatch installiert" \
  || fail "fswatch fehlt → brew install fswatch"

command -v python3 &>/dev/null \
  && pass "python3 verfügbar ($(python3 --version 2>&1))" \
  || fail "python3 fehlt"

python3 -c "import anthropic" 2>/dev/null \
  && pass "anthropic SDK installiert ($(python3 -c 'import anthropic; print(anthropic.__version__)'))" \
  || fail "anthropic SDK fehlt → pip3 install anthropic"

echo ""

# ── 2. API KEY ───────────────────────────────────────────────────────────────
echo "[ API Key ]"

if [ -z "$ANTHROPIC_API_KEY" ]; then
  fail "ANTHROPIC_API_KEY nicht gesetzt"
elif [[ "$ANTHROPIC_API_KEY" != sk-ant-* ]]; then
  warn "ANTHROPIC_API_KEY gesetzt, aber unerwartetes Format"
else
  pass "ANTHROPIC_API_KEY gesetzt (${ANTHROPIC_API_KEY:0:12}…)"
fi

echo ""

# ── 3. API VERBINDUNG ────────────────────────────────────────────────────────
echo "[ API Verbindung ]"

if [ -z "$ANTHROPIC_API_KEY" ]; then
  warn "API-Test übersprungen (kein Key)"
else
  API_RESULT=$(python3 - <<'EOF'
import os, sys
try:
    import anthropic
except ImportError:
    print("NO_SDK")
    sys.exit()

try:
    client = anthropic.Anthropic()
    client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=10,
        messages=[{"role": "user", "content": "ping"}]
    )
    print("OK")
except anthropic.AuthenticationError:
    print("AUTH")
except anthropic.RateLimitError:
    print("RATE")
except Exception as e:
    print(f"ERR:{e}")
EOF
)

  case "$API_RESULT" in
    OK)      pass "Claude API erreichbar (Anthropic SDK)" ;;
    AUTH)    fail "API Key ungültig (AuthenticationError)" ;;
    RATE)    warn "Rate-Limit erreicht (RateLimitError)" ;;
    NO_SDK)  fail "anthropic SDK nicht installiert — API-Test übersprungen" ;;
    *)       fail "API nicht erreichbar: $API_RESULT" ;;
  esac
fi

echo ""

# ── 4. OBSIDIAN VAULT ────────────────────────────────────────────────────────
echo "[ Obsidian Vault ]"

if [ -d "$VAULT" ]; then
  pass "Vault-Ordner vorhanden: $VAULT"
  if [ -d "$VAULT/$TRANSCRIPT_FOLDER" ]; then
    COUNT=$(find "$VAULT/$TRANSCRIPT_FOLDER" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    pass "Transcripts-Unterordner vorhanden ($COUNT .md-Dateien)"
  else
    warn "Transcripts-Ordner fehlt noch — wird beim ersten Lauf angelegt"
  fi
else
  fail "Vault nicht gefunden: $VAULT"
  warn "Obsidian iCloud-Vault nicht gemountet oder anderer Pfad?"
fi

echo ""

# ── 5. AUDIO WATCH-ORDNER ────────────────────────────────────────────────────
echo "[ Watch-Ordner ]"

if [ -d "$AUDIO_WATCH_FOLDER" ]; then
  pass "Watch-Ordner vorhanden: $AUDIO_WATCH_FOLDER"
  if [ -d "$AUDIO_WATCH_FOLDER/processed" ]; then
    pass "processed/ Unterordner vorhanden"
  else
    warn "processed/ fehlt — wird beim ersten Lauf angelegt"
  fi
else
  fail "Watch-Ordner fehlt: $AUDIO_WATCH_FOLDER"
  echo "         → mkdir ~/Desktop/AudioInput"
fi

echo ""

# ── 6. LAUNCHAGENT ──────────────────────────────────────────────────────────
echo "[ LaunchAgent (Watch-Dienst) ]"

PLIST="$HOME/Library/LaunchAgents/com.transcribe.watch.plist"
if [ -f "$PLIST" ]; then
  # Format: PID  ExitStatus  Label  (PID="-" wenn gestoppt)
  PID=$(launchctl list | grep com.transcribe.watch | awk '{print $1}')
  EXIT=$(launchctl list | grep com.transcribe.watch | awk '{print $2}')
  if [ "$PID" != "-" ] && [ -n "$PID" ]; then
    pass "LaunchAgent läuft (PID $PID)"
  elif [ "$EXIT" = "0" ] || [ "$EXIT" = "-" ]; then
    warn "LaunchAgent registriert, aber gerade nicht aktiv → launchctl start com.transcribe.watch"
  elif [ -n "$EXIT" ]; then
    fail "LaunchAgent abgestürzt (Exit-Code $EXIT) → cat /tmp/transcribe.log"
  else
    warn "LaunchAgent-Datei vorhanden, aber nicht geladen → launchctl load $PLIST"
  fi
else
  warn "LaunchAgent nicht installiert (Watch läuft manuell oder gar nicht)"
fi

echo ""

# ── ERGEBNIS ─────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}Bestanden:${NC}  $PASS"
[ $WARN -gt 0 ] && echo -e "  ${YELLOW}Warnungen:${NC}  $WARN"
[ $FAIL -gt 0 ] && echo -e "  ${RED}Fehler:${NC}     $FAIL"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}System ist bereit.${NC}"
  exit 0
else
  echo -e "${RED}$FAIL Problem(e) beheben bevor das Workflow funktioniert.${NC}"
  exit 1
fi
