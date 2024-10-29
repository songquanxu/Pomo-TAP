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
    
    init() {
        // 在检查通知权限前确保 NotificationDelegate 已正确初始化
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 等待0.5秒确保初始化完成
            checkNotificationPermission()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(timerModel)
                .environmentObject(notificationDelegate)
                .alert("需要通知权限", isPresented: $showNotificationPermissionAlert) {
                    Button("去设置", role: .none) {
                        openSettings()
                    }
                    Button("稍后再说", role: .cancel) { }
                } message: {
                    Text("为了在番茄钟完成时通知您，我们需要通知权限。请在设置中开启通知。")
                }
        }
    }
    
    // 检查通知权限
    private func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .notDetermined:
                    // 首次使用，请求权限
                    notificationDelegate.requestNotificationPermission()
                case .denied:
                    // 权限被拒绝，显示提示
                    showNotificationPermissionAlert = true
                case .authorized, .provisional, .ephemeral:
                    // 已获得权限，不需要操作
                    break
                @unknown default:
                    break
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

// MARK: - Preview Provider
struct Pomo_TAPApp_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(TimerModel())
    }
}
