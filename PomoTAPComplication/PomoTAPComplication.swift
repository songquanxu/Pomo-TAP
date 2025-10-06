//
//  PomoTAPComplication.swift
//  PomoTAPComplication
//
//  Created by 许宗桢 on 2024/11/7.
//

import WidgetKit
import SwiftUI
import os
import WatchKit  // Added for WKExtension.shared().applicationState

// 添加日志记录器
private let logger = Logger(
    subsystem: "com.songquan.pomoTAP",
    category: "PomoTAPComplication"
)

// 定义数据模型
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let phase: String
    let isRunning: Bool
    let progress: Double
    let totalMinutes: Int
    let remainingTime: Int
    let relevance: TimelineEntryRelevance?
}

// 提供数据的 Provider
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(
            date: Date(),
            phase: "work",
            isRunning: false,
            progress: 0.0,
            totalMinutes: 25,
            remainingTime: 1500,
            relevance: TimelineEntryRelevance(score: 10)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> ()) {
        do {
            let entry = try loadCurrentState()
            completion(entry)
        } catch {
            logger.error("获取快照失败: \(error.localizedDescription)")
            // 提供默认值作为回退方案
            completion(ComplicationEntry(
                date: Date(),
                phase: "work",
                isRunning: false,
                progress: 0.0,
                totalMinutes: 25,
                remainingTime: 1500,
                relevance: TimelineEntryRelevance(score: 10)
            ))
        }
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> ()) {
        do {
            let currentEntry = try loadCurrentState()

            // 如果计时器没有运行,只返回当前状态
            if !currentEntry.isRunning {
                let timeline = Timeline(entries: [currentEntry], policy: .never)
                completion(timeline)
                return
            }

            // 检测应用状态，用于自适应时间线策略
            let appState = WKExtension.shared().applicationState
            let isActiveOrForeground = (appState == .active || appState == .inactive)

            // 计时器运行时的逻辑 - 使用状态感知的稀疏采样策略
            var entries: [ComplicationEntry] = [currentEntry]
            let calendar = Calendar.current
            let now = Date()
            let remainingSeconds = currentEntry.remainingTime

            // 自适应采样策略：
            // - 活跃状态：使用稀疏采样（前5分钟每分钟、中间每5分钟、最后5分钟每分钟）
            // - AOD/后台状态：仅每5分钟更新，减少电池消耗
            let timeIntervals = isActiveOrForeground
                ? generateActiveModeIntervals(remainingSeconds: remainingSeconds)
                : generateAODModeIntervals(remainingSeconds: remainingSeconds)

            for interval in timeIntervals {
                if let futureDate = calendar.date(byAdding: .second, value: interval, to: now) {
                    let futureRemainingTime = remainingSeconds - interval
                    let futureProgress = 1.0 - Double(futureRemainingTime) / Double(currentEntry.totalMinutes * 60)

                    let entry = ComplicationEntry(
                        date: futureDate,
                        phase: currentEntry.phase,
                        isRunning: true,
                        progress: futureProgress,
                        totalMinutes: currentEntry.totalMinutes,
                        remainingTime: futureRemainingTime,
                        relevance: calculateRelevance(
                            isRunning: true,
                            remainingTime: futureRemainingTime,
                            totalTime: currentEntry.totalMinutes * 60,
                            date: futureDate
                        )
                    )
                    entries.append(entry)
                }
            }

            // 添加结束时间点
            if let endDate = calendar.date(byAdding: .second, value: remainingSeconds, to: now) {
                let finalEntry = ComplicationEntry(
                    date: endDate,
                    phase: currentEntry.phase,
                    isRunning: false,
                    progress: 1.0,
                    totalMinutes: currentEntry.totalMinutes,
                    remainingTime: 0,
                    relevance: TimelineEntryRelevance(score: 80)  // 阶段完成时高相关性
                )
                entries.append(finalEntry)
            }

            let timeline = Timeline(entries: entries, policy: .atEnd)
            logger.debug("生成时间线：\(entries.count)个条目，模式：\(isActiveOrForeground ? "活跃" : "AOD/后台")")
            completion(timeline)

        } catch {
            // 发生错误时，返回一个基本的时间线
            let entry = ComplicationEntry(
                date: Date(),
                phase: "work",
                isRunning: false,
                progress: 0.0,
                totalMinutes: 25,
                remainingTime: 1500,
                relevance: TimelineEntryRelevance(score: 10)
            )
            let timeline = Timeline(entries: [entry], policy: .never)
            completion(timeline)
        }
    }

    // 活跃模式时间间隔生成（原稀疏采样策略）
    private func generateActiveModeIntervals(remainingSeconds: Int) -> [Int] {
        return generateTimeIntervals(remainingSeconds: remainingSeconds)
    }

    // AOD/后台模式时间间隔生成（仅每5分钟更新）
    private func generateAODModeIntervals(remainingSeconds: Int) -> [Int] {
        var intervals: [Int] = []

        // 每5分钟更新一次，直到剩余时间结束
        for second in stride(from: 300, to: remainingSeconds, by: 300) {
            intervals.append(second)
        }

        // 如果剩余时间不足5分钟，至少在结束前1分钟更新一次
        if remainingSeconds > 60 && remainingSeconds < 300 {
            intervals.append(remainingSeconds - 60)
        }

        return intervals
    }

    private func generateTimeIntervals(remainingSeconds: Int) -> [Int] {
        var intervals: [Int] = []

        let firstPhaseEnd = min(5 * 60, remainingSeconds) // 前5分钟
        let lastPhaseStart = max(remainingSeconds - 5 * 60, firstPhaseEnd) // 最后5分钟

        // 前5分钟：每分钟
        for second in stride(from: 60, to: firstPhaseEnd, by: 60) {
            intervals.append(second)
        }

        // 中间阶段：每5分钟
        if lastPhaseStart > firstPhaseEnd {
            for second in stride(from: firstPhaseEnd + 300, to: lastPhaseStart, by: 300) {
                intervals.append(second)
            }
        }

        // 最后5分钟：每分钟
        if lastPhaseStart < remainingSeconds {
            let startMinute = (lastPhaseStart / 60 + 1) * 60 // 向上取整到下一分钟
            for second in stride(from: startMinute, to: remainingSeconds, by: 60) {
                intervals.append(second)
            }
        }

        return intervals
    }

    private func calculateRelevance(
        isRunning: Bool,
        remainingTime: Int,
        totalTime: Int,
        date: Date
    ) -> TimelineEntryRelevance {
        var score: Float = 0

        // 基础分数：计时器运行状态（0-50分）
        if isRunning {
            score += 50

            // 阶段即将结束：最后5分钟提升相关性（+30分）
            if remainingTime <= 300 {
                score += 30
            }
        } else {
            score += 10  // 暂停状态仍有一定相关性
        }

        // 时间上下文：工作日工作时间段（+5分，降低权重）
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)

        // weekday: 1=周日, 2=周一, ..., 7=周六
        // 工作日(周一到周五)且工作时间(9:00-18:00)
        if (2...6).contains(weekday) && (9...18).contains(hour) {
            score += 5  // 降低权重，Focus mode 更重要
        }

        // NEW: 休息即将到来加成（+10分）
        // 工作阶段最后10分钟，用户希望知道何时休息
        if isWorkPhaseActive() && remainingTime <= 600 && remainingTime > 300 {
            score += 10
        }

        // 分数范围：0-100
        return TimelineEntryRelevance(score: min(score, 100))
    }

    // Helper: 检测当前是否为工作阶段
    // watchOS 26: 使用共享状态判断阶段类型
    private func isWorkPhaseActive() -> Bool {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName),
              let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey),
              let state = try? JSONDecoder().decode(SharedTimerState.self, from: data) else {
            return false
        }

        return state.isCurrentPhaseWorkPhase
    }
    
    private func loadCurrentState() throws -> ComplicationEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            logger.error("无法访问共享 UserDefaults: \(SharedTimerState.suiteName)")
            throw ComplicationError.userDefaultsNotAccessible
        }

        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            logger.warning("未找到共享状态数据，key: \(SharedTimerState.userDefaultsKey)")
            throw ComplicationError.noDataAvailable
        }

        do {
            let state = try JSONDecoder().decode(SharedTimerState.self, from: data)
            logger.info("✅ Widget成功加载状态: phase=\(state.currentPhaseName), running=\(state.timerRunning), remaining=\(state.remainingTime)秒")

            // 计算相关性分数
            let relevance = calculateRelevance(
                isRunning: state.timerRunning,
                remainingTime: state.remainingTime,
                totalTime: state.totalTime,
                date: state.lastUpdateTime
            )

            return ComplicationEntry(
                date: state.lastUpdateTime,
                phase: state.standardizedPhaseName,
                isRunning: state.timerRunning,
                progress: state.progress,
                totalMinutes: state.totalTime / 60,
                remainingTime: state.remainingTime,
                relevance: relevance
            )
        } catch {
            logger.error("解码状态失败: \(error)")
            throw ComplicationError.decodingFailed(error)
        }
    }
}

