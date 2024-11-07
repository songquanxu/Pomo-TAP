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
    // 使用共享容器来管理状态，确保单一数据源
    @StateObject private var timerModel = TimerModelContainer.shared.timerModel
    @StateObject private var notificationDelegate = TimerModelContainer.shared.notificationDelegate
    
    // 添加状态变量来控制权限提示
    @State private var showNotificationPermissionAlert = false
    
    // 添加权限检查管理器
    private let permissionManager = PermissionManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(timerModel)
                .environmentObject(notificationDelegate)
                .onOpenURL { url in
                    // 处理从复杂功能打开应用的事件
                    if url.scheme == "pomoTAP" {
                        // 使用正确的 API 激活应用
                        WKExtension.shared().openSystemURL(url)
                    }
                }
                .alert("需要通知权限", isPresented: $showNotificationPermissionAlert) {
                    Button("去设置", role: .none) {
                        openSettings()
                    }
                    Button("稍后再说", role: .cancel) { }
                } message: {
                    Text("为了在番茄钟完成时通知您，我们需要通知权限。请在设置中开启通知。")
                }
                .task {
                    // 在视图加载后检查权限
                    await permissionManager.checkNotificationPermission { status in
                        switch status {
                        case .notDetermined:
                            notificationDelegate.requestNotificationPermission()
                        case .denied:
                            showNotificationPermissionAlert = true
                        default:
                            break
                        }
                    }
                }
        }
    }
    
    // 打开系统设置
    private func openSettings() {
        if let settingsUrl = URL(string: "x-apple-watch://") {
            WKExtension.shared().openSystemURL(settingsUrl)
        }
    }
}

// 权限管理器
private actor PermissionManager {
    func checkNotificationPermission(completion: @escaping (UNAuthorizationStatus) -> Void) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            completion(settings.authorizationStatus)
        }
    }
}

// MARK: - Preview Provider
struct Pomo_TAPApp_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(TimerModel())
    }
}
