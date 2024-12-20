//
//  PomoTAPComplication.swift
//  PomoTAPComplication
//
//  Created by 许宗桢 on 2024/11/7.
//

import WidgetKit
import SwiftUI
import os  // 添加 os 导入

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
            remainingTime: 1500
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
                remainingTime: 1500
            ))
        }
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> ()) {
        do {
            let currentEntry = try loadCurrentState()
            
            // 如果计时器没有运行，只返回当前状态
            if !currentEntry.isRunning {
                let timeline = Timeline(entries: [currentEntry], policy: .never)
                completion(timeline)
                return
            }
            
            // 计时器运行时的逻辑
            var entries: [ComplicationEntry] = [currentEntry]
            let calendar = Calendar.current
            let now = Date()
            let remainingSeconds = currentEntry.remainingTime
            
            // 每分钟生成一个时间点
            for second in stride(from: 60, to: remainingSeconds, by: 60) {
                if let futureDate = calendar.date(byAdding: .second, value: second, to: now) {
                    let futureRemainingTime = remainingSeconds - second
                    let futureProgress = 1.0 - Double(futureRemainingTime) / Double(currentEntry.totalMinutes * 60)
                    
                    let entry = ComplicationEntry(
                        date: futureDate,
                        phase: currentEntry.phase,
                        isRunning: true,
                        progress: futureProgress,
                        totalMinutes: currentEntry.totalMinutes,
                        remainingTime: futureRemainingTime
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
                    remainingTime: 0
                )
                entries.append(finalEntry)
            }
            
            let timeline = Timeline(entries: entries, policy: .atEnd)
            completion(timeline)
            
        } catch {
            // 发生错误时，返回一个基本的时间线
            let entry = ComplicationEntry(
                date: Date(),
                phase: "work",
                isRunning: false,
                progress: 0.0,
                totalMinutes: 25,
                remainingTime: 1500
            )
            let timeline = Timeline(entries: [entry], policy: .never)
            completion(timeline)
        }
    }
    
    private func loadCurrentState() throws -> ComplicationEntry {
        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) else {
            logger.error("无法访问共享 UserDefaults: \(SharedTimerState.suiteName)")
            throw ComplicationError.userDefaultsNotAccessible
        }
        
        guard let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey) else {
            logger.error("未找到共享状态数据，key: \(SharedTimerState.userDefaultsKey)")
            throw ComplicationError.noDataAvailable
        }
        
        do {
            let state = try JSONDecoder().decode(SharedTimerState.self, from: data)
            logger.debug("成功加载状态: phase=\(state.currentPhaseName), running=\(state.timerRunning)")
            
            return ComplicationEntry(
                date: state.lastUpdateTime,
                phase: state.standardizedPhaseName,
                isRunning: state.timerRunning,
                progress: state.progress,
                totalMinutes: state.totalTime / 60,
                remainingTime: state.remainingTime
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

// 复杂功能视图
struct ComplicationView: View {
    var entry: ComplicationEntry
    
    var body: some View {
        ZStack {
            // 背景圆环（灰色）
            Circle()
                .stroke(lineWidth: 4)
                .foregroundStyle(.gray.opacity(0.3))
            
            // 进度圆环
            Circle()
                .trim(from: 0, to: entry.progress)
                .stroke(style: StrokeStyle(
                    lineWidth: 4,
                    lineCap: .round
                ))
                .foregroundStyle(entry.isRunning ? .orange : .gray)
                .rotationEffect(.degrees(-90))  // 从顶部开始
            
            // 中心图标
            Image(systemName: phaseSymbol)
                .font(.system(size: 14, weight: .medium))
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
    // 工作阶段 - 30% 进度
    ComplicationEntry(
        date: .now,
        phase: "work",
        isRunning: true,
        progress: 0.3,
        totalMinutes: 25,
        remainingTime: 1050
    )
    // 工作阶段 - 70% 进度
    ComplicationEntry(
        date: .now,
        phase: "work",
        isRunning: true,
        progress: 0.7,
        totalMinutes: 25,
        remainingTime: 450
    )
    // 短休息阶段 - 暂停状态
    ComplicationEntry(
        date: .now,
        phase: "shortBreak",
        isRunning: false,
        progress: 0.0,
        totalMinutes: 5,
        remainingTime: 300
    )
}
