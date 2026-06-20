 //
//  ContentView.swift
//  pomoTAP Watch App
//  pomoTAP Watch App
//  Created by 许宗桢 on 2024/9/15.
//

import SwiftUI
import WatchKit
import UserNotifications
import os

struct ContentView: View {
    @EnvironmentObject var timerModel: TimerModel
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.isLuminanceReduced) var isLuminanceReduced
    @State private var showResetDialog = false
    @State private var selectedTab = 0  // 当前选中的标签页

    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "ContentView")

    var body: some View {
        TabView(selection: $selectedTab) {
            // 主计时器页面
            timerPage()
                .tag(0)

            // 设置页面
            SettingsView()
                .tag(1)
        }
        .tabViewStyle(.page)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            Task {
                switch newPhase {
                case .active:
                    // 任意 →active 都刷新（含 .inactive→.active，如抬腕唤醒）；
                    // appBecameActive() 仅重新发布共享状态且内部已节流，幂等安全
                    await timerModel.appBecameActive()
                case .background:
                    timerModel.appEnteredBackground()
                default:
                    break
                }
            }
        }
        .onChange(of: isLuminanceReduced) { oldValue, isAOD in
            // Update timer frequency based on AOD state (watchOS 26 1Hz support)
            timerModel.timerCore.updateFrequency = isAOD ? .aod : .normal

            // AOD 恢复时，从系统时间同步计时器状态，修正显示偏差
            if oldValue == true && isAOD == false {
                timerModel.timerCore.syncTimerStateFromSystemTime()
                logger.info("🔄 AOD 恢复，已同步计时器状态")
            }

            // 调试日志：记录 AOD 状态变化
            logger.info("🌙 AOD 状态变化: \(isAOD ? "已激活" : "已关闭") | 计时器运行: \(timerModel.timerRunning) | 会话引用计数: \(timerModel.sessionManager.sessionRetainCount)")
        }
        .task {
            await timerModel.appBecameActive()
        }
    }

    private func timerPage() -> some View {
        NavigationStack {
            timerRingView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if !isLuminanceReduced {
                        topDateView()
                            .padding(.leading, 12)
                            .padding(.top, 12)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !isLuminanceReduced {
                        topFlowModeIndicator()
                            .padding(.trailing, 12)
                            .padding(.top, 12)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                // AOD 模式下隐藏底部按钮
                .toolbar {
                    if !isLuminanceReduced {
                        ToolbarItemGroup(placement: .bottomBar) {
                            // 左侧：重置按钮 - 次要操作 - 圆形样式
                            Button {
                                showResetDialog = true
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(.gray.opacity(0.3)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(NSLocalizedString("Reset", comment: "")))

                            Spacer()

                            // 右侧：开始/暂停/停止按钮 - 主要操作 - 圆形样式
                            Button {
                                Task {
                                    if timerModel.isInFlowCountUp && timerModel.timerRunning {
                                        // 心流正计时模式下运行时，点击停止
                                        await timerModel.stopFlowCountUp()
                                    } else {
                                        await timerModel.toggleTimer()
                                    }
                                }
                            } label: {
                                Image(systemName: buttonIcon)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        Circle()
                                            .fill(timerModel.isInFlowCountUp ? .yellow : .orange)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(buttonAccessibilityLabel)
                            .handGestureShortcut(.primaryAction)  // 设置为双指互点的默认按钮
                        }
                    }
                }
            .confirmationDialog(
                NSLocalizedString("Reset_Dialog_Title", comment: ""),
                isPresented: $showResetDialog,
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("Skip_Current_Phase", comment: ""), role: .destructive) {
                    Task {
                        await timerModel.skipCurrentPhase()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button(NSLocalizedString("Reset_Current_Phase", comment: ""), role: .destructive) {
                    timerModel.resetCurrentPhase()
                }
                .buttonStyle(.borderedProminent)

                Button(NSLocalizedString("Reset_Cycle", comment: ""), role: .destructive) {
                    timerModel.resetCycle()
                }
                .buttonStyle(.borderedProminent)

                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                    // 默认选项，不做任何操作
                }
                .buttonStyle(.bordered)
                .handGestureShortcut(.primaryAction)  // 设置为双指互点的默认按钮
            }
            .ignoresSafeArea()
        }
    }

    // 按钮图标
    private var buttonIcon: String {
        if timerModel.isInFlowCountUp && timerModel.timerRunning {
            return "stop.fill"  // 心流正计时模式运行时显示停止按钮
        } else {
            return timerModel.timerRunning ? "pause.fill" : "play.fill"
        }
    }

    // 按钮的无障碍标签
    private var buttonAccessibilityLabel: Text {
        if timerModel.isInFlowCountUp && timerModel.timerRunning {
            return Text(NSLocalizedString("Stop", comment: ""))
        } else {
            return timerModel.timerRunning ? Text(NSLocalizedString("Pause", comment: "")) : Text(NSLocalizedString("Start", comment: ""))
        }
    }

    private func topDateView() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dateString().prefix(5)) // 只显示月日，如 "12/25"
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(weekdayString().prefix(3)) // 只显示周几的缩写，如 "周一"
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func topFlowModeIndicator() -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            // 空文本占位，保持与日期视图相同的垂直结构
            Text(" ")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .opacity(0)
            // ∞ 符号，与星期对齐
            Text(NSLocalizedString("∞", comment: "Flow mode infinite symbol"))
                .font(.system(size: 18, weight: .light, design: .rounded))
                .foregroundStyle(timerModel.isInfiniteMode ? .yellow : .gray)
        }
    }

    private func timerRingView() -> some View {
        GeometryReader { geometry in
            let ringSize = min(geometry.size.width, geometry.size.height) * 0.85
            ZStack {
                // 在 AOD 状态下也显示背景环和进度环，但是降低亮度
                if !isLuminanceReduced {
                    timerRingBackground(ringSize: ringSize)
                }
                timerRingProgress(ringSize: ringSize)
                timerContent()
            }
            .frame(width: ringSize, height: ringSize)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
    
    private func timerRingBackground(ringSize: CGFloat) -> some View {
        let ringDiameter = ringSize * 0.9 // 背景环稍小一些
        let strokeWidth = ringDiameter * 0.08
        return Circle()
            .stroke(lineWidth: strokeWidth)
            .opacity(0.2)
            .frame(width: ringDiameter, height: ringDiameter)
    }
    
    private func timerRingProgress(ringSize: CGFloat) -> some View {
        let ringDiameter = ringSize * 0.9
        let strokeWidth = ringDiameter * 0.08

        return ZStack {
            tomatoRing(diameter: ringDiameter, strokeWidth: strokeWidth)
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }
    
    private func tomatoRing(diameter: CGFloat, strokeWidth: CGFloat) -> some View {
        let progress: CGFloat
        if timerModel.isTransitioning {
            progress = 1 - timerModel.transitionProgress
        } else if timerModel.isInFlowCountUp {
            // 心流正计时模式：显示完整圆环（100%）
            progress = 1.0
        } else if timerModel.totalTime > 0 {
            // 普通模式：直接使用剩余时间和总时间的比例来计算进度
            progress = 1 - CGFloat(timerModel.remainingTime) / CGFloat(timerModel.totalTime)
        } else {
            // 防御：totalTime 在启动瞬间可能仍为 0（Combine 绑定尚未就绪），
            // 避免 0/0 = NaN 流入 Circle().trim 几何与动画
            progress = 0
        }

        let ring = Circle()
            .trim(from: 0.0, to: progress)
            .stroke(style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            .rotationEffect(Angle(degrees: 270.0))
            .animation(timerModel.isTransitioning ? .easeInOut(duration: 0.5) : .none, value: progress)

        if timerModel.isInFlowCountUp {
            // 心流正计时模式：彩虹渐变色
            // AOD 模式下降低整体亮度
            return AnyView(ring
                .foregroundStyle(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            .red, .orange, .yellow, .green, .cyan, .blue, .purple, .red
                        ]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    )
                )
                .opacity(isLuminanceReduced ? 0.5 : 1.0)
            )
        } else {
            // 普通模式：橙色；AOD 状态下降低亮度
            let ringColor = isLuminanceReduced ? Color.orange.opacity(0.5) : Color.orange
            return AnyView(ring.foregroundStyle(ringColor))
        }
    }

    private func timerContent() -> some View {
        VStack(spacing: 5) {
            // AOD 状态下隐藏奖牌
            if !isLuminanceReduced {
                HStack() {
                    Image(systemName: "medal.fill")
                        .foregroundStyle(timerModel.hasSkippedInCurrentCycle ? .green : .orange)
                    Text(
                        String(
                            format: NSLocalizedString("×%lld", comment: "Completed cycle count format"),
                            Int64(timerModel.completedCycles)
                        )
                    )
                        .font(.system(size: 14))
                        .foregroundStyle(timerModel.hasSkippedInCurrentCycle ? .green : .orange)
                }
            }

            // 时间显示：心流正计时模式显示已过时间（金色），普通模式显示剩余时间
            // AOD 模式下使用简化格式（mm:-- 或 :ss），并降低亮度
            let displayTime = timerModel.isInFlowCountUp ? timerModel.infiniteElapsedTime : timerModel.remainingTime
            let timeText = isLuminanceReduced
                ? aodTimeString(time: displayTime, isFlowMode: timerModel.isInFlowCountUp)
                : timeString(time: displayTime)

            Text(timeText)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(timerModel.isInFlowCountUp ? .yellow : .primary)
                .opacity(isLuminanceReduced ? 0.5 : 1.0)  // AOD 模式下降低亮度
                .allowsHitTesting(false)

            // AOD 状态下隐藏阶段指示器
            if !isLuminanceReduced {
                phaseIndicators()
            }
        }
    }

    private func phaseIndicators() -> some View {
        HStack(spacing: 5) {
            ForEach(0..<timerModel.phases.count, id: \.self) { index in
                // 防御：phases 与 phaseCompletionStatus 由各自独立的 Combine 管道驱动，
                // 用 safe 下标避免极端时序下两者计数短暂不一致导致的越界崩溃
                if let status = timerModel.phaseCompletionStatus[safe: index] {
                    PhaseIndicator(
                        status: status,
                        duration: timerModel.phases[index].duration,
                        adjustedDuration: timerModel.phases[index].adjustedDuration ?? (index == timerModel.currentPhaseIndex ? timerModel.adjustedPhaseDuration : nil),
                        isCycleCompleted: timerModel.currentCycleCompleted && index != 0,
                        isInFlowCountUp: timerModel.isInFlowCountUp && index == timerModel.currentPhaseIndex,
                        infiniteElapsedTime: timerModel.infiniteElapsedTime
                    )
                }
            }
        }
    }

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMMMd", options: 0, locale: Locale.current)
        return formatter.string(from: Date())
    }

    private func weekdayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = Locale.current
        return formatter.string(from: Date())
    }

    private func timeString(time: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad

        // 所有状态下都显示完整格式 "mm:ss"
        // AOD 模式下的亮度降低通过 Ring opacity 和 privacySensitive() 实现
        return formatter.string(from: TimeInterval(time)) ?? ""
    }

    // AOD 模式专用时间格式
    private func aodTimeString(time: Int, isFlowMode: Bool) -> String {
        if isFlowMode {
            // 心流模式：始终显示 mm:--
            let minutes = time / 60
            return String(format: "%02d:--", minutes)
        } else {
            // 普通倒计时模式
            if time >= 60 {
                // 剩余时间 ≥ 1 分钟：显示 mm:--
                // 用 ≥ 而非 >：剩 60 秒时应显示 "01:--"，旧的 > 会落入 :ss 分支显示 ":00"（看似归零）
                let minutes = time / 60
                return String(format: "%02d:--", minutes)
            } else {
                // 剩余时间 < 1 分钟：显示 :ss
                let seconds = time % 60
                return String(format: ":%02d", seconds)
            }
        }
    }
}

