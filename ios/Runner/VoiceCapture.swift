//
//  VoiceCapture.swift
//  Runner
//
//  Dictate notes: live on-device transcription that keeps running while the
//  phone is locked, appended to a voice notes file in the notes folder.
//

import ActivityKit
import AppIntents
import AVFoundation
import Flutter
import Foundation
import Speech
import os

fileprivate let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "VoiceCapture"
)

fileprivate let localeDefaultsKey = "orgroVoiceLocale"
fileprivate let dirDefaultsKey = "orgroVoiceDir"
fileprivate let pendingDefaultsKey = "orgroVoicePending"
fileprivate let voiceNotesFileName = "voice-notes.org"

final class VoiceCapture: NSObject, FlutterStreamHandler {
    static let shared = VoiceCapture()

    var channel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?

    /// Set when the app is opened by the App Shortcut before Flutter is ready
    private var pendingAction: String?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private let requestLock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmentId = 0
    private var segmentTimer: Timer?

    private var running = false
    private var committed = ""
    private var current = ""
    private var stopCompletion: ((String) -> Void)?

    /// Who started the current recording. Recordings started from the Lock
    /// Screen control are saved here; in-app ones are saved by the Flutter UI.
    private enum Origin { case app, intent }
    private var origin = Origin.app
    private var startedAt = Date()
    private var activity: Activity<VoiceNoteAttributes>?
    private var lastActivityUpdate = Date.distantPast
    private var activityUpdateScheduled = false

    private var fullTranscript: String {
        [committed, current].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Actions from outside Flutter (App Shortcut)

    func requestAction(_ action: String) {
        if let channel = channel {
            channel.invokeMethod("action", arguments: action) { [weak self] result in
                // Dart not listening yet: keep it for later
                if result is FlutterError || (result as? NSObject) == FlutterMethodNotImplemented {
                    self?.pendingAction = action
                }
            }
        } else {
            pendingAction = action
        }
    }

    // MARK: - Method channel

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any?] ?? [:]
        switch call.method {
        case "consumePendingAction":
            result(pendingAction)
            pendingAction = nil
        case "requestPermissions":
            requestPermissions(result)
        case "locales":
            let supported = SFSpeechRecognizer.supportedLocales()
                .map { $0.identifier(.bcp47) }
                .sorted()
            result(supported)
        case "getLocale":
            result(UserDefaults.standard.string(forKey: localeDefaultsKey))
        case "setLocale":
            UserDefaults.standard.set(args["locale"] as? String, forKey: localeDefaultsKey)
            result(nil)
        case "start":
            let locale = args["locale"] as? String ?? Locale.current.identifier(.bcp47)
            do {
                try start(locale: locale)
                result(nil)
            } catch {
                logger.error("Failed to start: \(error)")
                stopEngine()
                result(FlutterError(code: "StartFailed", message: error.localizedDescription, details: nil))
            }
        case "stop":
            stop { transcript in result(transcript) }
        case "cancel":
            cancel()
            result(nil)
        case "appendToFile":
            appendToFile(args, result)
        case "configure":
            // The notes folder to save background recordings to
            UserDefaults.standard.set(args["dirIdentifier"] as? String, forKey: dirDefaultsKey)
            flushPending()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { self.eventSink?(event) }
    }

    private func emitTranscript() {
        emit(["type": "transcript", "text": fullTranscript])
        scheduleActivityUpdate()
    }

    // MARK: - Permissions