// 添加错误类型
enum ComplicationError: Error {
    case userDefaultsNotAccessible
    case noDataAvailable
    case decodingFailed(Error)
    
    var localizedDescription: String {
        switch self {
        case .userDefaultsNotAccessible:
            return "无法访问共享 UserDefaults"
        case .noDataAvailable:
            return "未找到共享状态数据"
        case .decodingFailed(let error):
            return "解码状态失败: \(error.localizedDescription)"
        }
    }
}

// 复杂功能视图 - Circular
// Uses Apple's Gauge system control with .accessoryCircular style
// Reference: WWDC 2022 "Go further with Complications in WidgetKit"
struct CircularComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        // Apple HIG: Use Gauge for circular progress complications
        Gauge(value: entry.progress, in: 0...1) {
            // Empty label - not shown in accessoryCircular
        } currentValueLabel: {
            // Center content: Phase icon
            Image(systemName: phaseSymbol(for: entry))
                .font(WidgetTypography.Circular.icon)
                .foregroundStyle(entry.isRunning ? .orange : .gray)
                .widgetAccentable()
        }
        .gaugeStyle(.accessoryCircular)
        .tint(entry.isRunning ? .orange : .gray)
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

// Rectangular 视图 - 矩形布局
struct RectangularComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 第1行：阶段图标 + 名称 - HIG standard: 13pt semibold
            HStack(spacing: 4) {
                Image(systemName: phaseSymbol(for: entry))
                    .font(WidgetTypography.Rectangular.title)
                    .widgetAccentable()
                Text(phaseName(for: entry))
                    .font(WidgetTypography.Rectangular.title)
                Spacer()
            }
            .foregroundStyle(entry.isRunning ? .orange : .gray)

            // 第2行：剩余时间 - HIG standard: 17pt semibold rounded
            Text(timeString(from: entry.remainingTime))
                .font(WidgetTypography.Rectangular.body)
                .foregroundStyle(entry.isRunning ? .primary : .secondary)

            // 第3行：进度条
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // 背景
                    Capsule()
                        .fill(.gray.opacity(0.3))
                        .frame(height: 3)

                    // 进度
                    Capsule()
                        .fill(entry.isRunning ? .orange : .gray)
                        .frame(width: geometry.size.width * entry.progress, height: 3)
                }
            }
            .frame(height: 3)
        }
        .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

