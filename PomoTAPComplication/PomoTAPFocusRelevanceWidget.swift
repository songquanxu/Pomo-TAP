//
//  PomoTAPFocusRelevanceWidget.swift
//  PomoTAPComplication
//
//  watchOS 26 智能叠放（Smart Stack）相关度小组件：
//  在专注 / 休息阶段临近结束时自动浮现到叠放顶部，抬腕即见、一划即用。
//

import AppIntents
import RelevanceKit
import SwiftUI
import WidgetKit
import os

#if os(watchOS)

private let relevanceLogger = Logger(subsystem: "com.songquan.pomoTAP", category: "SmartFocusWidget")

// MARK: - 配置意图
/// `RelevanceEntriesProvider` 要求一个 `WidgetConfigurationIntent`。本小组件无可配置项，
/// 仅作为相关度声明的载体，因此是一个无参数的空配置。
struct SmartFocusConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Smart_Focus_Name"
    init() {}
}

// MARK: - 相关度条目
struct SmartFocusEntry: RelevanceEntry {
    let state: ComplicationDisplayState
}

// MARK: - 相关度条目提供器
struct SmartFocusRelevanceProvider: RelevanceEntriesProvider {
    func placeholder(context: RelevanceEntriesProviderContext) -> SmartFocusEntry {
        SmartFocusEntry(state: .smartFocusPlaceholder)
    }

    func entry(configuration: SmartFocusConfigurationIntent,
               context: RelevanceEntriesProviderContext) async throws -> SmartFocusEntry {
        SmartFocusEntry(state: Self.currentState())
    }

    /// 声明何时应把卡片推到智能叠放顶部。
    /// - 倒计时运行：阶段结束前最后 5 分钟用 `.scheduled`（时间敏感、优先级最高）。
    /// - 心流正计时：当前起一段时间内用 `.default`，让深度专注期间也能随手取用。
    func relevance() async -> WidgetRelevance<SmartFocusConfigurationIntent> {
        guard let shared = Self.loadSharedState(), shared.timerRunning else {
            return WidgetRelevance([])
        }

        let now = Date()
        let configuration = SmartFocusConfigurationIntent()
        var attributes: [WidgetRelevanceAttribute<SmartFocusConfigurationIntent>] = []

        if shared.displayMode == .countdown, let endDate = shared.phaseEndDate, endDate > now {
            // 整个剩余阶段：低优先级常驻
            attributes.append(
                WidgetRelevanceAttribute(
                    configuration: configuration,
                    context: .date(interval: DateInterval(start: now, end: endDate), kind: .default)
                )
            )
            // 结束前最后 5 分钟：高优先级（时间敏感）
            let leadStart = max(endDate.addingTimeInterval(-5 * 60), now)
            if leadStart < endDate {
                attributes.append(
                    WidgetRelevanceAttribute(
                        configuration: configuration,
                        context: .date(interval: DateInterval(start: leadStart, end: endDate), kind: .scheduled)
                    )
                )
            }
        } else if shared.displayMode == .flow {
            // 心流无固定结束：从现在起 1 小时内保持可用
            attributes.append(
                WidgetRelevanceAttribute(
                    configuration: configuration,
                    context: .date(interval: DateInterval(start: now, end: now.addingTimeInterval(60 * 60)), kind: .default)
                )
            )
        }

        relevanceLogger.info("智能叠放相关度：\(attributes.count) 条，mode=\(shared.displayMode.rawValue)")
        return WidgetRelevance(attributes)
    }

    // MARK: - 共享状态读取
    static func loadSharedState() -> SharedTimerState? {
        guard let defaults = UserDefaults(suiteName: SharedTimerState.suiteName),
              let data = defaults.data(forKey: SharedTimerState.userDefaultsKey),
              let state = try? JSONDecoder().decode(SharedTimerState.self, from: data) else {
            return nil
        }
        return state
    }

