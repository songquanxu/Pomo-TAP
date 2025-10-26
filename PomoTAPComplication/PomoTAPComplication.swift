//
//  PomoTAPComplication.swift
//  PomoTAPComplication
//
//  Created by 许宗桢 on 2024/11/7.
//

import WidgetKit
import SwiftUI
import os
import WatchKit

// MARK: - 日志
private let logger = Logger(
    subsystem: "com.songquan.pomoTAP",
    category: "PomoTAPComplication"
)

// MARK: - 时间线模型
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let state: ComplicationDisplayState
    let relevance: TimelineEntryRelevance?
}

// MARK: - Provider
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        let sampleState = ComplicationDisplayState(
            displayMode: .countdown,
            phaseType: .work,
            isRunning: true,
            countdownRemaining: 25 * 60,
            flowElapsed: 0,
            totalDuration: 25 * 60,
            progress: 0.25,
            phaseEndDate: Date().addingTimeInterval(25 * 60),
            flowStartDate: nil,
            currentPhaseName: "Work",
            nextPhaseName: "Short Break",
            nextPhaseDuration: 5 * 60
        )
        return ComplicationEntry(date: Date(), state: sampleState, relevance: TimelineEntryRelevance(score: 10))
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        do {
            completion(try loadCurrentEntry())
        } catch {
            logger.error("获取快照失败: \(error.localizedDescription)")
            completion(placeholder(in: context))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        do {
            let currentEntry = try loadCurrentEntry()

            guard currentEntry.state.isRunning else {
                completion(Timeline(entries: [currentEntry], policy: .never))
                return
            }

            let highFrequency = currentEntry.state.isRunning && currentEntry.state.displayMode == .countdown
            let entries = timelineEntries(
                from: currentEntry,
                prefersHighFrequencyUpdates: highFrequency
            )
            completion(Timeline(entries: entries, policy: .atEnd))
        } catch {
            logger.error("生成时间线失败: \(error.localizedDescription)")
            completion(Timeline(entries: [placeholder(in: context)], policy: .never))
        }
    }

    // MARK: - Timeline helpers
    private func timelineEntries(
        from entry: ComplicationEntry,
        prefersHighFrequencyUpdates: Bool
    ) -> [ComplicationEntry] {
        var entries: [ComplicationEntry] = [entry]
        let calendar = Calendar.current
        let now = entry.date
        let state = entry.state

        if state.displayMode == .flow {
            // 心流模式：每分钟更新，最多 30 分钟
            let maxMinutes = 30
            for minute in 1...maxMinutes {
                guard let futureDate = calendar.date(byAdding: .minute, value: minute, to: now) else { continue }
                let futureState = state.updatedForFlow(elapsed: state.flowElapsed + minute * 60)
                let entry = ComplicationEntry(
                    date: futureDate,
                    state: futureState,
                    relevance: calculateRelevance(for: futureState, at: futureDate)
                )
                entries.append(entry)
            }
        } else {
            let remainingSeconds = state.countdownRemaining
            let intervals = prefersHighFrequencyUpdates
                ? generateActiveModeIntervals(remainingSeconds: remainingSeconds)
                : generateAODModeIntervals(remainingSeconds: remainingSeconds)

            for seconds in intervals {
                guard let futureDate = calendar.date(byAdding: .second, value: seconds, to: now) else { continue }
                let futureRemaining = max(remainingSeconds - seconds, 0)
                let futureState = state.updatedForCountdown(remaining: futureRemaining)
                let entry = ComplicationEntry(
                    date: futureDate,
                    state: futureState,
                    relevance: calculateRelevance(for: futureState, at: futureDate)
                )
                entries.append(entry)
            }

            if let endDate = calendar.date(byAdding: .second, value: remainingSeconds, to: now) {
                let finalState = state.updatedForCountdown(remaining: 0, isRunning: false, progress: 1.0)
                let finalEntry = ComplicationEntry(
                    date: endDate,
                    state: finalState,
                    relevance: TimelineEntryRelevance(score: 80)
                )
                entries.append(finalEntry)
            }
        }

        logger.debug("生成时间线：\(entries.count)条，模式：\(state.displayMode.rawValue)")
        return entries
    }

    private func calculateRelevance(for state: ComplicationDisplayState, at date: Date) -> TimelineEntryRelevance {
        var score: Float = 0

        if state.isRunning {
            score += 50
            if state.displayMode == .flow || state.countdownRemaining <= 300 {
                score += 30
            }
        } else {
            score += 10
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

    private func loadCurrentEntry() throws -> ComplicationEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            logger.error("无法访问共享 UserDefaults: \(SharedTimerState.suiteName)")
            throw ComplicationError.userDefaultsNotAccessible
        }

        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            logger.warning("未找到共享状态数据，key: \(SharedTimerState.userDefaultsKey)")
            throw ComplicationError.noDataAvailable
        }

        let state = try JSONDecoder().decode(SharedTimerState.self, from: data)
        logger.info("✅ Complication加载状态: phase=\(state.currentPhaseName), mode=\(state.displayMode.rawValue)")

        let adapter = WidgetStateAdapter(state: state)
        let displayState = adapter.makeComplicationState()
        let relevance = calculateRelevance(for: displayState, at: state.lastUpdateTime)

        return ComplicationEntry(date: state.lastUpdateTime, state: displayState, relevance: relevance)
    }

    // MARK: - 时间间隔生成
    private func generateActiveModeIntervals(remainingSeconds: Int) -> [Int] {
        generateTimeIntervals(remainingSeconds: remainingSeconds)
    }

    private func generateAODModeIntervals(remainingSeconds: Int) -> [Int] {
        var intervals: [Int] = []
        for second in stride(from: 300, to: remainingSeconds, by: 300) {
            intervals.append(second)
        }
        if remainingSeconds > 60 && remainingSeconds < 300 {
            intervals.append(remainingSeconds - 60)
        }
        return intervals
    }

    private func generateTimeIntervals(remainingSeconds: Int) -> [Int] {
        var intervals: [Int] = []
        let firstPhaseEnd = min(5 * 60, remainingSeconds)
        let lastPhaseStart = max(remainingSeconds - 5 * 60, firstPhaseEnd)

        for second in stride(from: 60, to: firstPhaseEnd, by: 60) {
            intervals.append(second)
        }
        if lastPhaseStart > firstPhaseEnd {
            for second in stride(from: firstPhaseEnd + 300, to: lastPhaseStart, by: 300) {
                intervals.append(second)
            }
        }
        if lastPhaseStart < remainingSeconds {
            let startMinute = (lastPhaseStart / 60 + 1) * 60
            for second in stride(from: startMinute, to: remainingSeconds, by: 60) {
                intervals.append(second)
            }
        }
        return intervals
    }
}

