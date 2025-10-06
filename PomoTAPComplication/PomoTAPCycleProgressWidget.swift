//
//  PomoTAPCycleProgressWidget.swift
//  PomoTAPComplication
//
//  Created for Pomo TAP watchOS app
//

import WidgetKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "CycleProgressWidget")

// MARK: - Cycle Progress Entry
struct CycleProgressEntry: TimelineEntry {
    let date: Date
    let phaseStatuses: [PhaseCompletionStatus]
    let currentPhaseIndex: Int

    // Fallback for when no data available
    static var placeholder: CycleProgressEntry {
        CycleProgressEntry(
            date: Date(),
            phaseStatuses: [.current, .notStarted, .notStarted, .notStarted],
            currentPhaseIndex: 0
        )
    }
}

// MARK: - Cycle Progress Provider
struct CycleProgressProvider: TimelineProvider {
    func placeholder(in context: Context) -> CycleProgressEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CycleProgressEntry) -> ()) {
        do {
            let entry = try loadCycleState()
            completion(entry)
        } catch {
            logger.error("获取Cycle快照失败: \(error.localizedDescription)")
            completion(.placeholder)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CycleProgressEntry>) -> ()) {
        do {
            let currentEntry = try loadCycleState()

            // Static timeline - updates only when app triggers reload
            let timeline = Timeline(entries: [currentEntry], policy: .never)
            completion(timeline)
        } catch {
            logger.error("获取Cycle时间线失败: \(error.localizedDescription)")
            let timeline = Timeline(entries: [CycleProgressEntry.placeholder], policy: .never)
            completion(timeline)
        }
    }

    private func loadCycleState() throws -> CycleProgressEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            throw ComplicationError.userDefaultsNotAccessible
        }

        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            throw ComplicationError.noDataAvailable
        }

        let state = try JSONDecoder().decode(SharedTimerState.self, from: data)
        logger.info("✅ Cycle Widget成功加载状态: phases=\(state.phaseCompletionStatus.count)")

        return CycleProgressEntry(
            date: state.lastUpdateTime,
            phaseStatuses: state.phaseCompletionStatus,
            currentPhaseIndex: state.currentPhaseIndex
        )
    }
}

// MARK: - Cycle Progress Views

// Rectangular View
struct CycleProgressRectangularView: View {
    var entry: CycleProgressEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Title - HIG standard: 13pt semibold
            HStack(spacing: 4) {
                Image(systemName: "repeat.circle.fill")
                    .font(WidgetTypography.Rectangular.title)
                Text(NSLocalizedString("Cycle_Progress", comment: ""))
                    .font(WidgetTypography.Rectangular.title)
                Spacer()
            }
            .foregroundStyle(.orange)

            // Phase indicators in a row
            HStack(spacing: 6) {
                ForEach(0..<min(4, entry.phaseStatuses.count), id: \.self) { index in
                    PhaseProgressIndicator(
                        status: entry.phaseStatuses[index],
                        isCurrent: index == entry.currentPhaseIndex
                    )
                }
            }
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

// Phase Progress Indicator
struct PhaseProgressIndicator: View {
    let status: PhaseCompletionStatus
    let isCurrent: Bool

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 12, height: 12)
            .overlay(
                Circle()
                    .strokeBorder(isCurrent ? .white : .clear, lineWidth: 2)
            )
    }

    private var statusColor: Color {
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
}

// MARK: - Widget Main View
struct CycleProgressWidgetView: View {
    var entry: CycleProgressEntry

    var body: some View {
        CycleProgressRectangularView(entry: entry)
    }
}

// MARK: - Widget Definition
struct CycleProgressWidget: Widget {
    private let kind: String = "CycleProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CycleProgressProvider()) { entry in
            CycleProgressWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Cycle_Progress", comment: ""))
        .description(NSLocalizedString("Widget_Cycle_Progress_Desc", comment: ""))
        .supportedFamilies([.accessoryRectangular])
        .containerBackgroundRemovable(true)
    }
}
