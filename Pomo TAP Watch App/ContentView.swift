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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @EnvironmentObject var notificationDelegate: NotificationDelegate
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    topDateTimeView(geometry: geometry)
                        .padding(.top, 25.0)
                        .frame(height: geometry.size.height * 0.15)
                        .padding(.leading, 6.0)
                    
                    timerRingView(geometry: geometry)
                        .frame(height: geometry.size.height * 0.7)
                    
                    bottomControlView
                        .padding(.bottom, 20)
                        .frame(height: geometry.size.height * 0.15)
                        .padding(.horizontal, 1.0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .edgesIgnoringSafeArea(.all)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            Task {
                switch newPhase {
                case .active:
                    // 从后台恢复时，确保状态同步
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
            // 首次加载时同步状态
            await timerModel.appBecameActive()
        }
    }
    
    private func topDateTimeView(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dateString().prefix(5)) // 只显示月日，如 "12/25"
                .font(.system(size: geometry.size.width * 0.08))
            Text(weekdayString().prefix(3)) // 只显示周几的缩写，如 "周一"
                .font(.system(size: geometry.size.width * 0.06))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
    }
    
    private func timerRingView(geometry: GeometryProxy) -> some View {
        ZStack {
            if !isLuminanceReduced {
                timerRingBackground(geometry: geometry)
                timerRingProgress(geometry: geometry)
            }
            timerContent(geometry: geometry)
        }
        .frame(width: geometry.size.width * 0.8, height: geometry.size.width * 0.8)
    }
    
    private func timerRingBackground(geometry: GeometryProxy) -> some View {
        let ringDiameter = geometry.size.width * 0.78
        let strokeWidth = ringDiameter * 0.1
        return Circle()
            .stroke(lineWidth: strokeWidth)
            .opacity(0.2)
            .frame(width: ringDiameter, height: ringDiameter)
    }
    
    private func timerRingProgress(geometry: GeometryProxy) -> some View {
        let ringDiameter = geometry.size.width * 0.78
        let strokeWidth = ringDiameter * 0.1
        
        return ZStack {
            if timerModel.isInCooldownMode {
                cooldownRing(diameter: ringDiameter, strokeWidth: strokeWidth)
            }
            if timerModel.isInDecisionMode {
                decisionRing(diameter: ringDiameter, strokeWidth: strokeWidth)
            }
            tomatoRing(diameter: ringDiameter, strokeWidth: strokeWidth)
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }
    
    private func tomatoRing(diameter: CGFloat, strokeWidth: CGFloat) -> some View {
        let progress: CGFloat
        if timerModel.isTransitioning {
            progress = 1 - timerModel.transitionProgress
        } else {
            progress = CGFloat(timerModel.tomatoRingPosition.radians / (2 * .pi))
        }
        
        return Circle()
            .trim(from: 0.0, to: progress)
            .stroke(style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            .foregroundColor(.orange)
            .rotationEffect(Angle(degrees: 270.0))
            .animation(timerModel.isTransitioning ? .easeInOut(duration: 0.5) : .linear(duration: 1), value: progress)
    }
    
    private func decisionRing(diameter: CGFloat, strokeWidth: CGFloat) -> some View {
        let startAngle = timerModel.decisionStartAngle.radians / (2 * .pi)
        let endAngle = timerModel.decisionRingPosition.radians / (2 * .pi)
        
        return Circle()
            .trim(from: startAngle, to: endAngle)  // 顺时针
            .stroke(style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            .foregroundColor(.green)  // 改为绿色
            .rotationEffect(Angle(degrees: 270.0))
            .opacity(0.5)
    }
    
    private func cooldownRing(diameter: CGFloat, strokeWidth: CGFloat) -> some View {
        let startAngle = timerModel.cooldownStartAngle.radians / (2 * .pi)
        let currentAngle = timerModel.cooldownRingPosition.radians / (2 * .pi)
        
        return Circle()
            .trim(from: startAngle, to: currentAngle)  // 逆时针缩短
            .stroke(style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            .foregroundColor(.blue)  // 改为蓝色
            .rotationEffect(Angle(degrees: 270.0))
            .opacity(0.5)
    }
    
    private func timerContent(geometry: GeometryProxy) -> some View {
        VStack(spacing: 5) {
            if !isLuminanceReduced {
                HStack() {
                    Image(systemName: "medal.fill")
                        .foregroundColor(timerModel.hasSkippedInCurrentCycle ? .green : .orange)
                    Text("×\(timerModel.completedCycles)")
                        .font(.system(size: geometry.size.width * 0.08))
                        .foregroundColor(timerModel.hasSkippedInCurrentCycle ? .green : .orange)
                }
            }
            
            Text(timeString(time: timerModel.remainingTime))
                .font(.system(size: geometry.size.width * 0.2, weight: .bold, design: .rounded))
                .allowsHitTesting(false)
            
            if !isLuminanceReduced {
                phaseIndicators(geometry: geometry)
            }
        }
    }
    
    private func phaseIndicators(geometry: GeometryProxy) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<timerModel.phases.count, id: \.self) { index in
                PhaseIndicator(
                    status: timerModel.phaseCompletionStatus[index],
                    duration: timerModel.phases[index].duration,
                    isCycleCompleted: timerModel.currentCycleCompleted && index != 0
                )
            }
        }
    }
    
    private var bottomControlView: some View {
        HStack {
            skipButton
            Spacer()
            playPauseResetButton
        }
        .padding(.horizontal, 10)
    }
    
    private var skipButton: some View {
        Image(systemName: "forward.fill")
            .font(.system(size: 14))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(timerModel.isInCooldownMode ? Color.gray : (timerModel.isInDecisionMode ? Color.green : Color.gray.opacity(0.3)))
            )
            .clipShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !timerModel.isInDecisionMode && !timerModel.isInCooldownMode {
                            timerModel.startDecisionMode()
                        }
                    }
                    .onEnded { _ in
                        if timerModel.isInDecisionMode {
                            timerModel.cancelDecisionMode()
                        }
                    }
            )
            .disabled(timerModel.isInCooldownMode)
            .opacity(timerModel.isInCooldownMode ? 0.5 : 1.0)
            .accessibilityLabel(Text(NSLocalizedString("Skip", comment: "")))
    }
    
    private var playPauseResetButton: some View {
        Button(action: {
            Task {
                if timerModel.isInResetMode {
                    timerModel.resetCycle()
                } else {
                    await timerModel.toggleTimer()
                }
            }
        }) {
            Image(systemName: timerModel.isInResetMode ? "arrow.counterclockwise" : (timerModel.timerRunning ? "pause.fill" : "play.fill"))
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(timerModel.isInResetMode ? Color.blue : Color.orange)
                )
        }
        .handGestureShortcut(.primaryAction)
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(timerModel.isInResetMode ? Text(NSLocalizedString("Reset", comment: "")) : (timerModel.timerRunning ? Text(NSLocalizedString("Pause", comment: "")) : Text(NSLocalizedString("Start", comment: ""))))
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
        
        if isLuminanceReduced {
            if time < 60 {  // 如果剩余时间少于1分钟
                return formatter.string(from: TimeInterval(time)) ?? ""
            } else {
                let components = formatter.string(from: TimeInterval(time))?.components(separatedBy: ":")
                if let minutes = components?.first {
                    return "\(minutes):--"  // 只显示分钟数
                }
            }
        }
        return formatter.string(from: TimeInterval(time)) ?? ""
    }
}

struct PhaseIndicator: View {
    let status: PhaseStatus
    let duration: Int
    let isCycleCompleted: Bool
    
    var body: some View {
        Text("\(duration / 60)")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(color)
    }
    
    private var color: Color {
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
