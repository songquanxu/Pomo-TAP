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
        
        if currentEntry.isRunning {
            // 如果计时器在运行，生成更精确的时间线
            let calendar = Calendar.current
            let now = Date()
            
            // 计算剩余的分钟数
            let minutesRemaining = Int((1.0 - currentEntry.progress) * 25)  // 假设25分钟
            
            // 为每一分钟生成一个条目
            for minute in 1...minutesRemaining {
                if let futureDate = calendar.date(byAdding: .minute, value: minute, to: now) {
                    let futureProgress = currentEntry.progress + (Double(minute) / 25.0)
                    let entry = ComplicationEntry(
                        date: futureDate,
                        phase: currentEntry.phase,
                        isRunning: true,
                        progress: min(futureProgress, 1.0)
                    )
                    entries.append(entry)
                }
            }
            
            // 使用 atEnd 策略，让系统在最后一个条目后请求新的时间线
            completion(Timeline(entries: entries, policy: .atEnd))
        } else {
            // 如果计时器暂停，5分钟后更新
            completion(Timeline(entries: [currentEntry], policy: .after(Date().addingTimeInterval(300))))
        }
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
        ZStack {
            // 进度圆环
            Gauge(value: entry.progress) {
                // 空视图作为标签
            } currentValueLabel: {
                // 空视图作为当前值标签
            }
            .gaugeStyle(.accessoryCircular)
            
            // 中心图标
            Image(systemName: phaseSymbol)
                .font(.system(size: 15))
                .foregroundStyle(entry.isRunning ? .orange : .gray)
        }
        .widgetAccentable()
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
        .containerBackgroundRemovable(true)
    }
}

#Preview(as: .accessoryCircular) {
    PomoTAPComplication()
} timeline: {
    ComplicationEntry(date: .now, phase: "work", isRunning: true, progress: 0.3)
    ComplicationEntry(date: .now, phase: "work", isRunning: true, progress: 0.7)
}