// MARK: - 错误类型
enum ComplicationError: Error {
    case userDefaultsNotAccessible
    case noDataAvailable
    case decodingFailed(Error)
}

// MARK: - 视图
struct CircularComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        if entry.state.isInFlow {
            // Flow mode: show infinity icon with full ring
            Gauge(value: 1.0, in: 0...1) {
            } currentValueLabel: {
                Image(systemName: "infinity")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.yellow)
                    .widgetAccentable()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.yellow)
            .containerBackground(.clear, for: .widget)
            .widgetURL(URL(string: "pomoTAP://open")!)
        } else {
            // Normal countdown mode: show phase icon with progress ring
            Gauge(value: entry.state.progress, in: 0...1) {
            } currentValueLabel: {
                Image(systemName: phaseSymbol(for: entry.state))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(entry.state.isRunning ? .orange : .white.opacity(0.6))
                    .widgetAccentable()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(entry.state.isRunning ? .orange : .white.opacity(0.4))
            .containerBackground(.clear, for: .widget)
            .widgetURL(URL(string: "pomoTAP://open")!)
        }
    }
}

struct RectangularComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: phaseSymbol(for: entry.state))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(entry.state.isRunning ? .orange : .white.opacity(0.6))
                    .widgetAccentable()
                Text(phaseName(for: entry.state))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(entry.state.isRunning ? .primary : .secondary)
                Spacer()
            }
            Text(primaryTimeText(for: entry.state))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(entry.state.isRunning ? .primary : .secondary)
                .lineLimit(1)
            ProgressView(value: entry.state.progressValueForGauge)
                .tint(entry.state.isRunning ? .orange : .white.opacity(0.4))
                .frame(height: 4)
        }
        .padding(.vertical, 2)
        .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

