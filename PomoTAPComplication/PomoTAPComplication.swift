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
        let entry = loadCurrentState()
        
        // 根据计时器状态决定更新策略
        let updateDate: Date
        if entry.isRunning {
            // 如果计时器在运行，每分钟更新一次
            updateDate = Date().addingTimeInterval(60)
        } else {
            // 如果计时器暂停，延迟更长时间再更新
            updateDate = Date().addingTimeInterval(300) // 5分钟
        }
        
        let timeline = Timeline(entries: [entry], policy: .after(updateDate))
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
        
        return ComplicationEntry(
            date: state.lastUpdateTime,
            phase: state.currentPhaseName.lowercased(),
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
