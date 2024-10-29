import SwiftUI
import UserNotifications
import os  // 添加这一行以支持 Logger

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var timerModel: TimerModel
    private let logger = Logger(subsystem: "com.yourcompany.pomoTAP", category: "NotificationDelegate")  // 添加 Logger
    @Published private(set) var notificationPermissionStatus: UNAuthorizationStatus = .notDetermined
    
    init(timerModel: TimerModel) {
        self.timerModel = timerModel
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    // 处理用户对通知的响应
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "START_NEXT_PHASE" {
            Task {
                await timerModel.moveToNextPhase(autoStart: true, skip: false)
            }
        }
        // 如果是 "IGNORE" 或者用户没有选择任何操作，我们不需要做任何事
        completionHandler()
    }
    
    // 在前台展示通知并确保声音和横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 检查应用是否处于前台
        let state = WKExtension.shared().applicationState
        if state != .active {
            // 仅在后台时展示通知
            completionHandler([.banner, .sound])
        } else {
            // 前台不展示通知
            completionHandler([])
        }
    }
    
    @MainActor
    func requestNotificationPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    self.logger.info("通知权限已获得")
                } else {
                    self.logger.warning("用户拒绝了通知权限")
                }
            } catch {
                self.logger.error("请求通知权限时出错: \(error.localizedDescription)")
            }
        }
    }
    
    @MainActor
    func checkNotificationPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.notificationPermissionStatus = settings.authorizationStatus
        self.logger.info("当前通知权限状态: \(settings.authorizationStatus.rawValue)")
    }
    
    // 添加 sendNotification 方法
    func sendNotification(for event: NotificationEvent, currentPhaseDuration: Int, nextPhaseDuration: Int) {
        Task {
            // 先检查权限状态
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else {
                self.logger.warning("通知权限未获得，无法发送通知")
                return
            }
            
            let content = UNMutableNotificationContent()
            
            switch event {
            case .phaseCompleted:
                content.title = NSLocalizedString("Great_Job", comment: "")
                content.body = String(format: NSLocalizedString("Notification_Body", comment: ""), nextPhaseDuration)
                content.sound = .default
                
                let nextPhaseAction = UNNotificationAction(identifier: "START_NEXT_PHASE", title: NSLocalizedString("Start_Immediately", comment: ""), options: .foreground)
                let ignoreAction = UNNotificationAction(identifier: "IGNORE", title: NSLocalizedString("Ignore", comment: ""), options: .destructive)
                
                let category = UNNotificationCategory(identifier: "PHASE_COMPLETED", actions: [nextPhaseAction, ignoreAction], intentIdentifiers: [], options: [])
                
                UNUserNotificationCenter.current().setNotificationCategories([category])
                content.categoryIdentifier = "PHASE_COMPLETED"
            }
            
            // 创建通知触发器（立即触发）
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                if let error = error {
                    self?.logger.error("发送通知时出错: \(error.localizedDescription)")
                } else {
                    self?.logger.info("通知发送成功: \(content.body), 时间: \(Date())")
                }
            }
        }
    }
}
