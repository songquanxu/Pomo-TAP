import SwiftUI
import UserNotifications
import os

// MARK: - 重复通知管理器
@MainActor
class NotificationRepeatManager: ObservableObject {
    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "NotificationRepeatManager")

    // MARK: - Constants
    private let repeatCount = 3  // 重复 3 次通知
    private let repeatInterval: TimeInterval = 60  // 每次间隔 1 分钟（60 秒）

    // MARK: - Public Methods

    /// 调度重复通知
    /// - Parameters:
    ///   - initialDelay: 第一次通知的延迟时间（秒）
    ///   - title: 通知标题
    ///   - body: 通知内容
    func scheduleRepeatNotifications(
        initialDelay: TimeInterval,
        title: String,
        body: String
    ) async {
        do {
            // 检查通知权限
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else {
                logger.warning("通知权限未获得，无法调度重复通知")
                return
            }

            // 先取消所有待发送的重复通知
            await cancelAllRepeatNotifications()

            // 调度 3 次重复通知
            for index in 0..<repeatCount {
                // 计算每次通知的延迟时间
                // 第 0 次：initialDelay（例如 1500 秒，即 25 分钟）
                // 第 1 次：initialDelay + 60 秒
                // 第 2 次：initialDelay + 120 秒
                let delay = initialDelay + (TimeInterval(index) * repeatInterval)

                // 创建通知内容
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = "PomoTAP_Notifications"
                content.categoryIdentifier = "PHASE_COMPLETED"

                // 创建触发器
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: delay,
                    repeats: false
                )

                // 创建通知请求（使用固定 identifier 以便取消）
                let identifier = "PomoTAP_Repeat_\(index)"
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: trigger
                )

                // 添加通知到系统
                try await UNUserNotificationCenter.current().add(request)
                logger.info("已调度重复通知 #\(index + 1): \(delay)秒后触发")
            }

            logger.info("✅ 成功调度 \(self.repeatCount) 次重复通知")

        } catch {
            logger.error("调度重复通知失败: \(error.localizedDescription)")
        }
    }

    /// 取消所有待发送的重复通知
    func cancelAllRepeatNotifications() async {
        // 获取所有待发送的通知
        let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()

        // 筛选出重复通知的 identifier
        let repeatIdentifiers = pendingRequests
            .filter { $0.identifier.hasPrefix("PomoTAP_Repeat_") }
            .map { $0.identifier }

        // 取消重复通知
        if !repeatIdentifiers.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: repeatIdentifiers
            )
            logger.info("已取消 \(repeatIdentifiers.count) 个待发送的重复通知")
        }
    }

    /// 取消所有通知（包括普通通知和重复通知）
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        logger.info("已取消所有通知（普通 + 重复）")
    }
}
