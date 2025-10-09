import SwiftUI
import UserNotifications
import os

// MARK: - 通知管理
@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    // MARK: - Published Properties
    @Published var notificationPermissionStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "NotificationManager")
    weak var timerModel: TimerModel?
    private let repeatManager = NotificationRepeatManager()  // 重复通知管理器

    // MARK: - Initialization
    init(timerModel: TimerModel? = nil) {
        self.timerModel = timerModel
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Public Methods
    func requestNotificationPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                if granted {
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

    func checkNotificationPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.notificationPermissionStatus = settings.authorizationStatus
        logger.info("当前通知权限状态: \(settings.authorizationStatus.rawValue)")
    }

    func sendNotification(for event: NotificationEvent, currentPhaseDuration: Int, nextPhaseDuration: Int) {
        Task {
            do {
                // 检查权限状态
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                guard settings.authorizationStatus == .authorized else {
                    logger.warning("通知权限未获得，无法发送通知")
                    return
                }

                // 验证参数
                guard currentPhaseDuration > 0, nextPhaseDuration > 0 else {
                    logger.error("无效的阶段持续时间: 当前=\(currentPhaseDuration), 下一个=\(nextPhaseDuration)")
                    return
                }

                // 创建通知内容
                let content = UNMutableNotificationContent()
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = "PomoTAP_Notifications"
                content.categoryIdentifier = "PHASE_COMPLETED"

                switch event {
                case .phaseCompleted:
                    content.title = NSLocalizedString("Great_Job", comment: "")

                    // 获取下一个阶段的名称
                    let nextPhaseIndex = ((timerModel?.currentPhaseIndex ?? 0) + 1) % (timerModel?.phases.count ?? 4)
                    let nextPhaseName = timerModel?.phases[nextPhaseIndex].name ?? "Work"
                    let nextPhaseType = NSLocalizedString(
                        getPhaseLocalizationKey(for: nextPhaseName),
                        comment: "阶段类型：专注/短休息/长休息"
                    )

                    content.body = String(
                        format: NSLocalizedString("Notification_Body", comment: "通知内容：%d = 持续时间（分钟），%@ = 阶段类型"),
                        nextPhaseDuration,
                        nextPhaseType
                    )
                }

                // 创建触发器 - 使用剩余时间（秒）
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: TimeInterval(currentPhaseDuration),  // ✅ 修正：直接使用秒数
                    repeats: false
                )

                // 创建通知请求 - 使用更具描述性的标识符
                let requestIdentifier = "PomoTAP_\(String(describing: event))_\(Date().timeIntervalSince1970)"
                let request = UNNotificationRequest(
                    identifier: requestIdentifier,
                    content: content,
                    trigger: trigger
                )

                // 移除之前的通知
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()

                // 添加新通知
                try await UNUserNotificationCenter.current().add(request)
                logger.info("通知已安排: \(requestIdentifier), \(currentPhaseDuration)秒后触发")

                // 如果启用了重复提醒，调度重复通知
                if let timerModel = timerModel, timerModel.enableRepeatNotifications {
                    await repeatManager.scheduleRepeatNotifications(
                        initialDelay: TimeInterval(currentPhaseDuration),
                        title: content.title,
                        body: content.body
                    )
                    logger.info("已启用重复提醒功能")
                }

            } catch {
                logger.error("发送通知失败: \(error.localizedDescription)")
            }
        }
    }

    /// 取消所有重复通知
    func cancelRepeatNotifications() async {
        await repeatManager.cancelAllRepeatNotifications()
    }

    // MARK: - UNUserNotificationCenterDelegate
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == "START_NEXT_PHASE" {
            Task(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                await self.timerModel?.handleNotificationResponse()
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 无论前台还是后台，都显示系统通知（横幅 + 声音）
        // 这确保用户在任何状态下都能收到阶段完成提醒
        completionHandler([.banner, .sound])
    }

    // MARK: - Private Methods
    private func getPhaseLocalizationKey(for phaseName: String) -> String {
        switch phaseName.lowercased() {
        case "work", "专注":
            return "Phase_Work"
        case "short break", "短休息":
            return "Phase_Short_Break"
        case "long break", "长休息":
            return "Phase_Long_Break"
        default:
            return "Phase_Work"
        }
    }

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
