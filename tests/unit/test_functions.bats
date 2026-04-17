#!/usr/bin/env bats
# Unit tests for core functions in transcribe.sh
# Run: bats tests/unit/test_functions.bats

# ── Setup: define functions under test directly ───────────────────────────────
# transcribe.sh is not structured as a sourceable library (top-level side effects),
# so we define the pure functions here. These must be kept in sync with transcribe.sh.

setup() {
  BATS_TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$BATS_TEST_TMPDIR/AudioInput/processed"

  AUDIO_WATCH_FOLDER="$BATS_TEST_TMPDIR/AudioInput"
  PROCESSED_FOLDER="$BATS_TEST_TMPDIR/AudioInput/processed"
  PROCESSED_REGISTRY="$BATS_TEST_TMPDIR/AudioInput/.processed_registry"
  WHISPER_MODEL="small"
  HAIKU_PRICE_IN=0.0000008
  HAIKU_PRICE_CACHE_WRITE=0.000001
  HAIKU_PRICE_CACHE_READ=0.00000008
  HAIKU_PRICE_OUT=0.000004
  EUR_USD=0.92

  # ── Pure functions copied from transcribe.sh ──────────────────────────────

  model_from_filename() {
    local basename="$1"
    if [[ "$basename" =~ _(tiny|small|medium|large)$ ]]; then
      echo "${BASH_REMATCH[1]}"
    else
      echo "$WHISPER_MODEL"
    fi
  }

  is_processed() {
    [ -f "$PROCESSED_REGISTRY" ] && grep -qxF "$1" "$PROCESSED_REGISTRY"
  }

  mark_processed() {
    echo "$1" >> "$PROCESSED_REGISTRY"
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

  archive_file() {
    local audio_file="$1"
    local filename=$(basename "$audio_file")
    local dest="$PROCESSED_FOLDER/$filename"

    if [ ! -f "$audio_file" ]; then
      return 0
    fi

    if [ -f "$dest" ]; then
      dest="$PROCESSED_FOLDER/$(date +%H%M%S)_$filename"
    fi

    local src_size
    src_size=$(stat -f%z "$audio_file" 2>/dev/null || echo 0)

    cp "$audio_file" "$dest" 2>/dev/null || return 1

    local dst_size
    dst_size=$(stat -f%z "$dest" 2>/dev/null || echo 0)
    if [ "$src_size" != "$dst_size" ]; then
      rm -f "$dest"
      return 1
    fi

    rm -f "$audio_file"
  }
}

teardown() {
  rm -rf "$BATS_TEST_TMPDIR"
}

# ── model_from_filename ───────────────────────────────────────────────────────

@test "model_from_filename: no suffix → default model" {
  run model_from_filename "meeting"
  [ "$status" -eq 0 ]
  [ "$output" = "small" ]
}

@test "model_from_filename: _tiny suffix → tiny" {
  run model_from_filename "recording_tiny"
  [ "$status" -eq 0 ]
  [ "$output" = "tiny" ]
}

@test "model_from_filename: _medium suffix → medium" {
  run model_from_filename "interview_medium"
  [ "$status" -eq 0 ]
  [ "$output" = "medium" ]
}

@test "model_from_filename: _large suffix → large" {
  run model_from_filename "vortrag_large"
  [ "$status" -eq 0 ]
  [ "$output" = "large" ]
}

@test "model_from_filename: suffix in middle is ignored" {
  run model_from_filename "medium_recording"
  [ "$status" -eq 0 ]
  [ "$output" = "small" ]
}

@test "model_from_filename: unknown suffix → default model" {
  run model_from_filename "meeting_xlarge"
  [ "$status" -eq 0 ]
  [ "$output" = "small" ]
}

# ── is_processed / mark_processed ────────────────────────────────────────────

@test "is_processed: returns false when registry does not exist" {
  run is_processed "recording.m4a"
  [ "$status" -ne 0 ]
}

@test "is_processed: returns false for unknown file when registry exists" {
  echo "other.m4a" > "$PROCESSED_REGISTRY"
  run is_processed "recording.m4a"
  [ "$status" -ne 0 ]
}

@test "mark_processed then is_processed: returns true" {
  mark_processed "recording.m4a"
  run is_processed "recording.m4a"
  [ "$status" -eq 0 ]
}

@test "mark_processed: appends to existing registry" {
  mark_processed "first.m4a"
  mark_processed "second.m4a"
  run is_processed "first.m4a"
  [ "$status" -eq 0 ]
  run is_processed "second.m4a"
  [ "$status" -eq 0 ]
}

@test "is_processed: exact filename match only (no partial match)" {
  mark_processed "recording.m4a"
  run is_processed "recording"
  [ "$status" -ne 0 ]
}

# ── calc_cost_eur ─────────────────────────────────────────────────────────────

@test "calc_cost_eur: zero tokens → 0.0000" {
  run calc_cost_eur 0 0 0 0
  [ "$status" -eq 0 ]
  [ "$output" = "0.0000" ]
}

@test "calc_cost_eur: only output tokens produces positive cost" {
  run calc_cost_eur 0 1000 0 0
  [ "$status" -eq 0 ]
  result=$(python3 -c "print('ok' if float('$output') > 0 else 'fail')")
  [ "$result" = "ok" ]
}

@test "calc_cost_eur: cache read tokens cost less than regular input" {
  cost_regular=$(calc_cost_eur 1000000 0 0 0)
  cost_cached=$(calc_cost_eur 0 0 0 1000000)
  result=$(python3 -c "print('ok' if float('$cost_cached') < float('$cost_regular') else 'fail')")
  [ "$result" = "ok" ]
}

@test "calc_cost_eur: cache write tokens cost more than regular input" {
  cost_regular=$(calc_cost_eur 1000000 0 0 0)
  cost_write=$(calc_cost_eur 0 0 1000000 0)
  result=$(python3 -c "print('ok' if float('$cost_write') > float('$cost_regular') else 'fail')")
  [ "$result" = "ok" ]
}

@test "calc_cost_eur: output is a 4-decimal float string" {
  run calc_cost_eur 500 200 0 0
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]{4}$ ]]
}

# ── archive_file ──────────────────────────────────────────────────────────────

@test "archive_file: moves file to processed/ and removes original" {
  local src="$BATS_TEST_TMPDIR/AudioInput/test.m4a"
  echo "dummy audio content" > "$src"

  archive_file "$src"
  [ ! -f "$src" ]
  [ -f "$BATS_TEST_TMPDIR/AudioInput/processed/test.m4a" ]
}

@test "archive_file: returns 0 if file already gone (double-trigger guard)" {
  run archive_file "$BATS_TEST_TMPDIR/AudioInput/nonexistent.m4a"
  [ "$status" -eq 0 ]
}

@test "archive_file: adds timestamp prefix if dest already exists" {
  local src="$BATS_TEST_TMPDIR/AudioInput/test.m4a"
  echo "audio" > "$src"
  echo "existing" > "$BATS_TEST_TMPDIR/AudioInput/processed/test.m4a"

  archive_file "$src"
  [ ! -f "$src" ]
  count=$(ls "$BATS_TEST_TMPDIR/AudioInput/processed/" | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}
