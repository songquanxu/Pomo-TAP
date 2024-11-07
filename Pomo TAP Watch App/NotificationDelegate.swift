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
                // 使用新的公开方法处理通知响应
                await self.timerModel.handleNotificationResponse()
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
        // 检查应用状态
        let appState = WKExtension.shared().applicationState
        if appState == .active {
            // 前台不显示通知
            completionHandler([])
        } else {
            // 后台显示通知和播放声音
            completionHandler([.banner, .sound])
        }
    }
    
    // 优化权限请求方法
    @MainActor
    func requestNotificationPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                if granted {
                    // 权限获取成功后，设置通知类别并使用返回值
                    let category = try setupNotificationCategory()
                    UNUserNotificationCenter.current().setNotificationCategories([category])
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
    
    // 优化通知发送方法
    func sendNotification(for event: NotificationEvent, currentPhaseDuration: Int, nextPhaseDuration: Int) {
        Task {
            do {
                // 检查应用状态
                let appState = await WKExtension.shared().applicationState
                guard appState != .active else {
                    logger.debug("应用在前台，跳过通知")
                    return
                }
                
                // 检查权限状态
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
                    let currentPhaseType = NSLocalizedString(
                        getPhaseLocalizationKey(for: await timerModel.currentPhaseName),
                        comment: "阶段类型：专注/短休息/长休息"
                    )
                    
                    content.body = String(
                        format: NSLocalizedString("Notification_Body", comment: "通知内容：%d = 持续时间（分钟），%@ = 阶段类型"),
                        nextPhaseDuration,
                        currentPhaseType
                    )
                    
                    content.categoryIdentifier = "PHASE_COMPLETED"
                }
                
                // 创建通知请求
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil  // 立即触发
                )
                
                // 移除之前的通知
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                
                // 添加新通知
                try await UNUserNotificationCenter.current().add(request)
                logger.info("通知发送成功: \(content.body)")
            } catch {
                logger.error("发送通知失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 添加辅助方法来获取阶段的本地化键
    private func getPhaseLocalizationKey(for phaseName: String) -> String {
        switch phaseName {
        case "Work":
            return "Phase_Work"
        case "Short Break":
            return "Phase_Short_Break"
        case "Long Break":
            return "Phase_Long_Break"
        default:
            return "Phase_Work" // 默认返回专注阶段
        }
    }
    
    // 设置通知类别
    private func setupNotificationCategory() throws -> UNNotificationCategory {
        let nextPhaseAction = UNNotificationAction(
            identifier: "START_NEXT_PHASE",
            title: NSLocalizedString("Start_Immediately", comment: "通知动作：立即开始下一阶段"),
            options: [.foreground, .authenticationRequired]
        )
        
        let category = UNNotificationCategory(
            identifier: "PHASE_COMPLETED",
            actions: [nextPhaseAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
        return category
    }
}
