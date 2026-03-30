import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var recordingProcess: Process?
    var isRecording = false
    var selectedModel = "small"
    let models = ["tiny", "small", "medium"]
    let audioDevice = "0" // BlackHole 2ch
    let audioInputDir = NSHomeDirectory() + "/Desktop/AudioInput"
    var audioWarningShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()
        checkAudioSetup()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isRecording {
            stopRecording()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // --- Audio Setup Check ---
    func checkAudioSetup() {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", "system_profiler SPAudioDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let hasOutput = output.contains("Transcript_Output")
        let hasInput = output.contains("Transcript_Input")

        if !hasOutput || !hasInput {
            showAudioWarning()
        } else {
            showAudioSuccess()
        }
    }

    func showAudioSuccess() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "✅ Audio Setup korrekt"
            alert.informativeText = "Transcript_Input und Transcript_Output sind aktiv.\nAufnahmen werden korrekt funktionieren."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func showAudioWarning() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "⚠️ Audio Setup nicht korrekt"
            alert.informativeText = "\"Transcript_Output\" oder \"Transcript_Input\" nicht gefunden.\n\nBitte:\n1. Audio MIDI Setup öffnen → Transcript_Output & Transcript_Input prüfen\n2. Systemeinstellungen → Sound → Output → Transcript_Output wählen"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Audio MIDI Setup öffnen")
            alert.addButton(withTitle: "Sound-Einstellungen öffnen")
            alert.addButton(withTitle: "Ignorieren")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            default:
                break
            }
        }
    }

    func updateIcon() {
        statusItem?.button?.title = isRecording ? "🔴" : "🎙"
    }

    func buildMenu() {
        let menu = NSMenu()

        if isRecording {
            let stop = NSMenuItem(title: "⏹  Aufnahme stoppen", action: #selector(toggleRecording), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        } else {
            let start = NSMenuItem(title: "▶️  Aufnahme starten", action: #selector(toggleRecording), keyEquivalent: "")
            start.target = self
            menu.addItem(start)
        }

        menu.addItem(.separator())

        // Audio Setup
        let audioSetup = NSMenuItem(title: "⚙️  Audio Setup prüfen", action: #selector(checkAudioSetupManual), keyEquivalent: "")
        audioSetup.target = self
        menu.addItem(audioSetup)

        menu.addItem(.separator())

        // Modell submenu
        let modelSubmenu = NSMenu()
        for model in models {
            let item = NSMenuItem(title: model, action: #selector(changeModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = model == selectedModel ? .on : .off
            modelSubmenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "Modell: \(selectedModel)", action: nil, keyEquivalent: "")
        modelItem.submenu = modelSubmenu
        menu.addItem(modelItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Beenden", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc func checkAudioSetupManual() {
        showAudioWarning()
    }

    @objc func quitApp() {
        if isRecording {
            stopRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    @objc func changeModel(_ sender: NSMenuItem) {
        selectedModel = sender.representedObject as? String ?? "small"
        runShell("sed -i '' 's/WHISPER_MODEL=.*/WHISPER_MODEL=\"\(selectedModel)\"/' ~/scripts/transcribe.sh")
        buildMenu()
    }

    @objc func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            // Vor Aufnahme Audio prüfen
            let task = Process()
            task.launchPath = "/bin/zsh"
            task.arguments = ["-c", "system_profiler SPAudioDataType"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            try? task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if !output.contains("Transcript_Output") || !output.contains("Transcript_Input") {
                showAudioWarning()
            } else {
                startRecording()
            }
        }
    }

    func startRecording() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let filename = "recording_\(formatter.string(from: Date())).m4a"
        let outputPath = "\(audioInputDir)/\(filename)"

        let process = Process()
        process.launchPath = "/opt/homebrew/bin/ffmpeg"
        process.arguments = ["-f", "avfoundation", "-i", ":\(audioDevice)", outputPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            recordingProcess = process
            isRecording = true
            updateIcon()
            buildMenu()
            notify(title: "🔴 Aufnahme läuft", message: "Klicke auf 🔴 zum Stoppen")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.notify(title: "⚠️ Video-Call-Mikrofon prüfen", message: "Transcript_Input ist aktiv — in Meet/Hangouts/Zoom explizit Scarlett 2i2 wählen")
            }
        } catch {
            notify(title: "Fehler", message: "Aufnahme konnte nicht gestartet werden")
        }
    }

    func stopRecording() {
        recordingProcess?.interrupt()
        recordingProcess?.waitUntilExit()
        recordingProcess = nil
        isRecording = false
        updateIcon()
        buildMenu()
        notify(title: "✅ Aufnahme gespeichert", message: "Wird automatisch transkribiert...")
    }

    func runShell(_ command: String) {
        let p = Process()
        p.launchPath = "/bin/zsh"
        p.arguments = ["-c", "source ~/.zshrc && \(command)"]
        try? p.run()
    }

    func notify(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
