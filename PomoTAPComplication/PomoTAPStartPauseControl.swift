//
//  PomoTAPStartPauseControl.swift
//  PomoTAPComplication
//
//  watchOS 26 Control Center 控件：一键启停番茄钟。
//

import AppIntents
import SwiftUI
import WidgetKit

#if os(watchOS)

// MARK: - 控件动作意图
/// 启停计时器的控制中心动作。
///
/// 计时器引擎运行在主 app 进程内（`DispatchSourceTimer` + `WKExtendedRuntimeSession` + 通知），
/// 控件无法在扩展进程里直接驱动它。因此意图只做两件事：把 `pomoTAP://toggle` 写入 App Group，
/// 并通过 `openAppWhenRun` 唤起 app —— 由既有的、幂等的 `DeepLinkManager` 完成真正的启停。
/// 这与矩形复杂功能点击切换走的是同一条成熟路径。
struct StartPauseTimerControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Control_StartPause_Name"
    static let isDiscoverable: Bool = false
    static let openAppWhenRun: Bool = true

    /// 控件期望的目标状态（true = 运行）。系统在切换时写入，这里以 toggle 语义统一处理。
    @Parameter(title: "Control_StartPause_Value")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        ControlActionBridge.setPendingAction(ControlActionBridge.toggleURLString)
        return .result()
    }
}

// MARK: - 控件取值提供器
/// 从 App Group 读取当前运行状态，使控件在控制中心实时反映 运行 / 暂停。
struct TimerRunningValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let defaults = UserDefaults(suiteName: SharedTimerState.suiteName),
              let data = defaults.data(forKey: SharedTimerState.userDefaultsKey),
              let state = try? JSONDecoder().decode(SharedTimerState.self, from: data) else {
            return false
        }
        return state.timerRunning
    }
}

// MARK: - 控件定义
struct StartPauseControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: ControlActionBridge.startPauseControlKind,
            provider: TimerRunningValueProvider()
        ) { isRunning in
            ControlWidgetToggle(
                isOn: isRunning,
                action: StartPauseTimerControlIntent()
            ) {
                Label {
                    Text(isRunning
                         ? NSLocalizedString("Control_Running", comment: "运行中")
                         : NSLocalizedString("Control_Paused", comment: "已暂停"))
                } icon: {
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                }
            }
            .tint(.orange)
        }
        .displayName(LocalizedStringResource("Control_StartPause_Name"))
        .description(LocalizedStringResource("Control_StartPause_Desc"))
    }
}

#endif
