//
//  PomoTAPSmartStackWidget.swift
//  PomoTAPComplication
//
//  Created for Pomo TAP watchOS app
//

import WidgetKit
import SwiftUI
import AppIntents
import os

private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "SmartStackWidget")

// MARK: - Timeline Entry
struct SmartStackEntry: TimelineEntry {
    let date: Date
    let state: SmartStackDisplayState
    let relevance: TimelineEntryRelevance?

    static var placeholder: SmartStackEntry {
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
        return SmartStackEntry(date: Date(), state: sampleState, relevance: TimelineEntryRelevance(score: 60))
    }
}

// MARK: - Provider
struct SmartStackProvider: TimelineProvider {
    func placeholder(in context: Context) -> SmartStackEntry {
        SmartStackEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SmartStackEntry) -> Void) {
        do {
            completion(try loadEntry())
        } catch {
            logger.error("获取Smart Stack快照失败: \(error.localizedDescription)")
            completion(SmartStackEntry.placeholder)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SmartStackEntry>) -> Void) {
        do {
            let entry = try loadEntry()
            guard entry.state.isRunning else {
                completion(Timeline(entries: [entry], policy: .never))
                return
            }

            let entries = timelineEntries(from: entry)
            completion(Timeline(entries: entries, policy: .atEnd))
        } catch {
            logger.error("获取Smart Stack时间线失败: \(error.localizedDescription)")
            completion(Timeline(entries: [SmartStackEntry.placeholder], policy: .never))
        }
    }

    private func loadEntry() throws -> SmartStackEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            throw ComplicationError.userDefaultsNotAccessible
        }
        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            throw ComplicationError.noDataAvailable
        }

        let state = try JSONDecoder().decode(SharedTimerState.self, from: data)
        let adapter = WidgetStateAdapter(state: state)
        let displayState = adapter.makeSmartStackState()
        let relevance = calculateRelevance(for: displayState, at: state.lastUpdateTime)

        logger.info("✅ Smart Stack加载: phase=\(displayState.phaseName), mode=\(displayState.displayMode.rawValue)")

        return SmartStackEntry(date: state.lastUpdateTime, state: displayState, relevance: relevance)
    }

    private func timelineEntries(from entry: SmartStackEntry) -> [SmartStackEntry] {
        var entries: [SmartStackEntry] = [entry]
        let calendar = Calendar.current
        let now = entry.date
        let state = entry.state

        if state.displayMode == .flow {
            for minute in 1...30 {
                guard let futureDate = calendar.date(byAdding: .minute, value: minute, to: now) else { continue }
                let futureState = state.updatedForFlow(elapsed: state.flowElapsed + minute * 60)
                let entry = SmartStackEntry(
                    date: futureDate,
                    state: futureState,
                    relevance: calculateRelevance(for: futureState, at: futureDate)
                )
                entries.append(entry)
            }
        } else {
            let totalMinutes = max(state.countdownRemaining / 60, 1)
            for minute in 1..<totalMinutes {
                guard let futureDate = calendar.date(byAdding: .minute, value: minute, to: now) else { continue }
                let futureRemaining = max(state.countdownRemaining - minute * 60, 0)
                let futureState = state.updatedForCountdown(remaining: futureRemaining)
                let entry = SmartStackEntry(
                    date: futureDate,
                    state: futureState,
                    relevance: calculateRelevance(for: futureState, at: futureDate)
                )
                entries.append(entry)
            }

            if let endDate = calendar.date(byAdding: .second, value: state.countdownRemaining, to: now) {
                let finalState = state.updatedForCountdown(remaining: 0, isRunning: false)
                entries.append(SmartStackEntry(date: endDate, state: finalState, relevance: TimelineEntryRelevance(score: 80)))
            }
        }

        return entries
    }

    private func calculateRelevance(for state: SmartStackDisplayState, at date: Date) -> TimelineEntryRelevance {
        var score: Float = 0
        if state.isRunning {
            score += 60
            if state.displayMode == .flow || state.countdownRemaining <= 300 {
                score += 30
            }
        } else {
            score += 20
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        if (2...6).contains(weekday) && (9...18).contains(hour) {
            score += 5
        }

        if state.phaseType == .work && state.countdownRemaining <= 600 && state.countdownRemaining > 300 {
            score += 10
        }

        return TimelineEntryRelevance(score: min(score, 100))
    }
}

