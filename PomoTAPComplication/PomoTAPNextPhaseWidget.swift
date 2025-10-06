//
//  PomoTAPNextPhaseWidget.swift
//  PomoTAPComplication
//
//  Created for Pomo TAP watchOS app
//

import WidgetKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "NextPhaseWidget")

// MARK: - Next Phase Entry
struct NextPhaseEntry: TimelineEntry {
    let date: Date
    let nextPhaseName: String
    let remainingTime: Int
    let isRunning: Bool

    static var placeholder: NextPhaseEntry {
        NextPhaseEntry(
            date: Date(),
            nextPhaseName: "Short Break",
            remainingTime: 900,
            isRunning: true
        )
    }
}

// MARK: - Next Phase Provider
struct NextPhaseProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextPhaseEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (NextPhaseEntry) -> ()) {
        do {
            let entry = try loadNextPhaseState()
            completion(entry)
        } catch {
            logger.error("获取NextPhase快照失败: \(error.localizedDescription)")
            completion(.placeholder)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextPhaseEntry>) -> ()) {
        do {
            let currentEntry = try loadNextPhaseState()

            // Dynamic timeline - updates as timer progresses
            if currentEntry.isRunning {
                var entries: [NextPhaseEntry] = [currentEntry]
                let calendar = Calendar.current

                // Update every 5 minutes
                for minutesAhead in stride(from: 5, to: min(60, currentEntry.remainingTime / 60), by: 5) {
                    if let futureDate = calendar.date(byAdding: .minute, value: minutesAhead, to: Date()) {
                        let futureEntry = NextPhaseEntry(
                            date: futureDate,
                            nextPhaseName: currentEntry.nextPhaseName,
                            remainingTime: currentEntry.remainingTime - (minutesAhead * 60),
                            isRunning: true
                        )
                        entries.append(futureEntry)
                    }
                }

                let timeline = Timeline(entries: entries, policy: .atEnd)
                completion(timeline)
            } else {
                let timeline = Timeline(entries: [currentEntry], policy: .never)
                completion(timeline)
            }
        } catch {
            logger.error("获取NextPhase时间线失败: \(error.localizedDescription)")
            let timeline = Timeline(entries: [NextPhaseEntry.placeholder], policy: .never)
            completion(timeline)
        }
    }

    private func loadNextPhaseState() throws -> NextPhaseEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            throw ComplicationError.userDefaultsNotAccessible
        }

        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            throw ComplicationError.noDataAvailable
        }

        let state = try JSONDecoder().decode(SharedTimerState.self, from: data)

        // Calculate next phase
        let nextPhaseIndex = (state.currentPhaseIndex + 1) % state.phases.count
        let nextPhase = state.phases[nextPhaseIndex]

        logger.info("✅ NextPhase Widget成功加载状态: next=\(nextPhase.name), remaining=\(state.remainingTime)秒")

        return NextPhaseEntry(
            date: state.lastUpdateTime,
            nextPhaseName: nextPhase.name,
            remainingTime: state.remainingTime,
            isRunning: state.timerRunning
        )
    }
}

// MARK: - Next Phase Views

// Inline View
struct NextPhaseInlineView: View {
    var entry: NextPhaseEntry

    var body: some View {
        // HIG standard: 15pt regular rounded
        if entry.isRunning {
            Text("\(NSLocalizedString("Next", comment: "")): \(entry.nextPhaseName) · \(timeString(from: entry.remainingTime))")
                .font(WidgetTypography.Inline.text)
        } else {
            Text("\(NSLocalizedString("Next", comment: "")): \(entry.nextPhaseName)")
                .font(WidgetTypography.Inline.text)
        }
    }

    private func timeString(from seconds: Int) -> String {
        let minutes = seconds / 60
        return "\(minutes)m"
    }
}

// MARK: - Widget Main View
struct NextPhaseWidgetView: View {
    var entry: NextPhaseEntry

    var body: some View {
        NextPhaseInlineView(entry: entry)
            .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

// MARK: - Widget Definition
struct NextPhaseWidget: Widget {
    private let kind: String = "NextPhaseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextPhaseProvider()) { entry in
            NextPhaseWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Next", comment: ""))
        .description(NSLocalizedString("Widget_Next_Phase_Desc", comment: ""))
        .supportedFamilies([.accessoryInline])
        .containerBackgroundRemovable(true)
    }
}
