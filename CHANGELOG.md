# Changelog

## [1.6.0] — 2026-03-27

### Added
- **Speaker Diarization** via `pyannote/speaker-diarization-3.1`: erkennt automatisch wer spricht
  - Aktiviert sich wenn `HF_TOKEN` gesetzt und `pyannote.audio` installiert ist
  - Fallback auf Plain-Text wenn Voraussetzungen fehlen (kein Breaking Change)
  - MPS-Beschleunigung auf Apple Silicon automatisch genutzt
  - Sprecher werden als „Sprecher A / B / C" bezeichnet
- `speakers: N` im Frontmatter wenn Diarization aktiv
- Whisper gibt jetzt JSON + TXT aus (JSON liefert Timestamps für Sprecherzuweisung)
- `diarization_available()` Helper — check einmalig pro Run, kein Overhead wenn inaktiv

### Setup (optional)
```bash
pip install pyannote.audio
# HuggingFace-Token + Modell-Terms: huggingface.co/pyannote/speaker-diarization-3.1
echo 'export HF_TOKEN=hf_...' >> ~/.zshrc
```

---

## [1.5.0] — 2026-03-27

### Changed
- **Summary-Qualität**: `system`-Parameter mit klarer Rollenanweisung (keine Halluzinationen, Sprache des Transkripts)
- **Strukturierter JSON-Output**: Claude gibt JSON zurück → zuverlässiges Parsing statt Freitext-Formatierung
- **Titel-Extraktion**: Claude generiert einen prägnanten Titel → Obsidian-Dateiname z.B. `2026-03-27_Meeting-Q2-Planning.md`
- **Topics/Keywords**: 2-5 Schlagworte werden als Obsidian-Tags ins Frontmatter geschrieben
- **Action Items adaptiv**: Sektion erscheint nur wenn tatsächlich Aufgaben vorhanden
- Kosten-CSV enthält jetzt auch den generierten Titel

---

## [1.4.0] — 2026-03-27

### Fixed
- **Archivierung**: `mv` ersetzt durch `cp + Größenprüfung + rm` — verhindert stille Datenverluste
- **ffmpeg-Finalisierung**: `lsof`-Warten (max 30s) bevor archiviert wird — behebt Fehler wenn m4a-Container noch geschrieben wird
- **Doppelverarbeitung**: Frühzeitiger Exit wenn Datei bereits archiviert (fswatch kann mehrfach feuern)
- **Namenskonflikte**: Zeitstempel-Präfix wenn gleichnamige Datei in `processed/` existiert
- **Fehler-Sichtbarkeit**: Tatsächlicher Fehlergrund statt stummem `2>/dev/null`

---

## [1.3.0] — 2026-03-27

### Added
- **Kosten-Tracking**: Token-Nutzung (`tokens_in`, `tokens_out`, `cost_eur`) im Frontmatter jedes Transkripts
- **Kosten-Log**: läuft als CSV in `~/Desktop/AudioInput/costs.csv` mit — Datum, Datei, Dauer, Tokens, Kosten
- **`--costs` Flag**: tabellarische Übersicht aller Transkripte mit Gesamtkosten (`./transcribe.sh --costs`)
- Preise als Konstanten (`HAIKU_PRICE_IN`, `HAIKU_PRICE_OUT`, `EUR_USD`) — leicht anpassbar

---

## [1.2.0] — 2026-03-27

### Added
- **Frontmatter erweitert**: `duration` (MM:SS), `language` (Whisper-Erkennung), `word_count`
- **Modell per Dateiname**: `meeting_medium.m4a` → Whisper-Modell `medium` automatisch gewählt
- **macOS-Notifications**: Erfolg (`✅ Transkript fertig`) und Fehler (`❌ Transkription fehlgeschlagen`) via `osascript`

---

## [1.1.0] — 2026-03-27

### Added
- `tests/test.sh`: System-Check für Tools, API-Key, API-Verbindung, Vault-Pfad, Watch-Ordner, LaunchAgent
- `.gitignore`: Audio-Dateien, Logs, .DS_Store, .env
- `legacy/create_recorder_app.sh`: originale Bash-Variante des Recorders (Referenz)

### Changed
- API-Aufruf in `transcribe.sh`: `curl` → `python3/urllib` (keine externe Abhängigkeit, robusteres Error-Handling)
- Verbesserter Summary-Prompt mit explizitem Sprachhinweis und klarerem Format

### Fixed
- `~/scripts/transcribe.sh` ist jetzt ein Symlink ins Repo — LaunchAgent läuft immer mit aktueller Version

---

## [1.0.0] — 2026-03-25

### Added
- `transcribe.sh`: Audio → Whisper-Transkription → Claude-Zusammenfassung → Obsidian Markdown
- `RecorderMenuBar.swift`: Native Swift Menüleisten-App für System-Audio-Aufnahme via BlackHole
- `install_recorder.sh`: Kompiliert und installiert die Swift-App nach `~/Applications/Recorder.app`
- `com.transcribe.watch.plist`: LaunchAgent für automatischen Watch-Modus beim Login
- `README.md`: Setup-Anleitung, Konfiguration, Output-Format, Roadmap
