# Changelog

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