struct PhaseIndicator: View {
    let status: PhaseStatus
    let duration: Int
    let adjustedDuration: Int?  // 调整后的时长（仅当前阶段）
    let isCycleCompleted: Bool
    let isInFlowCountUp: Bool  // 是否处于心流正计时状态
    let infiniteElapsedTime: Int  // 心流正计时下的已过时间

    var body: some View {
        Text(displayText)
            .font(.caption)
            .foregroundStyle(color)
    }

    // 计算要显示的文本
    private var displayText: String {
        // 如果是心流正计时模式且是当前阶段，始终显示 ∞ 符号
        if isInFlowCountUp && status == .current {
            return NSLocalizedString("∞", comment: "Flow mode infinite symbol")
        }

        // 如果有调整后的时长（已完成的心流模式阶段），显示调整后的值
        if let adjusted = adjustedDuration {
            let minutes = adjusted / 60
            if minutes > 99 {
                // 超过99分钟，显示小时数（向上取整）
                let hours = (minutes + 59) / 60
                return "\(hours)h"
            }
            return "\(minutes)"
        }

        // 普通模式：显示默认分钟数
        return "\(duration / 60)"
    }

    private var color: Color {
        // 心流正计时模式下当前阶段显示金色
        if isInFlowCountUp && status == .current {
            return .yellow
        }

        if isCycleCompleted {
            return .gray
        }
        switch status {
        case .notStarted:
            return .gray
        case .current:
            return .white
        case .normalCompleted:
            return .orange
        case .skipped:
            return .green
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TimerModel())
}
