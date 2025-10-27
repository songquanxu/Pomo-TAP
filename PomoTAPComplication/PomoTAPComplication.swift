//
//  PomoTAPComplication.swift
//  PomoTAPComplication
//
//  Created by 许宗桢 on 2024/11/7.
//

import WidgetKit
import SwiftUI
import AppIntents
import os

#if os(watchOS)

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
            nextPhaseDuration: 5 * 60,
            completedCycles: 2,
            hasSkippedInCurrentCycle: false,
            phaseStatuses: [.current, .notStarted, .notStarted, .notStarted],
            phaseDurations: [25, 5, 25, 15]
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
        ZStack {
            AccessoryWidgetBackground()
            Gauge(value: gaugeProgress, in: 0...1) {
            } currentValueLabel: {
                Image(systemName: entry.state.isInFlow ? "infinity" : phaseSymbol(for: entry.state))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(iconColor)
                    .widgetAccentable()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(ringColor)
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "pomoTAP://open")!)
    }

    private var gaugeProgress: Double {
        let baseProgress = entry.state.isInFlow ? 1.0 : entry.state.progressValueForGauge
        return min(max(baseProgress, 0.0), 1.0)
    }

    private var ringColor: Color {
        if entry.state.isInFlow {
            return .yellow
        }
        return entry.state.isRunning ? .orange : .white.opacity(0.4)
    }

    private var iconColor: Color {
        if entry.state.isInFlow {
            return .yellow
        }
        return entry.state.isRunning ? .orange : .white.opacity(0.6)
    }
}

struct RectangularComplicationView: View {
    @Environment(\.widgetRenderingMode) var renderingMode
    var entry: ComplicationEntry

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // 左侧：Gauge + Button（交互）
            Button(intent: ToggleTimerIntent()) {
                Gauge(value: gaugeProgress, in: 0...1) {
                } currentValueLabel: {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(ringColor)
            }
            .buttonStyle(.plain)
            .frame(width: 42, height: 42)

            // 右侧：信息区域（通过 widgetURL 打开 app）
            VStack(alignment: .leading, spacing: 3) {
                // 第一行：软件名 + 成就
                HStack {
                    Text(appName)
                        .font(.system(size: 11, weight: .medium))

                    Spacer()

                    Label("×\(entry.state.completedCycles)", systemImage: "medal.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(medalColor)
                }

                // 第二行：阶段时长 + 心流
                HStack {
                    phaseDurationIndicators

                    Spacer()

                    Image(systemName: "infinity")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(flowIndicatorColor)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "pomoTAP://open")!)
    }

    // MARK: - 左侧 Gauge 相关

    private var gaugeProgress: Double {
        min(max(entry.state.progressValueForGauge, 0.0), 1.0)
    }

    private var buttonIcon: String {
        entry.state.isRunning ? "pause.fill" : "play.fill"
    }

    private var ringColor: Color {
        if entry.state.isInFlow {
            return .yellow
        }
        return entry.state.isRunning ? .orange : .white.opacity(0.35)
    }

    private var iconColor: Color {
        if entry.state.isInFlow {
            return .yellow
        }
        return entry.state.isRunning ? .orange : .white.opacity(0.6)
    }

    // MARK: - 右侧信息区域相关

    private var appName: String {
        NSLocalizedString("App_Name", comment: "")
    }

    private var medalColor: Color {
        entry.state.hasSkippedInCurrentCycle ? .green : .orange
    }

    private var flowIndicatorColor: Color {
        entry.state.isInFlow ? .yellow : .gray.opacity(0.5)
    }

    // MARK: - 阶段时长指示器

    private var phaseDurationIndicators: some View {
        HStack(spacing: 4) {
            ForEach(Array(displayedPhaseData.enumerated()), id: \.offset) { index, phaseData in
                VStack(spacing: 1) {
                    // 数字部分
                    Text("\(phaseData.duration)")
                        .font(phaseFont(for: phaseData.status))
                        .foregroundStyle(phaseColor(for: phaseData.status))
                        .widgetAccentable(shouldAccent(for: phaseData.status))

                    // accented 模式下：当前阶段显示圆点
                    if renderingMode == .accented && phaseData.status == .current {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 3, height: 3)
                            .widgetAccentable()
                    } else {
                        // 占位空间，保持视觉对齐
                        Color.clear.frame(width: 3, height: 3)
                    }
                }
            }
        }
    }

