//
//  PomoTAPComplication.swift
//  PomoTAPComplication
//
//  Created by 许宗桢 on 2024/11/7.
//

import WidgetKit
import SwiftUI

// 定义数据模型
struct ComplicationEntry: TimelineEntry {
    let date: Date
    let phase: String
    let isRunning: Bool
    let progress: Double
}

// 提供数据的 Provider
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), phase: "work", isRunning: false, progress: 0.0)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> ()) {
        let entry = loadCurrentState()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> ()) {
        let currentEntry = loadCurrentState()
        var entries: [ComplicationEntry] = [currentEntry]
        
        // 如果计时器正在运行，预生成未来的时间点
        if currentEntry.isRunning {
            let currentDate = Date()
            let calendar = Calendar.current
            
            // 计算下一个整分钟
            var nextDate = calendar.date(
                bySetting: .second,
                value: 0,
                of: calendar.date(byAdding: .minute, value: 1, to: currentDate) ?? currentDate
            ) ?? currentDate
            
            // 生成未来5分钟的时间点
            for _ in 0..<5 {
                if let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName),
                   let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey),
                   let state = try? JSONDecoder().decode(SharedTimerState.self, from: data) {
                    
                    // 计算该时间点的剩余时间
                    let elapsedTime = nextDate.timeIntervalSince(currentDate)
                    let remainingTime = max(0, Double(state.remainingTime) - elapsedTime)
                    let progress = 1.0 - (remainingTime / Double(state.totalTime))
                    
                    let entry = ComplicationEntry(
                        date: nextDate,
                        phase: state.currentPhaseName.lowercased(),
                        isRunning: true,
                        progress: progress
                    )
                    entries.append(entry)
                }
                
                nextDate = calendar.date(byAdding: .minute, value: 1, to: nextDate) ?? nextDate
            }
        }
        
        // 设置更新时间
        let nextUpdateDate: Date
        if currentEntry.isRunning {
            // 如果计时器运行中，在下一个整分钟更新
            let calendar = Calendar.current
            nextUpdateDate = calendar.date(
                bySetting: .second,
                value: 0,
                of: calendar.date(byAdding: .minute, value: 1, to: Date()) ?? Date()
            ) ?? Date()
        } else {
            // 如果计时器暂停，5分钟后再更新
            nextUpdateDate = Date().addingTimeInterval(300)
        }
        
        let timeline = Timeline(entries: entries, policy: .after(nextUpdateDate))
        completion(timeline)
    }
    
    private func loadCurrentState() -> ComplicationEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName),
              let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey),
              let state = try? JSONDecoder().decode(SharedTimerState.self, from: data)
        else {
            return ComplicationEntry(date: Date(), phase: "work", isRunning: false, progress: 0.0)
        }
        
        // 计算进度
        let progress = 1.0 - (Double(state.remainingTime) / Double(state.totalTime))
        
        // 获取当前阶段的正确名称
        let phaseName = state.phases[state.currentPhaseIndex].name.lowercased()
        
        return ComplicationEntry(
            date: state.lastUpdateTime,
            phase: phaseName,
            isRunning: state.timerRunning,
            progress: progress
        )
    }
}

// 复杂功能视图
struct ComplicationView: View {
    var entry: ComplicationEntry
    
    var body: some View {
        Gauge(value: entry.progress) {
            Image(systemName: phaseSymbol)
                .foregroundColor(entry.isRunning ? .orange : .gray)
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "pomoTAP://open")!)
    }
    
    private var phaseSymbol: String {
        switch entry.phase {
        case "work":
            // brain.head.profile 表示专注
            return entry.isRunning ? "brain.head.profile.fill" : "brain.head.profile"
        case "shortBreak":
            // cup.and.saucer 表示短休息
            return entry.isRunning ? "cup.and.saucer.fill" : "cup.and.saucer"
        case "longBreak":
            // figure.walk 表示长休息
            return entry.isRunning ? "figure.walk.motion" : "figure.walk"
        default:
            return entry.isRunning ? "brain.head.profile.fill" : "brain.head.profile"
        }
    }
}

@main
struct PomoTAPComplication: Widget {
    private let kind: String = "PomoTAPComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ComplicationView(entry: entry)
        }
        .configurationDisplayName("Pomo TAP")
        .description("显示当前番茄钟状态")
        .supportedFamilies([.accessoryCircular])
    }
}

#Preview(as: .accessoryCircular) {
    PomoTAPComplication()
} timeline: {
    ComplicationEntry(date: .now, phase: "work", isRunning: true, progress: 0.0)
}
