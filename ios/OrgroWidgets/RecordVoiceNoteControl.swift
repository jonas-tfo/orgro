//
//  RecordVoiceNoteControl.swift
//  OrgroWidgets
//
//  A button for the Lock Screen, Control Center and Action button that starts
//  dictating a voice note without opening Orgro; tap again to stop and save.
//

import AppIntents
import SwiftUI
import WidgetKit
import os

struct RecordVoiceNoteControl: ControlWidget {
    static let kind = "io.github.jonastfo.orgro.voice-note"

    var body: some ControlWidgetConfiguration {
        widgetLogger.notice("RecordVoiceNoteControl body requested")
        return StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleVoiceRecordingIntent()) {
                Label("Voice Note", systemImage: "mic.fill")
            }
        }
        .displayName("Orgro Voice Note")
        .description("Dictate a voice note into your notes without opening Orgro. Tap again to stop and save.")
    }
}

/// Fallback that opens Orgro (needs Face ID) and starts dictating there
struct OpenVoiceNoteControl: ControlWidget {
    static let kind = "io.github.jonastfo.orgro.voice-note-open"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenVoiceCaptureIntent()) {
                Label("Voice Note (Open App)", systemImage: "mic.badge.plus")
            }
        }
        .displayName("Orgro Voice Note (Open App)")
        .description("Opens Orgro and starts dictating a voice note.")
    }
}