    /// 以真实"现在"为锚点，从持久化日期重算实时剩余 / 已过时间。
    static func currentState() -> ComplicationDisplayState {
        guard let shared = loadSharedState() else {
            return .smartFocusPlaceholder
        }
        let base = WidgetStateAdapter(state: shared).makeComplicationState()
        let now = Date()
        if shared.displayMode == .countdown, shared.timerRunning, let endDate = shared.phaseEndDate {
            return base.updatedForCountdown(remaining: max(0, Int(endDate.timeIntervalSince(now).rounded(.up))))
        } else if shared.displayMode == .flow, let startDate = shared.flowStartDate {
            return base.updatedForFlow(elapsed: max(0, Int(now.timeIntervalSince(startDate))))
        }
        return base
    }
}

// MARK: - 占位状态
extension ComplicationDisplayState {
    static var smartFocusPlaceholder: ComplicationDisplayState {
        ComplicationDisplayState(
            displayMode: .countdown,
            phaseType: .work,
            isRunning: true,
            countdownRemaining: 5 * 60,
            flowElapsed: 0,
            totalDuration: 25 * 60,
            progress: 0.8,
            phaseEndDate: Date().addingTimeInterval(5 * 60),
            flowStartDate: nil,
            currentPhaseName: "Work",
            nextPhaseName: "Short Break",
            nextPhaseDuration: 5 * 60,
            completedCycles: 2,
            hasSkippedInCurrentCycle: false,
            phaseStatuses: [.current, .notStarted, .notStarted, .notStarted],
            phaseDurations: [25, 5, 25, 15]
        )
    }
}

// MARK: - 视图（智能叠放矩形卡片）
struct SmartFocusWidgetView: View {
    var entry: SmartFocusEntry

    var body: some View {
        let state = entry.state
        HStack(spacing: 10) {
            Gauge(value: min(max(state.progressValueForGauge, 0), 1), in: 0...1) {
            } currentValueLabel: {
                Image(systemName: iconName(for: state))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accentColor(for: state))
                    .widgetAccentable()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(accentColor(for: state))
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(phaseTitle(for: state))
                    .font(WidgetTypography.SmartStack.title)
                    .foregroundStyle(.primary)

                liveTime(for: state)
                    .font(WidgetTypography.SmartStack.time)
                    .foregroundStyle(accentColor(for: state))
            }

            Spacer(minLength: 0)
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "pomoTAP://open")!)
    }

    @ViewBuilder
    private func liveTime(for state: ComplicationDisplayState) -> some View {
        if state.displayMode == .countdown, state.isRunning, let endDate = state.phaseEndDate {
            Text(endDate, style: .timer)
        } else if state.displayMode == .flow, let startDate = state.flowStartDate {
            Text("☄︎ \(startDate, style: .timer)")
        } else {
            Text(staticTime(for: state))
        }
    }

    private func staticTime(for state: ComplicationDisplayState) -> String {
        let seconds = state.isInFlow ? state.flowElapsed : state.countdownRemaining
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private func iconName(for state: ComplicationDisplayState) -> String {
        if state.isInFlow { return "infinity" }
        switch state.phaseType {
        case .work:
            return state.isRunning ? "wand.and.sparkles" : "wand.and.stars"
        case .shortBreak, .longBreak:
            return "cup.and.heat.waves"
        case .unknown:
            return "wand.and.sparkles"
        }
    }

    private func accentColor(for state: ComplicationDisplayState) -> Color {
        if state.isInFlow { return .yellow }
        return state.isRunning ? .orange : .white.opacity(0.5)
    }

    private func phaseTitle(for state: ComplicationDisplayState) -> String {
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
}

// MARK: - 小组件定义
struct SmartFocusWidget: Widget {
    var body: some WidgetConfiguration {
        RelevanceConfiguration(
            kind: ControlActionBridge.relevanceWidgetKind,
            provider: SmartFocusRelevanceProvider()
        ) { entry in
            SmartFocusWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Smart_Focus_Name", comment: ""))
        .description(NSLocalizedString("Smart_Focus_Desc", comment: ""))
        .supportedFamilies([.accessoryRectangular])
        .containerBackgroundRemovable(true)
    }
}

#endif
