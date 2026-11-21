//
//  OrgroWidgetsBundle.swift
//  OrgroWidgets
//

import SwiftUI
import WidgetKit
import os

// Diagnostics: shows whether iOS starts the extension at all
let widgetLogger = Logger(subsystem: "io.github.jonastfo.orgro.OrgroWidgets", category: "Widgets")

@main
struct OrgroWidgetsBundle: WidgetBundle {
    init() {
        widgetLogger.notice("OrgroWidgets extension started")
    }

    var body: some Widget {
        RecordVoiceNoteControl()
        OpenVoiceNoteControl()
        VoiceNoteLockScreenWidget()
        VoiceNoteLiveActivity()
    }
}