    private var displayedPhaseData: [(duration: Int, status: PhaseCompletionStatus)] {
        let durations = entry.state.phaseDurations
        let statuses = entry.state.phaseStatuses

        // 确保两个数组长度一致
        let count = min(durations.count, statuses.count, 4)  // 最多显示4个阶段

        return (0..<count).map { index in
            (duration: durations[index], status: statuses[index])
        }
    }

    private func phaseFont(for status: PhaseCompletionStatus) -> Font {
        // accented 模式：用字体粗细区分状态
        if renderingMode == .accented {
            switch status {
            case .current:
                // 当前：常规字体（因为有圆点标记）
                return .system(size: 13, weight: .semibold, design: .rounded)
            case .normalCompleted:
                // 已完成：加粗字体
                return .system(size: 13, weight: .bold, design: .rounded)
            case .skipped, .notStarted:
                // 跳过/未开始：常规字体
                return .system(size: 13, weight: .regular, design: .rounded)
            }
        }

        // fullColor 模式：统一字体
        return .system(size: 13, weight: .bold, design: .rounded)
    }

    private func phaseColor(for status: PhaseCompletionStatus) -> Color {
        // fullColor 模式：完整配色方案（与主界面一致）
        if renderingMode == .fullColor {
            switch status {
            case .current:
                // 当前阶段：流模式时黄色，否则白色
                return entry.state.isInFlow ? .yellow : .white
            case .normalCompleted:
                return .orange
            case .skipped:
                return .green
            case .notStarted:
                return .gray.opacity(0.4)
            }
        }

        // accented 模式：用不透明度区分（系统会自动应用表盘强调色）
        switch status {
        case .current:
            return .primary.opacity(1.0)  // 圆点会标记，保持最高亮度
        case .normalCompleted:
            return .primary.opacity(0.9)  // 稍微暗一点
        case .skipped:
            return .primary.opacity(0.7)  // 更暗
        case .notStarted:
            return .primary.opacity(0.4)  // 最暗
        }
    }

    private func shouldAccent(for status: PhaseCompletionStatus) -> Bool {
        // 在 accented 模式下，有意义的阶段都接受强调色
        // 在 fullColor 模式下，不需要 widgetAccentable（我们自己控制颜色）
        if renderingMode == .accented {
            // 未开始阶段不接受强调色，其他状态都接受
            return status != .notStarted
        }
        return false
    }
}

struct InlineComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        Text(inlineText(for: entry.state))
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .containerBackground(.clear, for: .widget)
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
            ProgressView(value: entry.state.progressValueForGauge, total: 1.0)
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
            nextPhaseDuration: nextPhaseDuration,
            completedCycles: completedCycles,
            hasSkippedInCurrentCycle: hasSkippedInCurrentCycle,
            phaseStatuses: phaseStatuses,
            phaseDurations: phaseDurations
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
            nextPhaseDuration: nextPhaseDuration,
            completedCycles: completedCycles,
            hasSkippedInCurrentCycle: hasSkippedInCurrentCycle,
            phaseStatuses: phaseStatuses,
            phaseDurations: phaseDurations
        )
    }
}

// MARK: - Widget Entry View
struct PomoTAPComplicationView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var entry: ComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            CircularComplicationView(entry: entry)
        case .accessoryRectangular:
            RectangularComplicationView(entry: entry)
        case .accessoryInline:
            InlineComplicationView(entry: entry)
        case .accessoryCorner:
            CornerComplicationView(entry: entry)
        default:
            CircularComplicationView(entry: entry)
        }
    }
}

// MARK: - Widget Definition
struct PomoTAPComplication: Widget {
    private let kind = "PomoTAPComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            PomoTAPComplicationView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Focus", comment: ""))
        .description("Pomodoro timer")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
        .containerBackgroundRemovable(true)
    }
}

// MARK: - Widget Bundle
@main
struct PomoTAPWidgetBundle: WidgetBundle {
    var body: some Widget {
        PomoTAPComplication()
        QuickStartWorkWidget()
        QuickStartBreakWidget()
        StatsWidget()
        NextPhaseWidget()
    }
}

#endif