    private func requestPermissions(_ result: @escaping FlutterResult) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { result(false) }
                return
            }
            let done: (Bool) -> Void = { granted in
                DispatchQueue.main.async { result(granted) }
            }
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission(completionHandler: done)
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission(done)
            }
        }
    }

    // MARK: - Recording

    private func start(locale: String) throws {
        if running { cancel() }
        origin = .app
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            throw NSError(domain: "VoiceCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn’t supported for \(locale)"])
        }
        guard recognizer.isAvailable else {
            throw NSError(domain: "VoiceCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is currently unavailable"])
        }
        self.recognizer = recognizer

        let session = AVAudioSession.sharedInstance()
        // .record + the "audio" background mode keeps dictation going when the
        // phone is locked
        // .measurement is what Apple recommends for speech recognition;
        // .spokenAudio is a playback mode and makes .record fail with -50
        try step("configuring audio") {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        }
        try step("activating audio") {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )

        committed = ""
        current = ""
        running = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoiceCapture", code: 6, userInfo: [NSLocalizedDescriptionKey: "No microphone input available (is another app using it?)"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.requestLock.lock()
            self.request?.append(buffer)
            self.requestLock.unlock()
            self.emitLevel(buffer)
        }
        engine.prepare()
        try step("starting microphone") { try engine.start() }
        startedAt = Date()
        startSegment()
        startActivity()
        emit(["type": "started", "onDevice": recognizer.supportsOnDeviceRecognition])
    }

    /// Prefix errors with what we were doing, so reports are actionable
    private func step(_ what: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            let ns = error as NSError
            throw NSError(domain: ns.domain, code: ns.code, userInfo: [
                NSLocalizedDescriptionKey: "Failed \(what): \(ns.localizedDescription) (\(ns.domain) \(ns.code))",
            ])
        }
    }

    private var lastLevelEmit = Date.distantPast

    private func emitLevel(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelEmit) > 0.1,
              let data = buffer.floatChannelData?[0] else { return }
        lastLevelEmit = now
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count))
        // Map roughly -60...0 dB to 0...1
        let db = 20 * log10(max(rms, 0.000_001))
        emit(["type": "level", "value": Double(max(0, min(1, (db + 60) / 60)))])
    }

    /// Recognition runs in segments: a finished (or failed) segment is
    /// committed and a new one started, so long dictations aren't cut off.
    private func startSegment() {
        guard running, let recognizer = recognizer else { return }
        segmentId += 1
        let id = segmentId

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        requestLock.lock()
        let old = request
        request = req
        requestLock.unlock()
        old?.endAudio()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.onRecognition(segment: id, result: result, error: error)
            }
        }

        // Server-based recognition is limited to about a minute per request
        segmentTimer?.invalidate()
        if !req.requiresOnDeviceRecognition {
            segmentTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
                self?.rotateSegment()
            }
        }
    }

    private func rotateSegment() {
        guard running else { return }
        commitCurrent()
        startSegment()
    }

    private func commitCurrent() {
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            committed = committed.isEmpty ? text : "\(committed) \(text)"
        }
        current = ""
    }

    private func onRecognition(segment id: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        // Results from an older segment can still arrive after rotation
        if id != segmentId {
            if let result = result, result.isFinal, !running {
                // Ignore; the newest segment is authoritative
            }
            return
        }
        if let result = result {
            current = result.bestTranscription.formattedString
            emitTranscript()
            if result.isFinal {
                commitCurrent()
                if running {
                    startSegment()
                } else {
                    finishStop()
                }
            }
            return
        }
        if let error = error {
            let nsError = error as NSError
            // 1110: no speech detected; 301: request cancelled. Not worth
            // reporting while dictating.
            let quiet = nsError.domain == "kAFAssistantErrorDomain" && [1110, 301, 216].contains(nsError.code)
            if !quiet {
                logger.error("Recognition error: \(error)")
                emit(["type": "error", "message": error.localizedDescription])
            }
            commitCurrent()
            if running {
                // Brief pause so a persistent error can't spin
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self, self.running, id == self.segmentId else { return }
                    self.startSegment()
                }
            } else {
                finishStop()
            }
        }
    }

    private func stop(_ completion: @escaping (String) -> Void) {
        guard running else {
            completion(fullTranscript)
            return
        }
        running = false
        stopCompletion = completion
        segmentTimer?.invalidate()
        stopEngine()
        requestLock.lock()
        request?.endAudio()
        requestLock.unlock()
        // Don't wait forever for the final result
        let id = segmentId
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, id == self.segmentId else { return }
            self.commitCurrent()
            self.finishStop()
        }
    }

    private func finishStop() {
        guard let completion = stopCompletion else { return }
        stopCompletion = nil
        task = nil
        requestLock.lock()
        request = nil
        requestLock.unlock()
        segmentId += 1
        deactivateSession()
        emit(["type": "stopped"])
        let transcript = fullTranscript
        if origin == .intent {
            let status = saveInBackground(transcript)
            endActivity(transcript: transcript, status: status)
        } else {
            endActivity(transcript: transcript, status: nil)
        }
        completion(transcript)
    }

    private func cancel() {
        running = false
        segmentTimer?.invalidate()
        task?.cancel()
        task = nil
        stopEngine()
        requestLock.lock()
        request = nil
        requestLock.unlock()
        segmentId += 1
        committed = ""
        current = ""
        if let completion = stopCompletion {
            stopCompletion = nil
            completion("")
        }
        deactivateSession()
        endActivity(transcript: "", status: nil, immediately: true)
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func deactivateSession() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc private func onInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began,
              running else { return }
        // E.g. a phone call: keep what we have
        stopExternally()
    }

    // MARK: - Lock Screen control / Live Activity button

    func installIntentBridge() {
        VoiceIntentBridge.toggle = { [weak self] in
            guard let self = self else { return }
            if self.running {
                await self.stopAndWait()
            } else {
                try self.startFromIntent()
            }
        }
        VoiceIntentBridge.stop = { [weak self] in
            await self?.stopAndWait()
        }
        VoiceIntentBridge.openVoiceCapture = { [weak self] in
            self?.requestAction("voiceNote")
        }
    }

    private func startFromIntent() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw NSError(domain: "VoiceCapture", code: 10, userInfo: [NSLocalizedDescriptionKey: "Open Orgro and record a voice note once to allow microphone and speech recognition."])
        }
        let locale = UserDefaults.standard.string(forKey: localeDefaultsKey)
            ?? Locale.current.identifier(.bcp47)
        try start(locale: locale)
        origin = .intent
    }

    /// Stop from outside Flutter (Live Activity button, control, phone call)
    @MainActor
    private func stopAndWait() async {
        guard running else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            stopExternally { cont.resume() }
        }
    }

    private func stopExternally(_ done: (() -> Void)? = nil) {
        let wasApp = origin == .app
        stop { [weak self] transcript in
            // An in-app recording stopped elsewhere: hand the text to the UI
            if wasApp { self?.emit(["type": "interrupted", "text": transcript]) }
            done?()
        }
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Only one at a time
        for old in Activity<VoiceNoteAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let state = VoiceNoteAttributes.ContentState(transcript: "", startedAt: startedAt, recording: true, status: nil)
        do {
            activity = try Activity.request(
                attributes: VoiceNoteAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            logger.error("Failed to start Live Activity: \(error)")
        }
    }

    /// Updates are throttled; the system rate-limits Live Activities anyway
    private func scheduleActivityUpdate() {
        guard activity != nil, !activityUpdateScheduled else { return }
        let wait = max(0, 1 - Date().timeIntervalSince(lastActivityUpdate))
        activityUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self else { return }
            self.activityUpdateScheduled = false
            guard self.running, let activity = self.activity else { return }
            self.lastActivityUpdate = Date()
            let state = VoiceNoteAttributes.ContentState(
                transcript: Self.tail(self.fullTranscript),
                startedAt: self.startedAt,
                recording: true,
                status: nil
            )
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        }
    }

    private func endActivity(transcript: String, status: String?, immediately: Bool = false) {
        guard let activity = activity else { return }
        self.activity = nil
        let state = VoiceNoteAttributes.ContentState(
            transcript: Self.tail(transcript),
            startedAt: startedAt,
            recording: false,
            status: status
        )
        let policy: ActivityUIDismissalPolicy = immediately ? .immediate : .after(Date().addingTimeInterval(5))
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
    }

    /// Keep Live Activity payloads small (4 KB limit)
    private static func tail(_ text: String, max: Int = 300) -> String {
        guard text.count > max else { return text }
        return "…" + text.suffix(max)
    }

    // MARK: - Saving without the Flutter UI

    /// Returns a status line for the Live Activity
    private func saveInBackground(_ transcript: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Nothing recorded" }
        let entry = Self.formatEntry(text, Date())
        guard let dir = UserDefaults.standard.string(forKey: dirDefaultsKey) else {
            addPending(entry)
            return "Saved; open Orgro to add it to your notes"
        }
        switch Self.append(dirIdentifier: dir, fileName: voiceNotesFileName, text: entry, header: Self.fileHeader()) {
        case .success:
            emit(["type": "savedInBackground"])
            return "Saved to \(voiceNotesFileName)"
        case .failure(let error):
            logger.error("Background save failed: \(error)")
            addPending(entry)
            return "Kept; open Orgro to add it to your notes"
        }
    }

    private func addPending(_ entry: String) {
        var pending = UserDefaults.standard.stringArray(forKey: pendingDefaultsKey) ?? []
        pending.append(entry)
        UserDefaults.standard.set(pending, forKey: pendingDefaultsKey)
    }

    private func flushPending() {
        guard let dir = UserDefaults.standard.string(forKey: dirDefaultsKey),
              let pending = UserDefaults.standard.stringArray(forKey: pendingDefaultsKey),
              !pending.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            if case .success = Self.append(dirIdentifier: dir, fileName: voiceNotesFileName, text: pending.joined(), header: Self.fileHeader()) {
                DispatchQueue.main.async {
                    UserDefaults.standard.removeObject(forKey: pendingDefaultsKey)
                    self.emit(["type": "savedInBackground"])
                }
            }
        }
    }

    // Same format as formatVoiceEntry in lib/src/voice/voice.dart
    static func formatEntry(_ transcript: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
        let body = transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("*") ? ",\($0)" : String($0) }
            .joined(separator: "\n")
        return "* \(entryTitle(transcript))\n[\(formatter.string(from: date))]\n\(body)\n"
    }

    static func entryTitle(_ transcript: String, maxWords: Int = 8) -> String {
        let words = transcript.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return "Voice note" }
        var taken = words.prefix(maxWords).joined(separator: " ")
        while let last = taken.last, ".,;:!?".contains(last) { taken.removeLast() }
        return words.count > maxWords ? "\(taken)…" : taken
    }

    static func fileHeader() -> String {
        ":PROPERTIES:\n:ID:       \(UUID().uuidString.lowercased())\n:END:\n#+title: Voice Notes\n#+filetags: :voice:\n\n"
    }

    // MARK: - Writing

    /// Append text to a file in a directory the user granted access to,
    /// creating it with `header` if it doesn't exist yet.
    private func appendToFile(_ args: [String: Any?], _ result: @escaping FlutterResult) {
        guard let dirIdentifier = args["dirIdentifier"] as? String,
              let fileName = args["fileName"] as? String,
              let text = args["text"] as? String else {
            result(FlutterError(code: "MissingArgs", message: "appendToFile requires 'dirIdentifier', 'fileName', 'text'", details: nil))
            return
        }
        let header = args["header"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.append(dirIdentifier: dirIdentifier, fileName: fileName, text: text, header: header)
            DispatchQueue.main.async {
                switch outcome {
                case .success(let info): result(info)
                case .failure(let error):
                    result(FlutterError(code: "WriteFailed", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private static func append(dirIdentifier: String, fileName: String, text: String, header: String) -> Result<[String: String], Error> {
        guard let bookmark = Data(base64Encoded: dirIdentifier) else {
            return .failure(NSError(domain: "VoiceCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid directory identifier"]))
        }
        var stale = false
        let dir: URL
        do {
            dir = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        } catch {
            return .failure(error)
        }
        guard dir.startAccessingSecurityScopedResource() else {
            return .failure(NSError(domain: "VoiceCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "No access to the notes folder"]))
        }
        defer { dir.stopAccessingSecurityScopedResource() }

        let file = dir.appendingPathComponent(fileName)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forUpdating: url)
                    defer { try? handle.close() }
                    let end = try handle.seekToEnd()
                    var prefix = ""
                    if end > 0 {
                        try handle.seek(toOffset: end - 1)
                        let last = try handle.read(upToCount: 1)
                        if last != Data("\n".utf8) { prefix = "\n" }
                        try handle.seekToEnd()
                    }
                    try handle.write(contentsOf: Data((prefix + text).utf8))
                } else {
                    try (header + text).write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                writeError = error
            }
        }
        if let error = coordError ?? writeError {
            return .failure(error)
        }
        guard let fileBookmark = try? file.bookmarkData() else {
            return .failure(NSError(domain: "VoiceCapture", code: 5, userInfo: [NSLocalizedDescriptionKey: "Saved, but couldn’t get a reference to the file"]))
        }
        return .success([
            "identifier": fileBookmark.base64EncodedString(),
            "uri": file.absoluteString,
            "fileName": fileName,
        ])
    }
}

// MARK: - App Shortcut (Shortcuts app, Siri, Action button, and the Lock
// Screen/Control Center "Shortcut" control)

struct RecordVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Note"
    static let description = IntentDescription("Dictate a note into Orgro’s voice notes file.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceCapture.shared.requestAction("voiceNote")
        return .result()
    }
}

struct OrgroAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordVoiceNoteIntent(),
            phrases: [
                "Record a voice note in \(.applicationName)",
                "\(.applicationName) voice note",
            ],
            shortTitle: "Voice Note",
            systemImageName: "mic.fill"
        )
    }
}
