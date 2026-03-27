# 🎙 Transcript Workflow

Automatisches Audio-Transkriptions-System für macOS. Nimmt System-Audio auf, transkribiert lokal via Whisper und erstellt strukturierte Markdown-Notizen mit KI-Zusammenfassung direkt in Obsidian.

## Funktionsweise

```
record (Menüleisten-App)
  → Aufnahme via BlackHole (System-Audio)
  → fswatch erkennt neue Datei in AudioInput/
  → Whisper transkribiert lokal (Modell ggf. aus Dateiname)
  → Claude API erstellt Zusammenfassung + Titel + Tags (JSON)
  → optional: Speaker Diarization via pyannote.audio
  → .md mit Frontmatter → Obsidian Vault/Transcripts/
  → Audio-Datei → AudioInput/processed/
  → Kosten werden in costs.csv geloggt
```

## Features

- **Lokale Transkription** via Whisper — kein Cloud-Upload
- **KI-Zusammenfassung** mit Titel-Generierung und Themen-Tags
- **Speaker Diarization** (optional): erkennt automatisch wer spricht
- **Kosten-Tracking**: Token-Nutzung und Kosten pro Transkript, laufendes CSV-Log
- **Modell per Dateiname**: `meeting_medium.m4a` → Whisper nutzt `medium`
- **macOS-Notifications** bei Erfolg und Fehler
- **Erweitertes Frontmatter**: Dauer, Sprache, Wortanzahl, Kosten, Sprecher

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

### 7. Speaker Diarization einrichten (optional)

```bash
pip install pyannote.audio
echo 'export HF_TOKEN=hf_...' >> ~/.zshrc
source ~/.zshrc
```

HuggingFace-Account erforderlich, Terms für [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1) akzeptieren.
Wenn `HF_TOKEN` nicht gesetzt ist, läuft das Script ohne Diarization — kein Breaking Change.

## Benutzung

- **🎙** in der Menüleiste → Aufnahme starten
- **🔴** → Aufnahme stoppen
- Datei landet automatisch in `~/Desktop/AudioInput/`
- Watch-Dienst transkribiert automatisch
- `.md` erscheint in `Obsidian Vault/Transcripts/`

### Manuell transkribieren

```bash
~/scripts/transcribe.sh /pfad/zur/audio.mp3
```

### Whisper-Modell per Dateiname steuern

```bash
# Standard-Modell (small)
mv meeting.m4a ~/Desktop/AudioInput/

# Bestimmtes Modell erzwingen
mv interview_medium.m4a ~/Desktop/AudioInput/
mv vortrag_large.m4a ~/Desktop/AudioInput/
```

### Kosten-Übersicht

```bash
~/scripts/transcribe.sh --costs
```

Zeigt alle Transkripte tabellarisch mit Dauer, Tokens und Kosten. CSV-Log liegt in `~/Desktop/AudioInput/costs.csv`.

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
| `COSTS_LOG` | `~/Desktop/AudioInput/costs.csv` | Pfad zum Kosten-Log |
| `HF_TOKEN` | — | HuggingFace-Token für Speaker Diarization (env var) |

## Output-Format

```markdown
---
date: 2026-03-25
time: 14-30
type: transcript
source: meeting.m4a
model: small
duration: "04:32"
language: german
word_count: 847
cost_eur: 0.0014
tokens_in: 1203
tokens_out: 312
speakers: 2
tags: [transcript, Q2-Planung, Budget, Roadmap]
---

## Zusammenfassung
...

## Kernpunkte
- ...

## Action Items
- ...

---

## Vollständiges Transkript

**Sprecher A:** ...
**Sprecher B:** ...
```

> `speakers` und `Action Items` erscheinen nur wenn relevant (Diarization aktiv bzw. Aufgaben vorhanden).

## Roadmap / Ideen

- [ ] Obsidian MCP Integration (Claude Code Vault-Zugriff)

## Kosten

Claude Haiku API: ~0,01–0,02€ pro Meeting-Transkript.
Whisper läuft vollständig lokal — keine Cloud, keine Kosten.

## Lizenz

MIT
