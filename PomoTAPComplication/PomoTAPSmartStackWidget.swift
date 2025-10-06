//
//  PomoTAPSmartStackWidget.swift
//  PomoTAPComplication
//
//  Created for Pomo TAP watchOS app
//  Interactive Smart Stack widget optimized for watchOS
//

import WidgetKit
import SwiftUI
import AppIntents
import os

private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "SmartStackWidget")

// MARK: - Smart Stack Entry
struct SmartStackEntry: TimelineEntry {
    let date: Date
    let phase: String
    let isRunning: Bool
    let progress: Double
    let remainingTime: Int
    let phaseStatuses: [PhaseCompletionStatus]
    let currentPhaseIndex: Int
    let relevance: TimelineEntryRelevance?

    static var placeholder: SmartStackEntry {
        SmartStackEntry(
            date: Date(),
            phase: "work",
            isRunning: false,
            progress: 0.0,
            remainingTime: 1500,
            phaseStatuses: [.current, .notStarted, .notStarted, .notStarted],
            currentPhaseIndex: 0,
            relevance: TimelineEntryRelevance(score: 50)
        )
    }
}

// MARK: - Smart Stack Provider
struct SmartStackProvider: TimelineProvider {
    func placeholder(in context: Context) -> SmartStackEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SmartStackEntry) -> ()) {
        do {
            let entry = try loadSmartStackState()
            completion(entry)
        } catch {
            logger.error("获取Smart Stack快照失败: \(error.localizedDescription)")
            completion(.placeholder)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SmartStackEntry>) -> ()) {
        do {
            let currentEntry = try loadSmartStackState()

            // If timer not running, return static timeline
            if !currentEntry.isRunning {
                let timeline = Timeline(entries: [currentEntry], policy: .never)
                completion(timeline)
                return
            }

            // Timer running: 1-minute interval updates for Smart Stack
            var entries: [SmartStackEntry] = [currentEntry]
            let calendar = Calendar.current
            let now = Date()
            let remainingSeconds = currentEntry.remainingTime

            // Generate entries every 1 minute
            for minuteOffset in 1..<(remainingSeconds / 60) {
                guard let futureDate = calendar.date(byAdding: .minute, value: minuteOffset, to: now) else {
                    continue
                }

                let futureRemainingTime = remainingSeconds - (minuteOffset * 60)
                let futureProgress = 1.0 - Double(futureRemainingTime) / Double(currentEntry.remainingTime + (Int(currentEntry.progress * Double(currentEntry.remainingTime)) / (1 - Int(currentEntry.progress))))

                let entry = SmartStackEntry(
                    date: futureDate,
                    phase: currentEntry.phase,
                    isRunning: true,
                    progress: futureProgress,
                    remainingTime: futureRemainingTime,
                    phaseStatuses: currentEntry.phaseStatuses,
                    currentPhaseIndex: currentEntry.currentPhaseIndex,
                    relevance: calculateRelevance(isRunning: true, remainingTime: futureRemainingTime, date: futureDate)
                )
                entries.append(entry)
            }

            // Add completion entry
            if let endDate = calendar.date(byAdding: .second, value: remainingSeconds, to: now) {
                let finalEntry = SmartStackEntry(
                    date: endDate,
                    phase: currentEntry.phase,
                    isRunning: false,
                    progress: 1.0,
                    remainingTime: 0,
                    phaseStatuses: currentEntry.phaseStatuses,
                    currentPhaseIndex: currentEntry.currentPhaseIndex,
                    relevance: TimelineEntryRelevance(score: 80)
                )
                entries.append(finalEntry)
            }

            let timeline = Timeline(entries: entries, policy: .atEnd)
            completion(timeline)

        } catch {
            logger.error("获取Smart Stack时间线失败: \(error.localizedDescription)")
            let timeline = Timeline(entries: [SmartStackEntry.placeholder], policy: .never)
            completion(timeline)
        }
    }

    private func calculateRelevance(isRunning: Bool, remainingTime: Int, date: Date) -> TimelineEntryRelevance {
        var score: Float = 0

        // Base score: Timer state (0-60 points)
        if isRunning {
            score += 60  // Higher base score for Smart Stack priority (up from 50)

            // Last 5 minutes urgency boost (+30 points)
            if remainingTime <= 300 {
                score += 30
            }
        } else {
            score += 20  // Stopped but still relevant
        }

        // Work hours context (+5 points, reduced from +10)
        // Focus mode detection is more important than generic time context
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)

        // weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
        // Workdays (Mon-Fri) and work hours (9:00-18:00)
        if (2...6).contains(weekday) && (9...18).contains(hour) {
            score += 5  // Reduced weight, Focus mode more relevant
        }

        // NEW: Break approaching bonus (+10 points)
        // When work phase is ending soon, user wants to know when break arrives
        // This boosts Smart Stack visibility in the last 10 minutes of work phase
        if isWorkPhaseActive() && remainingTime <= 600 && remainingTime > 300 {
            score += 10
        }

        // Score range: 0-100 (capped)
        return TimelineEntryRelevance(score: min(score, 100))
    }

    // Helper: Detect if current phase is work phase
    // watchOS 26: Use shared state to determine phase type
    private func isWorkPhaseActive() -> Bool {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName),
              let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey),
              let state = try? JSONDecoder().decode(SharedTimerState.self, from: data) else {
            return false
        }

        return state.isCurrentPhaseWorkPhase
    }

    private func loadSmartStackState() throws -> SmartStackEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            throw ComplicationError.userDefaultsNotAccessible
        }

        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            throw ComplicationError.noDataAvailable
        }

        let state = try JSONDecoder().decode(SharedTimerState.self, from: data)
        logger.info("✅ Smart Stack Widget成功加载状态: phase=\(state.currentPhaseName), running=\(state.timerRunning)")

        let relevance = calculateRelevance(
            isRunning: state.timerRunning,
            remainingTime: state.remainingTime,
            date: state.lastUpdateTime
        )

        return SmartStackEntry(
            date: state.lastUpdateTime,
            phase: state.standardizedPhaseName,
            isRunning: state.timerRunning,
            progress: state.progress,
            remainingTime: state.remainingTime,
            phaseStatuses: state.phaseCompletionStatus,
            currentPhaseIndex: state.currentPhaseIndex,
            relevance: relevance
        )
    }
}

