//
//  VoiceShared.swift
//  Compiled into both Runner and the OrgroWidgets extension.
//
//  The intents run in the app's process (the system launches Orgro in the
//  background for them); the extension only needs their types for the
//  Control and Live Activity buttons.
//

import ActivityKit
import AppIntents
import Foundation
import os

fileprivate let intentLogger = Logger(subsystem: "io.github.jonastfo.orgro", category: "VoiceIntents")

struct VoiceNoteAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Tail of the transcript so far
        var transcript: String
        var startedAt: Date
        var recording: Bool
        /// Shown after stopping, e.g. "Saved to voice-notes.org"
        var status: String?
    }
}

/// Hooks the app installs at launch; nil inside the widget extension
enum VoiceIntentBridge {
    nonisolated(unsafe) static var toggle: (@MainActor () async throws -> Void)?
    nonisolated(unsafe) static var stop: (@MainActor () async throws -> Void)?
    nonisolated(unsafe) static var openVoiceCapture: (@MainActor () -> Void)?

    /// Logs when an intent ran somewhere the app's hooks aren't installed
    /// (i.e. inside the widget extension), which would make it a no-op
    static func missing(_ name: String) {
        intentLogger.error("\(name, privacy: .public): app hook missing; running in \(Bundle.main.bundleIdentifier ?? "?", privacy: .public)")
    }
}

/// Start (or stop and save) dictation without opening the app. Used by the
/// Lock Screen / Control Center control and the Lock Screen widget.
///
/// LiveActivityIntent makes the system run perform() in the app's process
/// (where the recorder lives) rather than in the widget extension.
@available(iOS 18.0, *)
struct ToggleVoiceRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Voice Note Recording"
    static let description = IntentDescription("Starts dictating a voice note into Orgro, or stops and saves the current one.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let toggle = VoiceIntentBridge.toggle else {
            VoiceIntentBridge.missing("ToggleVoiceRecordingIntent")
            return .result()
        }
        try await toggle()
        return .result()
    }
}

/// Fallback for the control: opens Orgro and starts dictating there (needs
/// the phone unlocked)
struct OpenVoiceCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Orgro Voice Note"
    static let description = IntentDescription("Opens Orgro and starts dictating a voice note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let open = VoiceIntentBridge.openVoiceCapture else {
            VoiceIntentBridge.missing("OpenVoiceCaptureIntent")
            return .result()
        }
        open()
        return .result()
    }
}

/// The Stop & Save button in the Live Activity
struct StopVoiceRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Voice Note"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let stop = VoiceIntentBridge.stop else {
            VoiceIntentBridge.missing("StopVoiceRecordingIntent")
            return .result()
        }
        try await stop()
        return .result()
    }
}
