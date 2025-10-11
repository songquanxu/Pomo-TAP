//
//  PomoTAPNextPhaseWidget.swift
//  PomoTAPComplication
//

import WidgetKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "NextPhaseWidget")

struct NextPhaseEntry: TimelineEntry {
    let date: Date
    let state: SmartStackDisplayState

    static var placeholder: NextPhaseEntry {
        let sampleState = SmartStackDisplayState(
            displayMode: .countdown,
            phaseType: .work,
            phaseName: "Work",
            isRunning: true,
            countdownRemaining: 25 * 60,
            flowElapsed: 0,
            totalDuration: 25 * 60,
            completedCycles: 2,
            hasSkippedInCurrentCycle: false,
            phaseStatuses: [.current, .notStarted, .notStarted, .notStarted],
            nextPhaseName: "Short Break",
            nextPhaseDuration: 5 * 60
        )
        return NextPhaseEntry(date: Date(), state: sampleState)
    }
}

struct NextPhaseProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextPhaseEntry {
        NextPhaseEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (NextPhaseEntry) -> Void) {
        do {
            completion(try loadEntry())
        } catch {
            logger.error("获取NextPhase快照失败: \(error.localizedDescription)")
            completion(NextPhaseEntry.placeholder)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextPhaseEntry>) -> Void) {
        do {
            let entry = try loadEntry()
            guard entry.state.isRunning else {
                completion(Timeline(entries: [entry], policy: .never))
                return
            }

            let timelineEntries = timeline(from: entry)
            completion(Timeline(entries: timelineEntries, policy: .atEnd))
        } catch {
            logger.error("获取NextPhase时间线失败: \(error.localizedDescription)")
            completion(Timeline(entries: [NextPhaseEntry.placeholder], policy: .never))
        }
    }

    private func loadEntry() throws -> NextPhaseEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            throw ComplicationError.userDefaultsNotAccessible
        }
        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            throw ComplicationError.noDataAvailable
        }

        let state = try JSONDecoder().decode(SharedTimerState.self, from: data)
        let adapter = WidgetStateAdapter(state: state)
        let displayState = adapter.makeSmartStackState()

        logger.info("✅ NextPhase加载: next=\(displayState.nextPhaseName ?? "nil"), mode=\(displayState.displayMode.rawValue)")

        return NextPhaseEntry(date: state.lastUpdateTime, state: displayState)
    }

    private func timeline(from entry: NextPhaseEntry) -> [NextPhaseEntry] {
        var entries: [NextPhaseEntry] = [entry]
        let calendar = Calendar.current
        let now = entry.date
        let state = entry.state

        if state.displayMode == .flow {
            for minute in 1...30 {
                guard let futureDate = calendar.date(byAdding: .minute, value: minute, to: now) else { continue }
                let newState = state.updatedForFlow(elapsed: state.flowElapsed + minute * 60)
                entries.append(NextPhaseEntry(date: futureDate, state: newState))
            }
        } else {
            let remainingMinutes = max(state.countdownRemaining / 60, 1)
            for minute in stride(from: 5, through: min(60, remainingMinutes), by: 5) {
                guard let futureDate = calendar.date(byAdding: .minute, value: minute, to: now) else { continue }
                let futureRemaining = max(state.countdownRemaining - minute * 60, 0)
                let newState = state.updatedForCountdown(remaining: futureRemaining)
                entries.append(NextPhaseEntry(date: futureDate, state: newState))
            }
        }

        return entries
    }
}

struct NextPhaseWidgetView: View {
    var entry: NextPhaseEntry

    var body: some View {
        Text(displayText(for: entry.state))
            .font(WidgetTypography.Inline.text)
            .widgetURL(URL(string: "pomoTAP://open")!)
    }

    private func displayText(for state: SmartStackDisplayState) -> String {
        let nextName = state.nextPhaseName ?? NSLocalizedString("Unknown", comment: "")
        switch state.displayMode {
        case .flow:
            return String(format: NSLocalizedString("Inline_Next_After_Flow", comment: ""), nextName, timeString(from: state.flowElapsed))
        case .countdown:
            return String(format: NSLocalizedString("Inline_Next_Countdown", comment: ""), nextName, timeString(from: state.countdownRemaining))
        case .paused:
            return String(format: NSLocalizedString("Inline_Next_Paused", comment: ""), nextName)
        case .idle:
            return String(format: NSLocalizedString("Inline_Next_Ready", comment: ""), nextName)
        }
    }

    private func timeString(from seconds: Int) -> String {
        let minutes = seconds / 60
        return "\(minutes)m"
    }
}

struct NextPhaseWidget: Widget {
    private let kind = "NextPhaseWidget"

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
