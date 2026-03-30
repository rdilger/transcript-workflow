# 🎙 Transcript Workflow

Automatisches Audio-Transkriptions-System für macOS. Nimmt System-Audio auf, transkribiert lokal via Whisper und erstellt strukturierte Markdown-Notizen mit KI-Zusammenfassung direkt in Obsidian.

## Funktionsweise

```
record (Menüleisten-App)
  → Aufnahme via BlackHole (System-Audio)
  → fswatch erkennt neue Datei in AudioInput/
  → Whisper transkribiert lokal
  → Claude API erstellt Zusammenfassung
  → .md mit Frontmatter → Obsidian Vault/Transcripts/
  → Audio-Datei → AudioInput/processed/
```

## Voraussetzungen

- macOS 13+
- Obsidian (iCloud Vault)
- Anthropic API Key ([console.anthropic.com](https://console.anthropic.com))
- Claude Pro oder API Credits

## Installation

### 1. Dependencies installieren

```bash
brew install openai-whisper ffmpeg fswatch blackhole-2ch
```

### 2. Audio Setup

**Audio MIDI Setup** (`Cmd+Space` → "Audio MIDI Setup"):

- `+` → **Create Aggregate Device** → umbenennen in `Transcript_Input`
  - ✅ BlackHole 2ch
  - ✅ AirPods / Mikrofon (Zeile mit `1 in`)

- `+` → **Create Multi-Output Device** → umbenennen in `Transcript_Output`
  - ✅ BlackHole 2ch
  - ✅ AirPods / Lautsprecher

**Systemeinstellungen → Sound → Output** → `Transcript_Output` wählen

### 3. API Key einrichten

```bash
echo 'export ANTHROPIC_API_KEY=sk-ant-...' >> ~/.zshrc
source ~/.zshrc
```

### 4. Script einrichten

```bash
mkdir ~/scripts
cp transcribe.sh ~/scripts/transcribe.sh
chmod +x ~/scripts/transcribe.sh
mkdir ~/Desktop/AudioInput
```

### 5. Watch-Dienst als Autostart einrichten

```bash
cp com.transcribe.watch.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.transcribe.watch.plist
```

### 6. Menüleisten-App installieren

```bash
chmod +x install_recorder.sh
./install_recorder.sh
open ~/Applications/Recorder.app
```

App beim Mac-Start automatisch starten:
**Systemeinstellungen → Allgemein → Anmeldeelemente** → `Recorder.app` hinzufügen

## Benutzung

- **🎙** in der Menüleiste → Aufnahme starten
- **🔴** → Aufnahme stoppen
- Datei landet automatisch in `~/Desktop/AudioInput/`
- Watch-Dienst transkribiert automatisch
- `.md` erscheint in `Obsidian Vault/Transcripts/`

> **⚠️ Hinweis für Video-Calls (Meet, Hangouts, Zoom):**
> `Transcript_Input` ist als System-Standard-Eingabegerät gesetzt. Video-Call-Tools übernehmen diesen Standard und senden dadurch u.U. Stille. Beim Start einer Aufnahme erscheint automatisch ein Reminder — in der jeweiligen App immer explizit das echte Mikrofon (z.B. Scarlett 2i2) auswählen.

### Manuell transkribieren

```bash
~/scripts/transcribe.sh /pfad/zur/audio.mp3
```

### Datei nachträglich importieren

Liegt eine Datei bereits in `~/Desktop/AudioInput/` (z.B. weil der Watch-Dienst nicht lief), einfach manuell anstoßen:

```bash
~/scripts/transcribe.sh ~/Desktop/AudioInput/recording.m4a
```

Alternativ den Watch-Dienst neu starten — er verarbeitet beim Start automatisch alle noch vorhandenen Dateien im Ordner.

### Unterstützte Formate

`mp3`, `mp4`, `m4a`, `wav`, `ogg`, `flac`, `webm`, `opus`

## Konfiguration

In `transcribe.sh` anpassbar:

| Variable | Standard | Beschreibung |
|----------|----------|--------------|
| `WHISPER_MODEL` | `small` | `tiny` / `small` / `medium` / `large` |
| `VAULT` | iCloud Obsidian Vault | Pfad zum Obsidian Vault |
| `TRANSCRIPT_FOLDER` | `Transcripts` | Unterordner im Vault |
| `AUDIO_WATCH_FOLDER` | `~/Desktop/AudioInput` | Ordner für Audio-Input |

## Output-Format

```markdown
---
date: 2026-03-25
time: 14-30
type: transcript
source: meeting.m4a
model: small
tags: [transcript]
---

## Zusammenfassung
...

## Kernpunkte
- ...

## Action Items
- ...

---

## Vollständiges Transkript
...
```

## Roadmap / Ideen

- [ ] Obsidian MCP Integration (Claude Code Vault-Zugriff)
- [ ] Frontmatter erweitern (duration, word_count, language, Links)
- [ ] Speaker Diarization (verschiedene Sprecher unterscheiden)
- [x] Modell per Dateiname steuern (`meeting_medium.m4a`)
- [x] Kosten-Tracking pro Transkript
- [x] Fehler-Notifications via macOS
- [ ] Processed-Ordner Bug bei iCloud fixen
- [x] Summary Qualität verbessern
- [x] Vorhandene Dateien beim Watch-Start automatisch verarbeiten
- [x] Mikrofon-Warnung bei Aufnahmestart (Video-Call-Konflikt)

## Kosten

Claude Haiku API: ~0,01–0,02€ pro Meeting-Transkript.
Whisper läuft vollständig lokal — keine Cloud, keine Kosten.

## Lizenz

MIT