// Inline 视图 - 单行文本
struct InlineComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        Text("\(phaseEmoji(for: entry)) \(phaseName(for: entry)) · \(timeString(from: entry.remainingTime))")
            .font(WidgetTypography.Inline.text)  // HIG standard: 15pt regular rounded
            .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

// Corner 视图 - 角落布局（曲线）
// Uses AccessoryWidgetBackground + Gauge in widgetLabel
// Reference: WWDC 2022 "Go further with Complications in WidgetKit"
struct CornerComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        ZStack {
            // Apple HIG: AccessoryWidgetBackground for consistent backdrop
            AccessoryWidgetBackground()

            // Center icon
            Image(systemName: phaseSymbol(for: entry))
                .font(WidgetTypography.Corner.icon)
                .foregroundStyle(entry.isRunning ? .orange : .gray)
                .widgetAccentable()
        }
        .widgetLabel {
            // Apple HIG: Use Gauge in widgetLabel for curved progress + text
            Gauge(value: entry.progress, in: 0...1) {
                // Empty label
            } currentValueLabel: {
                Text(timeString(from: entry.remainingTime))
                    .font(WidgetTypography.Corner.label)
            }
            .tint(entry.isRunning ? .orange : .gray)
        }
        .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

// 辅助函数
private func phaseSymbol(for entry: ComplicationEntry) -> String {
    switch entry.phase {
    case "work":
        return entry.isRunning ? "brain.head.profile.fill" : "brain.head.profile"
    case "shortBreak":
        return entry.isRunning ? "cup.and.saucer.fill" : "cup.and.saucer"
    case "longBreak":
        return entry.isRunning ? "figure.walk.motion" : "figure.walk"
    default:
        return entry.isRunning ? "brain.head.profile.fill" : "brain.head.profile"
    }
}

