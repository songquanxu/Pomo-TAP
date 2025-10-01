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
                Toggle(isOn: $timerModel.isInfiniteMode) {
                    HStack {
                        Image(systemName: "infinity")
                            .foregroundColor(.yellow)
                        Text(NSLocalizedString("Infinite_Timer", comment: ""))
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
