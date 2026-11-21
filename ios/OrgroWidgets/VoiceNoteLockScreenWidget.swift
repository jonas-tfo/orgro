//
//  VoiceNoteLockScreenWidget.swift
//  OrgroWidgets
//
//  A Lock Screen widget (the row under the clock) with a button that starts
//  dictating a voice note; tap again to stop and save.
//

import AppIntents
import SwiftUI
import WidgetKit
import os

struct VoiceNoteWidgetEntry: TimelineEntry {
    let date: Date
}

struct VoiceNoteWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceNoteWidgetEntry {
        VoiceNoteWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (VoiceNoteWidgetEntry) -> Void) {
        completion(VoiceNoteWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceNoteWidgetEntry>) -> Void) {
        // Static content: nothing to refresh
        completion(Timeline(entries: [VoiceNoteWidgetEntry(date: .now)], policy: .never))
    }
}

struct VoiceNoteLockScreenWidget: Widget {
    static let kind = "io.github.jonastfo.orgro.voice-note-widget"

    var body: some WidgetConfiguration {
        widgetLogger.notice("VoiceNoteLockScreenWidget body requested")
        return StaticConfiguration(kind: Self.kind, provider: VoiceNoteWidgetProvider()) { _ in
            VoiceNoteWidgetView()
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Orgro Voice Note")
        .description("Tap to dictate a voice note into your notes. Tap again to stop and save.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct VoiceNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Button(intent: ToggleVoiceRecordingIntent()) {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.title2)
                    VStack(alignment: .leading) {
                        Text("Voice Note").font(.headline)
                        Text("Tap to record").font(.caption)
                    }
                    Spacer(minLength: 0)
                }
            case .accessoryInline:
                Label("Voice Note", systemImage: "mic.fill")
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill").font(.title2)
                }
            }
        }
        .buttonStyle(.plain)
        .widgetAccentable()
    }
}
