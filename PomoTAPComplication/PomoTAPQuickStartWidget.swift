//
//  PomoTAPQuickStartWidget.swift
//  PomoTAPComplication
//
//  Created for Pomo TAP watchOS app
//

import WidgetKit
import SwiftUI

// MARK: - Quick Start Entry
struct QuickStartEntry: TimelineEntry {
    let date: Date
    let action: QuickStartAction
}

enum QuickStartAction {
    case startWork
    case startBreak

    var title: String {
        switch self {
        case .startWork:
            return NSLocalizedString("Quick_Start_Work", comment: "")
        case .startBreak:
            return NSLocalizedString("Quick_Start_Break", comment: "")
        }
    }

    var symbol: String {
        switch self {
        case .startWork:
            return "brain.head.profile.fill"
        case .startBreak:
            return "cup.and.saucer.fill"
        }
    }

    var emoji: String {
        switch self {
        case .startWork:
            return "🍅"
        case .startBreak:
            return "☕️"
        }
    }

    var urlScheme: String {
        switch self {
        case .startWork:
            return "pomoTAP://startWork"
        case .startBreak:
            return "pomoTAP://startBreak"
        }
    }
}

// MARK: - Quick Start Provider
struct QuickStartProvider: TimelineProvider {
    let action: QuickStartAction

    init(action: QuickStartAction) {
        self.action = action
    }

    func placeholder(in context: Context) -> QuickStartEntry {
        QuickStartEntry(date: Date(), action: action)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickStartEntry) -> ()) {
        let entry = QuickStartEntry(date: Date(), action: action)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickStartEntry>) -> ()) {
        // Static widget - no timeline updates needed
        let entry = QuickStartEntry(date: Date(), action: action)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Quick Start Views

// Circular View
struct QuickStartCircularView: View {
    var entry: QuickStartEntry

    var body: some View {
        ZStack {
            Circle()
                .fill(.orange.gradient)

            // HIG standard: 20pt medium for circular icons
            Image(systemName: entry.action.symbol)
                .font(WidgetTypography.Circular.icon)
                .foregroundStyle(.white)
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: entry.action.urlScheme)!)
    }
}

// Corner View
struct QuickStartCornerView: View {
    var entry: QuickStartEntry

    var body: some View {
        ZStack {
            Circle()
                .fill(.orange.gradient)

            // HIG standard: 12pt medium for corner icons
            Image(systemName: entry.action.symbol)
                .font(WidgetTypography.Corner.icon)
                .foregroundStyle(.white)
        }
        .widgetLabel {
            // HIG standard: 13pt regular rounded for corner labels
            Text(entry.action.title)
                .font(WidgetTypography.Corner.label)
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: entry.action.urlScheme)!)
    }
}

// MARK: - Widget Main View
struct QuickStartWidgetView: View {
    var entry: QuickStartEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            QuickStartCircularView(entry: entry)
        case .accessoryCorner:
            QuickStartCornerView(entry: entry)
        default:
            QuickStartCircularView(entry: entry)
        }
    }
}

// MARK: - Widget Definitions

struct QuickStartWorkWidget: Widget {
    private let kind: String = "QuickStartWorkWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickStartProvider(action: .startWork)) { entry in
            QuickStartWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Quick_Start_Work", comment: ""))
        .description(NSLocalizedString("Widget_Quick_Start_Desc", comment: ""))
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
        .containerBackgroundRemovable(true)
    }
}

struct QuickStartBreakWidget: Widget {
    private let kind: String = "QuickStartBreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickStartProvider(action: .startBreak)) { entry in
            QuickStartWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Quick_Start_Break", comment: ""))
        .description(NSLocalizedString("Widget_Quick_Start_Desc", comment: ""))
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
        .containerBackgroundRemovable(true)
    }
}
