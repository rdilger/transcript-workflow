#!/usr/bin/env bats
# E2E test for watch-mode pipeline
# Run: bats tests/e2e/test_watch_mode.bats
#
# Prerequisites: ANTHROPIC_API_KEY set, whisper + ffmpeg + fswatch installed.
# This test starts a real fswatch process and exercises the full watch → process
# → archive flow. It is slow (Whisper runtime) — tag with --filter to skip in CI.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURE_AUDIO="$REPO_ROOT/tests/fixtures/silent_3s.mp3"
WATCH_TIMEOUT=120  # seconds to wait for transcript to appear

setup() {
  if [ -z "$ANTHROPIC_API_KEY" ]; then
    skip "ANTHROPIC_API_KEY not set"
  fi
  if ! command -v fswatch &>/dev/null; then
    skip "fswatch not installed"
  fi

  BATS_TEST_TMPDIR="$(mktemp -d)"
  export VAULT="$BATS_TEST_TMPDIR/vault"
  export TRANSCRIPT_FOLDER="Transcripts"
  export AUDIO_WATCH_FOLDER="$BATS_TEST_TMPDIR/AudioInput"
  export PROCESSED_FOLDER="$BATS_TEST_TMPDIR/AudioInput/processed"
  export COSTS_LOG="$BATS_TEST_TMPDIR/AudioInput/costs.csv"
  export PROCESSED_REGISTRY="$BATS_TEST_TMPDIR/AudioInput/.processed_registry"
  mkdir -p "$VAULT/$TRANSCRIPT_FOLDER" "$AUDIO_WATCH_FOLDER" "$PROCESSED_FOLDER"

  WATCH_PID=""
}

teardown() {
  # Kill watch process if still running
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill "$WATCH_PID" 2>/dev/null
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  rm -rf "$BATS_TEST_TMPDIR"
}

# Helper: wait up to $WATCH_TIMEOUT seconds for a condition
wait_for() {
  local condition="$1"
  local elapsed=0
  while ! eval "$condition" 2>/dev/null; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ $elapsed -ge $WATCH_TIMEOUT ]; then
      return 1
    fi
  done
  return 0
}

# ── Watch mode ────────────────────────────────────────────────────────────────

@test "watch: dropping audio file triggers transcription and produces .md" {
  # Start watch mode in background
  VAULT="$VAULT" \
  TRANSCRIPT_FOLDER="$TRANSCRIPT_FOLDER" \
  AUDIO_WATCH_FOLDER="$AUDIO_WATCH_FOLDER" \
  PROCESSED_FOLDER="$PROCESSED_FOLDER" \
  COSTS_LOG="$COSTS_LOG" \
  PROCESSED_REGISTRY="$PROCESSED_REGISTRY" \
    bash "$REPO_ROOT/transcribe.sh" --watch &
  WATCH_PID=$!

  # Give fswatch a moment to start
  sleep 2

  # Drop the audio file
  cp "$FIXTURE_AUDIO" "$AUDIO_WATCH_FOLDER/silent_3s.mp3"

  # Wait for .md to appear in vault
  wait_for "[ \"\$(find '$VAULT/$TRANSCRIPT_FOLDER' -name '*.md' | wc -l | tr -d ' ')\" -ge 1 ]"
  [ $? -eq 0 ] || fail "No .md produced within ${WATCH_TIMEOUT}s"

  md=$(find "$VAULT/$TRANSCRIPT_FOLDER" -name "*.md" | head -1)
  [ -n "$md" ]
  grep -q "^type: transcript" "$md"
}

@test "watch: audio file is moved to processed/ after transcription" {
  VAULT="$VAULT" \
  TRANSCRIPT_FOLDER="$TRANSCRIPT_FOLDER" \
  AUDIO_WATCH_FOLDER="$AUDIO_WATCH_FOLDER" \
  PROCESSED_FOLDER="$PROCESSED_FOLDER" \
  COSTS_LOG="$COSTS_LOG" \
  PROCESSED_REGISTRY="$PROCESSED_REGISTRY" \
    bash "$REPO_ROOT/transcribe.sh" --watch &
  WATCH_PID=$!

  sleep 2
  cp "$FIXTURE_AUDIO" "$AUDIO_WATCH_FOLDER/silent_3s.mp3"

  # Wait for file to be archived
  wait_for "[ -f '$PROCESSED_FOLDER/silent_3s.mp3' ]"
  [ $? -eq 0 ] || fail "Audio not archived within ${WATCH_TIMEOUT}s"

  [ ! -f "$AUDIO_WATCH_FOLDER/silent_3s.mp3" ]
  [ -f "$PROCESSED_FOLDER/silent_3s.mp3" ]
}

@test "watch: registry entry written after successful transcription" {
  VAULT="$VAULT" \
  TRANSCRIPT_FOLDER="$TRANSCRIPT_FOLDER" \
  AUDIO_WATCH_FOLDER="$AUDIO_WATCH_FOLDER" \
  PROCESSED_FOLDER="$PROCESSED_FOLDER" \
  COSTS_LOG="$COSTS_LOG" \
  PROCESSED_REGISTRY="$PROCESSED_REGISTRY" \
    bash "$REPO_ROOT/transcribe.sh" --watch &
  WATCH_PID=$!

  sleep 2
  cp "$FIXTURE_AUDIO" "$AUDIO_WATCH_FOLDER/silent_3s.mp3"

  wait_for "grep -qxF 'silent_3s.mp3' '$PROCESSED_REGISTRY'"
  [ $? -eq 0 ] || fail "Registry entry not written within ${WATCH_TIMEOUT}s"

  grep -qxF "silent_3s.mp3" "$PROCESSED_REGISTRY"
}

@test "watch: files in processed/ subdir are ignored by fswatch" {
  VAULT="$VAULT" \
  TRANSCRIPT_FOLDER="$TRANSCRIPT_FOLDER" \
  AUDIO_WATCH_FOLDER="$AUDIO_WATCH_FOLDER" \
  PROCESSED_FOLDER="$PROCESSED_FOLDER" \
  COSTS_LOG="$COSTS_LOG" \
  PROCESSED_REGISTRY="$PROCESSED_REGISTRY" \
    bash "$REPO_ROOT/transcribe.sh" --watch &
  WATCH_PID=$!

  sleep 2

  # Drop file directly into processed/ — should not trigger transcription
  cp "$FIXTURE_AUDIO" "$PROCESSED_FOLDER/silent_3s.mp3"

  sleep 5  # Give fswatch time to react if it was going to

  md_count=$(find "$VAULT/$TRANSCRIPT_FOLDER" -name "*.md" | wc -l | tr -d ' ')
  [ "$md_count" -eq 0 ]
}
