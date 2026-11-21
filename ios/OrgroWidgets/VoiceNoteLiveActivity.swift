//
//  VoiceNoteLiveActivity.swift
//  OrgroWidgets
//
//  Live transcript on the Lock Screen and in the Dynamic Island while
//  dictating.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import os

// doom-horizon
private let bg = Color(red: 0x23 / 255, green: 0x25 / 255, blue: 0x30 / 255)
private let fg = Color(red: 0xc7 / 255, green: 0xc9 / 255, blue: 0xcb / 255)
private let dim = Color(red: 0x6a / 255, green: 0x6a / 255, blue: 0x6a / 255)
private let red = Color(red: 0xe9 / 255, green: 0x56 / 255, blue: 0x78 / 255)
private let green = Color(red: 0x09 / 255, green: 0xf7 / 255, blue: 0xa0 / 255)

struct VoiceNoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        widgetLogger.notice("VoiceNoteLiveActivity body requested")
        return ActivityConfiguration(for: VoiceNoteAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(bg)
                .activitySystemActionForegroundColor(fg)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.recording ? "mic.fill" : "checkmark.circle.fill")
                        .foregroundStyle(context.state.recording ? red : green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.recording {
                        Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .foregroundStyle(red)
                            .frame(maxWidth: 60)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        TranscriptText(state: context.state, lines: 3)
                        if context.state.recording {
                            StopButton()
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(red)
            } compactTrailing: {
                if context.state.recording {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .foregroundStyle(red)
                        .frame(maxWidth: 44)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(green)
                }
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(red)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: VoiceNoteAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.recording ? "mic.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.recording ? red : green)
                Text(state.recording ? "Recording voice note" : (state.status ?? "Saved"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(fg)
                Spacer()
                if state.recording {
                    Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .font(.subheadline)
                        .foregroundStyle(red)
                        .frame(maxWidth: 70, alignment: .trailing)
                }
            }
            TranscriptText(state: state, lines: 4)
            if state.recording {
                StopButton()
            }
        }
        .padding()
    }
}

private struct TranscriptText: View {
    let state: VoiceNoteAttributes.ContentState
    let lines: Int

    var body: some View {
        Text(state.transcript.isEmpty ? "Listening…" : state.transcript)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(state.transcript.isEmpty ? dim : fg)
            .lineLimit(lines)
            // Show the newest words when the transcript is long
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopVoiceRecordingIntent()) {
            Label("Stop & Save", systemImage: "stop.fill")
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .tint(red)
    }
}