private func phaseEmoji(for entry: ComplicationEntry) -> String {
    switch entry.phase {
    case "work": return "🍅"
    case "shortBreak": return "☕️"
    case "longBreak": return "🚶"
    default: return "🍅"
    }
}

private func phaseName(for entry: ComplicationEntry) -> String {
    switch entry.phase {
    case "work": return NSLocalizedString("Phase_Work", comment: "")
    case "shortBreak": return NSLocalizedString("Phase_Short_Break", comment: "")
    case "longBreak": return NSLocalizedString("Phase_Long_Break", comment: "")
    default: return NSLocalizedString("Phase_Work", comment: "")
    }
}

private func timeString(from seconds: Int) -> String {
    let minutes = seconds / 60
    let secs = seconds % 60
    if minutes > 0 {
        return String(format: "%d:%02d", minutes, secs)
    } else {
        return String(format: "0:%02d", secs)
    }
}

// 旧的 ComplicationView（保留向后兼容）
struct ComplicationView: View {
    var entry: ComplicationEntry

    var body: some View {
        CircularComplicationView(entry: entry)
    }
}

// Primary Timer Widget (Part of Bundle)
struct PomoTAPComplication: Widget {
    private let kind: String = "PomoTAPComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            PomoTAPWidgetView(entry: entry)
        }
        .configurationDisplayName("Pomo TAP")
        .description("显示当前番茄钟状态")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
        .containerBackgroundRemovable(true)
    }
}

// MARK: - Widget Bundle (All Widgets Entry Point)
@main
struct PomoTAPWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Primary timer widget
        PomoTAPComplication()
        // Quick start widgets
        QuickStartWorkWidget()
        QuickStartBreakWidget()
        // Cycle progress widget
        CycleProgressWidget()
        // Stats widget
        StatsWidget()
        // Next phase widget
        NextPhaseWidget()
        // Smart Stack interactive widget
        PomoTAPSmartStackWidget()
    }
}

// 主 Widget 视图，根据 family 自动选择
struct PomoTAPWidgetView: View {
    var entry: ComplicationEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
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

#Preview(as: .accessoryCircular) {
    PomoTAPComplication()
} timeline: {
    // 工作阶段 - 30% 进度
    ComplicationEntry(
        date: .now,
        phase: "work",
        isRunning: true,
        progress: 0.3,
        totalMinutes: 25,
        remainingTime: 1050,
        relevance: TimelineEntryRelevance(score: 50)
    )
    // 工作阶段 - 70% 进度
    ComplicationEntry(
        date: .now,
        phase: "work",
        isRunning: true,
        progress: 0.7,
        totalMinutes: 25,
        remainingTime: 450,
        relevance: TimelineEntryRelevance(score: 80)
    )
    // 短休息阶段 - 暂停状态
    ComplicationEntry(
        date: .now,
        phase: "shortBreak",
        isRunning: false,
        progress: 0.0,
        totalMinutes: 5,
        remainingTime: 300,
        relevance: TimelineEntryRelevance(score: 10)
    )
}
