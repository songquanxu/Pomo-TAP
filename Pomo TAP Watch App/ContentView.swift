 //
//  ContentView.swift
//  pomoTAP Watch App
//  pomoTAP Watch App
//  Created by 许宗桢 on 2024/9/15.
//

import SwiftUI
import WatchKit
import UserNotifications

struct ContentView: View {
    @EnvironmentObject var timerModel: TimerModel
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.isLuminanceReduced) var isLuminanceReduced
    @StateObject private var wristStateManager = WristStateManager()
    @State private var showResetDialog = false
    @State private var selectedTab = 0  // 当前选中的标签页

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
                    if oldPhase == .background {
                        await timerModel.appBecameActive()
                    }
                case .background:
                    timerModel.appEnteredBackground()
                default:
                    break
                }
            }
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
                    if wristStateManager.isWristRaised && !isLuminanceReduced {
                        topDateView()
                            .padding(.leading, 12)
                            .padding(.top, 12)
                    }
                }
                .navigationBarHidden(true)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    // 左侧：重置按钮 - 次要操作
                    Button {
                        showResetDialog = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .glassEffect()
                    .accessibilityLabel(Text(NSLocalizedString("Reset", comment: "")))

                    Spacer()

                    // 右侧：开始/暂停/停止按钮 - 主要操作
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
                    }
                    .buttonStyle(.borderedProminent)
                    .glassEffect()
                    .tint(timerModel.isInFlowCountUp ? .yellow : .orange)
                    .accessibilityLabel(buttonAccessibilityLabel)
                    .handGestureShortcut(.primaryAction)  // 设置为双指互点的默认按钮
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
            .confirmationDialog(
                NSLocalizedString("Phase_Completed", comment: ""),
                isPresented: $timerModel.showPhaseCompletionDialog,
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("Start_Immediately", comment: "")) {
                    Task {
                        await timerModel.startNextPhaseNow()
                    }
                }
                .buttonStyle(.borderedProminent)
                .handGestureShortcut(.primaryAction)  // 设置为双指互点的默认按钮

                Button(NSLocalizedString("Start_Later", comment: ""), role: .cancel) {
                    Task {
                        await timerModel.startNextPhaseLater()
                    }
                }
                .buttonStyle(.bordered)
            }
            .edgesIgnoringSafeArea(.all)
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
                .foregroundColor(.secondary)
        }
    }

    private func timerRingView() -> some View {
        GeometryReader { geometry in
            let ringSize = min(geometry.size.width, geometry.size.height) * 0.85
            ZStack {
                // AOD 状态下也显示背景环和进度环，但是降低亮度
                if wristStateManager.isWristRaised || isLuminanceReduced {
                    timerRingBackground(ringSize: ringSize)
                    timerRingProgress(ringSize: ringSize)
                }
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
        } else {
            // 普通模式：直接使用剩余时间和总时间的比例来计算进度
            progress = 1 - CGFloat(timerModel.remainingTime) / CGFloat(timerModel.totalTime)
        }

        let ring = Circle()
            .trim(from: 0.0, to: progress)
            .stroke(style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            .rotationEffect(Angle(degrees: 270.0))
            .animation(timerModel.isTransitioning ? .easeInOut(duration: 0.5) : .none, value: progress)

        if timerModel.isInFlowCountUp {
            // 心流正计时模式：彩虹渐变色
            return AnyView(ring.foregroundStyle(
                AngularGradient(
                    gradient: Gradient(colors: [
                        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .red
                    ]),
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(360)
                )
            ))
        } else {
            // 普通模式：橙色；AOD 状态下降低亮度
            let ringColor = isLuminanceReduced ? Color.orange.opacity(0.5) : Color.orange
            return AnyView(ring.foregroundColor(ringColor))
        }
    }

    private func timerContent() -> some View {
        VStack(spacing: 5) {
            // AOD 状态下隐藏奖牌
            if wristStateManager.isWristRaised && !isLuminanceReduced {
                HStack() {
                    Image(systemName: "medal.fill")
                        .foregroundColor(timerModel.hasSkippedInCurrentCycle ? .green : .orange)
                    Text("×\(timerModel.completedCycles)")
                        .font(.system(size: 14))
                        .foregroundColor(timerModel.hasSkippedInCurrentCycle ? .green : .orange)
                }
            }

            // 时间显示：心流正计时模式显示已过时间（金色），普通模式显示剩余时间
            Text(timeString(time: timerModel.isInFlowCountUp ? timerModel.infiniteElapsedTime : timerModel.remainingTime))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(timerModel.isInFlowCountUp ? .yellow : .primary)
                .allowsHitTesting(false)
                .privacySensitive()  // 添加隐私保护

            // AOD 状态下隐藏阶段指示器
            if wristStateManager.isWristRaised && !isLuminanceReduced {
                phaseIndicators()
            }
        }
    }

    private func phaseIndicators() -> some View {
        HStack(spacing: 5) {
            ForEach(0..<timerModel.phases.count, id: \.self) { index in
                PhaseIndicator(
                    status: timerModel.phaseCompletionStatus[index],
                    duration: timerModel.phases[index].duration,
                    adjustedDuration: index == timerModel.currentPhaseIndex ? timerModel.adjustedPhaseDuration : nil,
                    isCycleCompleted: timerModel.currentCycleCompleted && index != 0,
                    isInFlowCountUp: timerModel.isInFlowCountUp,
                    infiniteElapsedTime: timerModel.infiniteElapsedTime
                )
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

        // 常亮显示（手腕放下）时的格式
        if !wristStateManager.isWristRaised {
            if time > 60 {
                // 剩余时间大于1分钟：显示 "mm:--"
                let minutes = time / 60
                return String(format: "%d:--", minutes)
            } else {
                // 剩余时间小于等于1分钟：显示 ":ss"
                let seconds = time % 60
                return String(format: ":%02d", seconds)
            }
        }

        // 手腕抬起时显示完整格式 "mm:ss"
        return formatter.string(from: TimeInterval(time)) ?? ""
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
            .foregroundColor(color)
    }

    // 计算要显示的文本
    private var displayText: String {
        // 如果是心流正计时模式且是当前阶段，显示金色无穷符号或实际时长
        if isInFlowCountUp && status == .current {
            // 如果已过时间为0（还未开始计时），显示∞
            if infiniteElapsedTime == 0 {
                return "∞"
            }
            // 如果已经开始计时，显示实际时长
            let minutes = infiniteElapsedTime / 60
            if minutes > 99 {
                // 超过99分钟，显示小时数（向上取整）
                let hours = (minutes + 59) / 60  // 向上取整
                return "\(hours)h"
            }
            return "\(minutes)"
        }

        // 普通模式：显示分钟数
        return "\(displayDuration)"
    }

    // 计算要显示的时长（分钟数）
    private var displayDuration: Int {
        // 如果有调整后的时长，优先显示调整后的值
        if let adjusted = adjustedDuration {
            return adjusted / 60
        }
        // 否则显示原始时长
        return duration / 60
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(TimerModel())
    }
}

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
