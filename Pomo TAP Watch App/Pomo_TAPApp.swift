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
    // 直接使用TimerModel
    @StateObject private var timerModel: TimerModel

    // 深度链接管理器
    @StateObject private var deepLinkManager: DeepLinkManager

    // 添加状态变量来控制权限提示
    @State private var showNotificationPermissionAlert = false

    // 添加权限检查管理器
    private let permissionManager = PermissionManager()

    // 自定义初始化器
    init() {
        let timerModel = TimerModel()
        let deepLinkManager = DeepLinkManager(timerModel: timerModel)

        self._timerModel = StateObject(wrappedValue: timerModel)
        self._deepLinkManager = StateObject(wrappedValue: deepLinkManager)

        // 建立双向连接：让TimerModel的诊断管理器能访问DeepLinkManager
        timerModel.setDeepLinkManager(deepLinkManager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(timerModel)
                .environmentObject(deepLinkManager)
                .onOpenURL { url in
                    Task {
                        let result = await deepLinkManager.handleDeepLink(url)
                        await handleDeepLinkResult(result)
                    }
                }
                .alert("需要通知权限", isPresented: $showNotificationPermissionAlert) {
                    Button("去设置", role: .none) {
                        openSettings()
                    }
                    Button("稍后再说", role: .cancel) { }
                } message: {
                    Text("为了在番茄钟完成时通知您,我们需要通知权限。请在设置中开启通知。")
                }
                .task {
                    // 在视图加载后检查权限
                    await permissionManager.checkNotificationPermission { status in
                        switch status {
                        case .notDetermined:
                            // 使用TimerModel中的NotificationManager
                            timerModel.requestNotificationPermission()
                        case .denied:
                            showNotificationPermissionAlert = true
                        default:
                            break
                        }
                    }
                }
        }
    }

    // MARK: - 深度链接结果处理
    @MainActor
    private func handleDeepLinkResult(_ result: DeepLinkResult) async {
        switch result {
        case .success(let message):
            print("✅ 深度链接执行成功: \(message)")

        case .duplicate(let message):
            print("🔄 深度链接重复请求: \(message)")

        case .failed(let error):
            print("❌ 深度链接执行失败: \(error)")

        case .unsupported(let action):
            print("⚠️ 不支持的深度链接操作: \(action)")
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
