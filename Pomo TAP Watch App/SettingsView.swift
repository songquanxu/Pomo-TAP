//
//  SettingsView.swift
//  Pomo TAP Watch App
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var timerModel: TimerModel

    var body: some View {
        NavigationStack {
            List {
                // 心流模式开关
                Toggle(isOn: $timerModel.isInfiniteMode) {
                    HStack {
                        Image(systemName: "infinity")
                            .foregroundColor(.yellow)
                        Text(NSLocalizedString("Flow_Mode", comment: ""))
                    }
                }

                // 重复提醒开关
                Toggle(isOn: $timerModel.enableRepeatNotifications) {
                    HStack {
                        Image(systemName: "bell.badge")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Repeat_Notifications", comment: ""))
                            Text(NSLocalizedString("Repeat_Notifications_Desc", comment: ""))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Toggle(isOn: $timerModel.enableFinalCountdownHaptics) {
                    HStack {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .foregroundColor(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Final_Countdown_Haptics", comment: ""))
                            Text(NSLocalizedString("Final_Countdown_Haptics_Desc", comment: ""))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Settings", comment: ""))
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(TimerModel())
}
