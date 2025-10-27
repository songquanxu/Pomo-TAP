//
//  PomoTAPStatsWidget.swift
//  PomoTAPComplication
//
//  Created for Pomo TAP watchOS app
//

import WidgetKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "StatsWidget")

// MARK: - Stats Entry
struct StatsEntry: TimelineEntry {
    let date: Date
    let completedCycles: Int
    let hasSkipped: Bool

    static var placeholder: StatsEntry {
        StatsEntry(date: Date(), completedCycles: 0, hasSkipped: false)
    }
}

// MARK: - Stats Provider
struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> ()) {
        do {
            let entry = try loadStatsState()
            completion(entry)
        } catch {
            logger.error("获取Stats快照失败: \(error.localizedDescription)")
            completion(.placeholder)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> ()) {
        do {
            let currentEntry = try loadStatsState()

            // Static timeline - updates only when app triggers reload
            let timeline = Timeline(entries: [currentEntry], policy: .never)
            completion(timeline)
        } catch {
            logger.error("获取Stats时间线失败: \(error.localizedDescription)")
            let timeline = Timeline(entries: [StatsEntry.placeholder], policy: .never)
            completion(timeline)
        }
    }

    private func loadStatsState() throws -> StatsEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            throw ComplicationError.userDefaultsNotAccessible
        }

        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            throw ComplicationError.noDataAvailable
        }

        let state = try JSONDecoder().decode(SharedTimerState.self, from: data)
        logger.info("✅ Stats Widget成功加载状态: cycles=\(state.completedCycles)")

        return StatsEntry(
            date: state.lastUpdateTime,
            completedCycles: state.completedCycles,
            hasSkipped: state.hasSkippedInCurrentCycle
        )
    }
}

// MARK: - Stats Views

// Rectangular View
// Inline View
struct StatsInlineView: View {
    var entry: StatsEntry

    var body: some View {
        // HIG standard: 15pt regular rounded
        Text("🍅 \(entry.completedCycles) · \(NSLocalizedString("Completed_Cycles", comment: ""))")
            .font(WidgetTypography.Inline.text)
            .containerBackground(.clear, for: .widget)
            .widgetURL(URL(string: "pomoTAP://open")!)
    }
}

// MARK: - Widget Main View
struct StatsWidgetView: View {
    var entry: StatsEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        StatsInlineView(entry: entry)
    }
}

// MARK: - Widget Definition
struct StatsWidget: Widget {
    private let kind: String = "StatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatsProvider()) { entry in
            StatsWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Completed_Cycles", comment: ""))
        .description(NSLocalizedString("Widget_Stats_Desc", comment: ""))
        .supportedFamilies([.accessoryInline])
        .containerBackgroundRemovable(true)
    }
}
