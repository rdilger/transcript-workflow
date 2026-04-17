#!/usr/bin/env bats
# Integration tests for the transcribe.sh pipeline
# Run: bats tests/integration/test_pipeline.bats
#
# Prerequisites: ANTHROPIC_API_KEY set, whisper + ffmpeg installed.
# These tests call the real Whisper and Claude API — they are slower than unit tests.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURE_AUDIO="$REPO_ROOT/tests/fixtures/silent_3s.mp3"

setup() {
  # Skip all tests if ANTHROPIC_API_KEY is not set
  if [ -z "$ANTHROPIC_API_KEY" ]; then
    skip "ANTHROPIC_API_KEY not set"
  fi

  # Isolated temp dirs for each test — no iCloud, no side effects
  BATS_TEST_TMPDIR="$(mktemp -d)"
  export VAULT="$BATS_TEST_TMPDIR/vault"
  export TRANSCRIPT_FOLDER="Transcripts"
  export AUDIO_WATCH_FOLDER="$BATS_TEST_TMPDIR/AudioInput"
  export PROCESSED_FOLDER="$BATS_TEST_TMPDIR/AudioInput/processed"
  export COSTS_LOG="$BATS_TEST_TMPDIR/AudioInput/costs.csv"
  export PROCESSED_REGISTRY="$BATS_TEST_TMPDIR/AudioInput/.processed_registry"
  mkdir -p "$VAULT/$TRANSCRIPT_FOLDER" "$AUDIO_WATCH_FOLDER" "$PROCESSED_FOLDER"
}

teardown() {
  rm -rf "$BATS_TEST_TMPDIR"
}

# Helper: run transcribe.sh with overridden paths via env
run_transcribe() {
  VAULT="$VAULT" \
  TRANSCRIPT_FOLDER="$TRANSCRIPT_FOLDER" \
  AUDIO_WATCH_FOLDER="$AUDIO_WATCH_FOLDER" \
  PROCESSED_FOLDER="$PROCESSED_FOLDER" \
  COSTS_LOG="$COSTS_LOG" \
  PROCESSED_REGISTRY="$PROCESSED_REGISTRY" \
    bash "$REPO_ROOT/transcribe.sh" "$@"
}

# ── Pipeline: process a real audio file ──────────────────────────────────────

@test "pipeline: processing silent_3s.mp3 produces a .md file" {
  local audio="$AUDIO_WATCH_FOLDER/silent_3s.mp3"
  cp "$FIXTURE_AUDIO" "$audio"

  run_transcribe "$audio"

  md_count=$(find "$VAULT/$TRANSCRIPT_FOLDER" -name "*.md" | wc -l | tr -d ' ')
  [ "$md_count" -ge 1 ]
}

@test "pipeline: output .md has valid YAML frontmatter" {
  local audio="$AUDIO_WATCH_FOLDER/silent_3s.mp3"
  cp "$FIXTURE_AUDIO" "$audio"
  run_transcribe "$audio"

  md=$(find "$VAULT/$TRANSCRIPT_FOLDER" -name "*.md" | head -1)
  [ -n "$md" ]

  # Must start with ---
  first_line=$(head -1 "$md")
  [ "$first_line" = "---" ]

  # Required frontmatter fields
  grep -q "^date:" "$md"
  grep -q "^type: transcript" "$md"
  grep -q "^source:" "$md"
  grep -q "^model:" "$md"
  grep -q "^duration:" "$md"
  grep -q "^language:" "$md"
  grep -q "^word_count:" "$md"
  grep -q "^cost_eur:" "$md"
  grep -q "^tags:" "$md"
}

@test "pipeline: output .md contains summary and transcript sections" {
  local audio="$AUDIO_WATCH_FOLDER/silent_3s.mp3"
  cp "$FIXTURE_AUDIO" "$audio"
  run_transcribe "$audio"

  md=$(find "$VAULT/$TRANSCRIPT_FOLDER" -name "*.md" | head -1)
  grep -q "## Zusammenfassung" "$md"
  grep -q "## Vollständiges Transkript" "$md"
}

@test "pipeline: audio file is archived to processed/ after run" {
  local audio="$AUDIO_WATCH_FOLDER/silent_3s.mp3"
  cp "$FIXTURE_AUDIO" "$audio"
  run_transcribe "$audio"

  [ ! -f "$audio" ]
  [ -f "$PROCESSED_FOLDER/silent_3s.mp3" ]
}

@test "pipeline: registry entry written after successful run" {
  local audio="$AUDIO_WATCH_FOLDER/silent_3s.mp3"
  cp "$FIXTURE_AUDIO" "$audio"
  run_transcribe "$audio"

  grep -qxF "silent_3s.mp3" "$PROCESSED_REGISTRY"
}

@test "pipeline: re-running on same file is a no-op (registry guard)" {
  local audio="$AUDIO_WATCH_FOLDER/silent_3s.mp3"
  cp "$FIXTURE_AUDIO" "$audio"
  run_transcribe "$audio"

  md_count_before=$(find "$VAULT/$TRANSCRIPT_FOLDER" -name "*.md" | wc -l | tr -d ' ')

  # Put the file back and run again — should skip
  cp "$FIXTURE_AUDIO" "$audio"
  run_transcribe "$audio"

  md_count_after=$(find "$VAULT/$TRANSCRIPT_FOLDER" -name "*.md" | wc -l | tr -d ' ')
  [ "$md_count_after" -eq "$md_count_before" ]
}

# ── --costs flag ──────────────────────────────────────────────────────────────

@test "--costs: shows table from existing costs.csv" {
  # Seed a known costs.csv
  cat > "$COSTS_LOG" <<'CSV'
date,time,source,title,duration,language,word_count,tokens_in,tokens_out,cost_eur
2026-04-17,10-00,test.m4a,"Test Meeting",1:30,de,250,800,200,0.0008
CSV

  run run_transcribe --costs
  [ "$status" -eq 0 ]
  [[ "$output" == *"test.m4a"* ]]
  [[ "$output" == *"0.0008"* ]]
}

@test "--costs: exits cleanly when no log exists" {
  run run_transcribe --costs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Noch keine Transkripte"* ]]
}
