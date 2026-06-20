import SwiftUI
import UserNotifications
import os

// MARK: - 通知管理
@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "NotificationManager")
    weak var timerModel: TimerModel?
    private let repeatManager = NotificationRepeatManager()  // 重复通知管理器

    // MARK: - Initialization
    init(timerModel: TimerModel? = nil) {
        self.timerModel = timerModel
        super.init()
        UNUserNotificationCenter.current().delegate = self
        // 关键：通知 category 不会跨启动持久化，必须在每次启动时无条件注册，
        // 否则用户授权后的后续启动里 “立即开始下一阶段” 动作按钮会消失。
        registerNotificationCategories()
    }

    // MARK: - Public Methods
    func requestNotificationPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                if granted {
                    // category 已在 init 中注册，这里仅记录授权结果
                    logger.info("通知权限已获得")
                } else {
                    logger.warning("用户拒绝了通知权限")
                }
            } catch {
                logger.error("请求通知权限时出错: \(error.localizedDescription)")
            }
        }
    }

    /// 安排阶段完成通知。
    /// - Parameters:
    ///   - currentPhaseDurationSeconds: 当前阶段剩余时间（**秒**），用作触发器间隔。
    ///   - nextPhaseDurationMinutes: 下一阶段时长（**分钟**），仅用于通知正文展示。
    func sendNotification(for event: NotificationEvent, currentPhaseDurationSeconds: Int, nextPhaseDurationMinutes: Int) {
        Task {
            do {
                // 检查权限状态
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                guard settings.authorizationStatus == .authorized else {
                    logger.warning("通知权限未获得，无法发送通知")
                    return
                }

                // 验证参数
                guard currentPhaseDurationSeconds > 0, nextPhaseDurationMinutes > 0 else {
                    logger.error("无效的阶段持续时间: 当前=\(currentPhaseDurationSeconds)秒, 下一个=\(nextPhaseDurationMinutes)分")
                    return
                }

                // 创建通知内容
                let content = UNMutableNotificationContent()
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.relevanceScore = 0.8  // 高相关性评分，提升 Smart Stack 和通知优先级
                content.threadIdentifier = "PomoTAP_Notifications"
                content.categoryIdentifier = "PHASE_COMPLETED"

                // 标记此通知对应的“正在倒计时的阶段”索引：响应时据此精确判断是否需要推进，
                // 消除 “remainingTime == totalTime” 启发式在 reset/skip/快捷启动后的阶段误判。
                let scheduledPhaseIndex = timerModel?.currentPhaseIndex ?? 0
                content.userInfo = ["scheduledPhaseIndex": scheduledPhaseIndex]

                switch event {
                case .phaseCompleted:
                    content.title = NSLocalizedString("Great_Job", comment: "")

                    // 获取下一个阶段的名称
                    let nextPhaseIndex = ((timerModel?.currentPhaseIndex ?? 0) + 1) % (timerModel?.phases.count ?? 4)
                    let nextPhaseName = timerModel?.phases[nextPhaseIndex].name ?? "Work"
                    let nextPhaseType = localizedPhaseDisplayName(for: nextPhaseName)

                    content.body = String(
                        format: NSLocalizedString("Notification_Body", comment: "通知内容：%d = 持续时间（分钟），%@ = 阶段类型"),
                        nextPhaseDurationMinutes,
                        nextPhaseType
                    )
                }

                // 创建触发器 - 使用剩余时间（秒）
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: TimeInterval(currentPhaseDurationSeconds),  // 直接使用秒数
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
                logger.info("通知已安排: \(requestIdentifier), \(currentPhaseDurationSeconds)秒后触发")

                // 如果启用了重复提醒，调度重复通知
                if let timerModel = timerModel, timerModel.enableRepeatNotifications {
                    await repeatManager.scheduleRepeatNotifications(
                        initialDelay: TimeInterval(currentPhaseDurationSeconds),
                        title: content.title,
                        body: content.body,
                        scheduledPhaseIndex: scheduledPhaseIndex
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
            // 在 nonisolated 上下文同步取出 Sendable 的 Int，避免把非 Sendable 的 userInfo 字典捕获进 @MainActor Task
            let scheduledPhaseIndex = response.notification.request.content.userInfo["scheduledPhaseIndex"] as? Int
            Task(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                await self.timerModel?.handleNotificationResponse(scheduledPhaseIndex: scheduledPhaseIndex)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // watchOS 26 通知展示：前台也使用 list + sound（部署下限 26，无需版本判断，避免已废弃的 .alert）
        completionHandler([.list, .sound])
    }

    // MARK: - Private Methods
    private func localizedPhaseDisplayName(for phaseName: String) -> String {
        switch phaseName.lowercased() {
        case "work", "专注":
            return NSLocalizedString("Phase_Work", comment: "阶段类型：专注")
        case "short break", "短休息":
            return NSLocalizedString("Phase_Short_Break", comment: "阶段类型：短休息")
        case "long break", "长休息":
            return NSLocalizedString("Phase_Long_Break", comment: "阶段类型：长休息")
        default:
            return NSLocalizedString("Phase_Work", comment: "阶段类型：专注默认值")
        }
    }

    /// 注册通知 category（含 “立即开始下一阶段” 动作）。
    /// 必须在每次启动时调用——category 不会被系统跨进程/跨启动持久化。
    private func registerNotificationCategories() {
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
        logger.info("通知 category 已注册（PHASE_COMPLETED）")
    }
}