// MARK: - Widget View
struct SmartStackWidgetView: View {
    var entry: SmartStackEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            primaryTime
            progressSection
            cycleSection
        }
        .padding(.vertical, 4)
        .widgetURL(URL(string: "pomoTAP://open")!)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: phaseSymbol(for: entry.state))
                .font(WidgetTypography.SmartStack.title)
                .foregroundStyle(phaseColor(for: entry.state))
                .widgetAccentable()
            Text(headerTitle(for: entry.state))
                .font(WidgetTypography.SmartStack.title)
                .foregroundStyle(.primary)
            Spacer()
            if entry.state.displayMode == .flow {
                Text(NSLocalizedString("FLOW", comment: "Flow mode badge"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.yellow.opacity(0.15)))
            }
        }
    }

    private var primaryTime: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primaryTimeText(for: entry.state))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            if let subtitle = secondaryText(for: entry.state) {
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressSection: some View {
        Group {
            if entry.state.displayMode == .flow {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.yellow)
                    Text(flowInfoText(for: entry.state))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView(value: entry.state.progressValueForGauge)
                    .tint(.orange)
                    .frame(height: 6)
            }
        }
    }

    private var cycleSection: some View {
        HStack(spacing: 4) {
            ForEach(entry.state.phaseStatuses.indices, id: \.self) { index in
                let status = entry.state.phaseStatuses[index]
                Circle()
                    .fill(statusColor(status, isCurrent: index == currentPhaseIndex))
                    .frame(width: 10, height: 10)
            }
            Spacer()
            Button(intent: ToggleTimerIntent()) {
                Image(systemName: entry.state.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
    }

    private var currentPhaseIndex: Int {
        // phaseStatuses 与 state.currentPhaseIndex 不一定同步，暂时用第一个 .current
        if let currentIndex = entry.state.phaseStatuses.firstIndex(of: .current) {
            return currentIndex
        }
        return 0
    }

    private func phaseColor(for state: SmartStackDisplayState) -> Color {
        switch state.phaseType {
        case .work:
            return .orange
        case .shortBreak:
            return .teal
        case .longBreak:
            return .indigo
        case .unknown:
            return .gray
        }
    }

    private func headerTitle(for state: SmartStackDisplayState) -> String {
        switch state.phaseType {
        case .work:
            return NSLocalizedString("Focus", comment: "")
        case .shortBreak:
            return NSLocalizedString("Short_Break", comment: "")
        case .longBreak:
            return NSLocalizedString("Long_Break", comment: "")
        case .unknown:
            return state.phaseName
        }
    }

    private func primaryTimeText(for state: SmartStackDisplayState) -> String {
        switch state.displayMode {
        case .flow:
            return timeString(from: state.flowElapsed)
        case .countdown:
            return timeString(from: state.countdownRemaining)
        case .paused:
            return NSLocalizedString("Paused", comment: "")
        case .idle:
            return NSLocalizedString("Ready", comment: "")
        }
    }

    private func secondaryText(for state: SmartStackDisplayState) -> String? {
        switch state.displayMode {
        case .flow:
            if let nextName = state.nextPhaseName {
                return String(format: NSLocalizedString("Next_After_Flow_Format", comment: ""), nextName)
            }
            return NSLocalizedString("Tap_to_stop_flow", comment: "")
        case .countdown:
            if let nextName = state.nextPhaseName {
                return String(format: NSLocalizedString("Next_Format", comment: ""), nextName)
            }
            return nil
        case .paused:
            return NSLocalizedString("Tap_to_resume", comment: "")
        case .idle:
            return NSLocalizedString("Tap_to_start", comment: "")
        }
    }

    private func flowInfoText(for state: SmartStackDisplayState) -> String {
        if let nextName = state.nextPhaseName {
            return String(format: NSLocalizedString("Flow_Info_Format", comment: ""), timeString(from: state.flowElapsed), nextName)
        }
        return timeString(from: state.flowElapsed)
    }

    private func statusColor(_ status: PhaseCompletionStatus, isCurrent: Bool) -> Color {
        if entry.state.displayMode == .flow && isCurrent {
            return .yellow
        }
        switch status {
        case .normalCompleted:
            return .orange
        case .skipped:
            return .green
        case .current:
            return .blue
        case .notStarted:
            return .gray.opacity(0.3)
        }
    }

    private func timeString(from seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remaining = minutes % 60
            return "\(hours)h \(remaining)m"
        }
        return "\(minutes)m"
    }

    private func phaseSymbol(for state: SmartStackDisplayState) -> String {
        switch state.phaseType {
        case .work:
            return "brain.head.profile.fill"
        case .shortBreak:
            return "cup.and.saucer.fill"
        case .longBreak:
            return "bed.double.fill"
        case .unknown:
            return "brain.head.profile"
        }
    }
}

// MARK: - Widget Definition
struct SmartStackWidget: Widget {
    private let kind = "PomoTAPSmartStackWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SmartStackProvider()) { entry in
            SmartStackWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Focus_Summary", comment: ""))
        .description(NSLocalizedString("Widget_Smart_Stack_Desc", comment: ""))
        .supportedFamilies([.accessoryRectangular])
        .containerBackgroundRemovable(true)
    }
}
