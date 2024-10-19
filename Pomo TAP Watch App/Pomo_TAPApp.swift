//
//  Pomo_TAPApp.swift
//  Pomo TAP Watch App
//
//  Created by 许宗桢 on 2024/9/22.
//

import SwiftUI
import UserNotifications
import os
import WatchKit

@main
struct Pomo_TAPApp: App {
    @StateObject private var timerModel = TimerModelContainer.shared.timerModel
    @StateObject private var notificationDelegate = TimerModelContainer.shared.notificationDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(timerModel)
                .environmentObject(notificationDelegate)
        }
    }
}

struct Pomo_TAPApp_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(TimerModel())
    }
}