struct InlineComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        Text(inlineText(for: entry.state))
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

struct CornerComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: phaseSymbol(for: entry.state))
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(entry.state.isRunning ? .orange : .white.opacity(0.6))
                .widgetAccentable()
        }
        .widgetLabel {
            ProgressView(value: entry.state.progressValueForGauge) { }
                .tint(entry.state.isRunning ? .orange : .white.opacity(0.4))
        }
        .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

// MARK: - 视图辅助
private func phaseSymbol(for state: ComplicationDisplayState) -> String {
    // Flow mode: show infinity symbol
    if state.isInFlow {
        return "infinity"
    }

    // Normal/paused mode: state-aware icons
    switch state.phaseType {
    case .work:
        // Work phase: wand with sparkles (running) or stars (paused)
        return state.isRunning ? "wand.and.sparkles" : "wand.and.stars"
    case .shortBreak, .longBreak:
        // Break phases: cup with heat waves
        return "cup.and.heat.waves"
    case .unknown:
        return "wand.and.sparkles"
    }
}

private func phaseName(for state: ComplicationDisplayState) -> String {
    switch state.phaseType {
    case .work:
        return NSLocalizedString("Work", comment: "")
    case .shortBreak:
        return NSLocalizedString("Short_Break", comment: "")
    case .longBreak:
        return NSLocalizedString("Long_Break", comment: "")
    case .unknown:
        return state.currentPhaseName.capitalized
    }
}

private func inlineText(for state: ComplicationDisplayState) -> String {
    switch state.displayMode {
    case .flow:
        return "☄︎ \(timeString(from: state.flowElapsed))"
    case .countdown:
        return "\(phaseEmoji(for: state)) \(timeString(from: state.countdownRemaining))"
    case .paused:
        return "⏸ \(phaseName(for: state))"
    case .idle:
        return "▶︎ \(phaseName(for: state))"
    }
}

private func phaseEmoji(for state: ComplicationDisplayState) -> String {
    switch state.phaseType {
    case .work:
        return "🍅"
    case .shortBreak:
        return "☕️"
    case .longBreak:
        return "🛌"
    case .unknown:
        return "🍅"
    }
}

private func primaryTimeText(for state: ComplicationDisplayState) -> String {
    switch state.displayMode {
    case .flow:
        return String(format: NSLocalizedString("Flow_Time_Format", comment: ""), timeString(from: state.flowElapsed))
    case .countdown:
        return timeString(from: state.countdownRemaining)
    case .paused:
        return NSLocalizedString("Paused", comment: "")
    case .idle:
        return NSLocalizedString("Ready", comment: "")
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

private extension ComplicationDisplayState {
    var progressValueForGauge: Double {
        if isInFlow {
            return min(Double(flowElapsed) / Double(max(totalDuration, 1)), 1.0)
        }
        return progress
    }

    func updatedForCountdown(remaining: Int, isRunning: Bool? = nil, progress: Double? = nil) -> ComplicationDisplayState {
        ComplicationDisplayState(
            displayMode: remaining > 0 ? .countdown : .idle,
            phaseType: phaseType,
            isRunning: isRunning ?? (remaining > 0),
            countdownRemaining: remaining,
            flowElapsed: 0,
            totalDuration: totalDuration,
            progress: progress ?? (totalDuration > 0 ? 1.0 - Double(remaining) / Double(totalDuration) : self.progress),
            phaseEndDate: phaseEndDate,
            flowStartDate: flowStartDate,
            currentPhaseName: currentPhaseName,
            nextPhaseName: nextPhaseName,
            nextPhaseDuration: nextPhaseDuration
        )
    }

    func updatedForFlow(elapsed: Int) -> ComplicationDisplayState {
        ComplicationDisplayState(
            displayMode: .flow,
            phaseType: phaseType,
            isRunning: true,
            countdownRemaining: 0,
            flowElapsed: elapsed,
            totalDuration: totalDuration,
            progress: progress,
            phaseEndDate: phaseEndDate,
            flowStartDate: flowStartDate,
            currentPhaseName: currentPhaseName,
            nextPhaseName: nextPhaseName,
            nextPhaseDuration: nextPhaseDuration
        )
    }
}