// MARK: - Smart Stack Widget View
struct SmartStackWidgetView: View {
    var entry: SmartStackEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Top row: Phase name + Control button - HIG standard: 13pt semibold
            HStack(spacing: 4) {
                Image(systemName: phaseSymbol)
                    .font(WidgetTypography.SmartStack.title)
                    .foregroundStyle(phaseColor)

                Text(phaseName)
                    .font(WidgetTypography.SmartStack.title)
                    .foregroundStyle(phaseColor)

                Spacer()

                // Interactive button using AppIntent
                Button(intent: ToggleTimerIntent()) {
                    Image(systemName: entry.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(entry.isRunning ? .orange : .green)
                        )
                }
                .buttonStyle(.plain)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    Capsule()
                        .fill(.gray.opacity(0.3))
                        .frame(height: 3)

                    // Progress
                    Capsule()
                        .fill(entry.isRunning ? .orange : .gray)
                        .frame(width: geometry.size.width * entry.progress, height: 3)
                }
            }
            .frame(height: 3)

            // Bottom row: Phase dots + Time - HIG standard: 15pt medium rounded
            HStack(spacing: 4) {
                // Phase status dots
                HStack(spacing: 3) {
                    ForEach(0..<min(4, entry.phaseStatuses.count), id: \.self) { index in
                        Circle()
                            .fill(dotColor(for: entry.phaseStatuses[index], isCurrent: index == entry.currentPhaseIndex))
                            .frame(width: 6, height: 6)
                    }
                }

                Spacer()

                // Remaining time
                Text(timeString)
                    .font(WidgetTypography.SmartStack.time)
                    .foregroundStyle(entry.isRunning ? .primary : .secondary)
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    // MARK: - Computed Properties

    private var phaseSymbol: String {
        switch entry.phase {
        case "work":
            return entry.isRunning ? "brain.head.profile.fill" : "brain.head.profile"
        case "shortBreak":
            return entry.isRunning ? "cup.and.saucer.fill" : "cup.and.saucer"
        case "longBreak":
            return entry.isRunning ? "figure.walk.motion" : "figure.walk"
        default:
            return "brain.head.profile"
        }
    }

    private var phaseName: String {
        switch entry.phase {
        case "work": return NSLocalizedString("Phase_Work", comment: "")
        case "shortBreak": return NSLocalizedString("Phase_Short_Break", comment: "")
        case "longBreak": return NSLocalizedString("Phase_Long_Break", comment: "")
        default: return NSLocalizedString("Phase_Work", comment: "")
        }
    }

    private var phaseColor: Color {
        entry.isRunning ? .orange : .gray
    }

    private var timeString: String {
        let minutes = entry.remainingTime / 60
        let seconds = entry.remainingTime % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func dotColor(for status: PhaseCompletionStatus, isCurrent: Bool) -> Color {
        if isCurrent {
            return .blue
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
}

// MARK: - Widget Definition
struct PomoTAPSmartStackWidget: Widget {
    private let kind: String = "PomoTAPSmartStackWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SmartStackProvider()) { entry in
            SmartStackWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("Smart_Stack_Widget", comment: ""))
        .description(NSLocalizedString("Widget_Smart_Stack_Desc", comment: ""))
        .supportedFamilies([.accessoryRectangular])
        .containerBackgroundRemovable(true)
    }
}

// MARK: - Preview
#Preview(as: .accessoryRectangular) {
    PomoTAPSmartStackWidget()
} timeline: {
    // Running state
    SmartStackEntry(
        date: .now,
        phase: "work",
        isRunning: true,
        progress: 0.65,
        remainingTime: 525,
        phaseStatuses: [.current, .notStarted, .notStarted, .notStarted],
        currentPhaseIndex: 0,
        relevance: TimelineEntryRelevance(score: 70)
    )

    // Paused state
    SmartStackEntry(
        date: .now,
        phase: "shortBreak",
        isRunning: false,
        progress: 0.0,
        remainingTime: 300,
        phaseStatuses: [.normalCompleted, .current, .notStarted, .notStarted],
        currentPhaseIndex: 1,
        relevance: TimelineEntryRelevance(score: 20)
    )
}
