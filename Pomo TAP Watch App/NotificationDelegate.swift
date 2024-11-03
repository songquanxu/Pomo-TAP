import SwiftUI
import UserNotifications
import os  // 添加这一行以支持 Logger

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var timerModel: TimerModel
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "NotificationDelegate")
    @Published private(set) var notificationPermissionStatus: UNAuthorizationStatus = .notDetermined
    
    init(timerModel: TimerModel) {
        self.timerModel = timerModel
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    // 处理用户对通知的响应
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == "START_NEXT_PHASE" {
            Task(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                // 确保当前阶段已经完成
                if await self.timerModel.remainingTime <= 0 {
                    await self.timerModel.moveToNextPhase(autoStart: true, skip: false)
                }
            }
        }
        completionHandler()
    }
    
    // 处理前台通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let state = WKExtension.shared().applicationState
        if state != .active {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])
        }
    }
    
    // 请求通知权限
    @MainActor
    func requestNotificationPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                )
                if granted {
                    logger.info("通知权限已获得")
                } else {
                    logger.warning("用户拒绝了通知权限")
                }
            } catch {
                logger.error("请求通知权限时出错: \(error.localizedDescription)")
            }
        }
    }
    
    // 检查通知权限状态
    @MainActor
    func checkNotificationPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.notificationPermissionStatus = settings.authorizationStatus
        logger.info("当前通知权限状态: \(settings.authorizationStatus.rawValue)")
    }
    
    // 发送通知
    func sendNotification(for event: NotificationEvent, currentPhaseDuration: Int, nextPhaseDuration: Int) {
        Task {
            do {
                // 检查权限
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                guard settings.authorizationStatus == .authorized else {
                    logger.warning("通知权限未获得，无法发送通知")
                    return
                }
                
                // 创建通知内容
                let content = UNMutableNotificationContent()
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = "PomoTAP_Notifications"
                
                switch event {
                case .phaseCompleted:
                    content.title = NSLocalizedString("Great_Job", comment: "")
                    
                    // 获取下一阶段的类型描述
                    let nextPhaseType = await NSLocalizedString(
                        self.timerModel.phases[(self.timerModel.currentPhaseIndex + 1) % self.timerModel.phases.count].name == "Work" 
                            ? "Phase_Work" 
                            : (self.timerModel.phases[(self.timerModel.currentPhaseIndex + 1) % self.timerModel.phases.count].name == "Short Break" 
                                ? "Phase_Short_Break" 
                                : "Phase_Long_Break"),
                        comment: ""
                    )
                    
                    content.body = String(format: NSLocalizedString("Notification_Body", comment: ""), 
                                         nextPhaseDuration,
                                         nextPhaseType)
                    
                    // 设置通知动作
                    let category = try setupNotificationCategory()
                    content.categoryIdentifier = category.identifier
                }
                
                // 创建通知请求
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil  // 立即触发
                )
                
                // 添加通知请求
                try await UNUserNotificationCenter.current().add(request)
                logger.info("通知发送成功: \(content.body)")
            } catch {
                logger.error("发送通知失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 设置通知类别
    private func setupNotificationCategory() throws -> UNNotificationCategory {
        let nextPhaseAction = UNNotificationAction(
            identifier: "START_NEXT_PHASE",
            title: NSLocalizedString("Start_Immediately", comment: ""),
            options: [.foreground, .authenticationRequired]
        )
        
        let ignoreAction = UNNotificationAction(
            identifier: "IGNORE",
            title: NSLocalizedString("Ignore", comment: ""),
            options: .destructive
        )
        
        let category = UNNotificationCategory(
            identifier: "PHASE_COMPLETED",
            actions: [nextPhaseAction, ignoreAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        // 直接设置类别，不使用 await
        UNUserNotificationCenter.current().setNotificationCategories([category])
        return category
    }
}
