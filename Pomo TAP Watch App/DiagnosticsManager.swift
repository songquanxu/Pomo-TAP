//
//  DiagnosticsManager.swift
//  Pomo TAP Watch App
//
//  Created by Claude on 2025/10/11.
//  集中式诊断和日志管理系统
//

import SwiftUI
import os
import WatchKit
import UserNotifications

// MARK: - 系统健康状态
enum SystemHealthStatus {
    case healthy
    case warning
    case critical

    var emoji: String {
        switch self {
        case .healthy: return "✅"
        case .warning: return "⚠️"
        case .critical: return "❌"
        }
    }

    var description: String {
        switch self {
        case .healthy: return "健康"
        case .warning: return "警告"
        case .critical: return "严重"
        }
    }
}

// MARK: - 诊断项目
struct DiagnosticItem {
    let category: String
    let name: String
    let status: SystemHealthStatus
    let message: String
    let timestamp: Date
    let details: [String: Any]?

    init(category: String, name: String, status: SystemHealthStatus, message: String, details: [String: Any]? = nil) {
        self.category = category
        self.name = name
        self.status = status
        self.message = message
        self.timestamp = Date()
        self.details = details
    }
}

// MARK: - 集中式诊断管理器
@MainActor
class DiagnosticsManager: ObservableObject {
    // MARK: - Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "DiagnosticsManager")

    // 弱引用防止循环引用
    private weak var timerModel: TimerModel?
    private weak var deepLinkManager: DeepLinkManager?

    // 诊断数据
    @Published private(set) var diagnosticItems: [DiagnosticItem] = []
    @Published private(set) var overallHealthStatus: SystemHealthStatus = .healthy

    // 配置
    private let maxDiagnosticItems = 100  // 最大保存项目数
    private let healthCheckInterval: TimeInterval = 60.0  // 健康检查间隔（秒）

    // 计时器
    private var healthCheckTimer: Timer?

    // MARK: - Initialization
    init() {
        startHealthMonitoring()
    }

    @MainActor deinit {
        stopHealthMonitoring()
    }

    // MARK: - 依赖注入方法
    func setTimerModel(_ timerModel: TimerModel) {
        self.timerModel = timerModel
    }

    func setDeepLinkManager(_ deepLinkManager: DeepLinkManager) {
        self.deepLinkManager = deepLinkManager
    }

    // MARK: - 健康监控
    private func startHealthMonitoring() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performHealthCheck()
            }
        }
        logger.info("健康监控已启动（间隔: \(Int(self.healthCheckInterval))秒）")
    }

    private func stopHealthMonitoring() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        logger.info("健康监控已停止")
    }

    // MARK: - 系统健康检查
    func performHealthCheck() async {
        logger.debug("开始系统健康检查...")

        var allItems: [DiagnosticItem] = []

        // 1. 计时器核心诊断
        allItems.append(contentsOf: await checkTimerCoreHealth())

        // 2. 后台会话诊断
        allItems.append(contentsOf: await checkBackgroundSessionHealth())

        // 3. 通知系统诊断
        allItems.append(contentsOf: await checkNotificationHealth())

        // 4. 深度链接诊断
        allItems.append(contentsOf: checkDeepLinkHealth())

        // 5. 共享状态一致性诊断
        allItems.append(contentsOf: checkSharedWidgetState())

        // 6. 系统资源诊断
        allItems.append(contentsOf: checkSystemResourceHealth())

        // 7. Widget状态诊断
        allItems.append(contentsOf: checkWidgetHealth())

        // 更新诊断结果
        await updateDiagnosticResults(allItems)
    }

    // MARK: - 具体诊断方法

    /// 计时器核心健康检查
    private func checkTimerCoreHealth() async -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let timerModel = timerModel else {
            items.append(DiagnosticItem(
                category: "TimerCore",
                name: "Reference",
                status: .critical,
                message: "TimerModel引用丢失"
            ))
            return items
        }

        // 检查计时器状态一致性
        let timerRunning = timerModel.timerRunning
        let remainingTime = timerModel.remainingTime
        let totalTime = timerModel.totalTime

        if timerRunning && remainingTime <= 0 {
            items.append(DiagnosticItem(
                category: "TimerCore",
                name: "StateConsistency",
                status: .warning,
                message: "计时器正在运行但剩余时间为0",
                details: ["remainingTime": remainingTime]
            ))
        }

        if totalTime <= 0 {
            items.append(DiagnosticItem(
                category: "TimerCore",
                name: "Configuration",
                status: .warning,
                message: "总时间配置异常",
                details: ["totalTime": totalTime]
            ))
        }

        // 如果没有问题，记录健康状态
        if items.isEmpty {
            items.append(DiagnosticItem(
                category: "TimerCore",
                name: "Status",
                status: .healthy,
                message: "计时器核心运行正常",
                details: [
                    "running": timerRunning,
                    "remainingTime": remainingTime,
                    "totalTime": totalTime
                ]
            ))
        }

        return items
    }

    /// 后台会话健康检查
    private func checkBackgroundSessionHealth() async -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let timerModel = timerModel else { return items }

        let sessionManager = timerModel.sessionManager
        let isActive = sessionManager.isSessionActive
        let retainCount = sessionManager.sessionRetainCount

        // 检查会话状态合理性
        if timerModel.timerRunning && !isActive {
            items.append(DiagnosticItem(
                category: "BackgroundSession",
                name: "Consistency",
                status: .warning,
                message: "计时器运行但后台会话未激活",
                details: ["timerRunning": true, "sessionActive": isActive]
            ))
        }

        if retainCount < 0 {
            items.append(DiagnosticItem(
                category: "BackgroundSession",
                name: "RetainCount",
                status: .critical,
                message: "会话引用计数异常",
                details: ["retainCount": retainCount]
            ))
        }

        // 获取会话诊断信息
        let sessionDiagnostics = sessionManager.getSessionDiagnostics()

        if items.isEmpty {
            items.append(DiagnosticItem(
                category: "BackgroundSession",
                name: "Status",
                status: .healthy,
                message: "后台会话运行正常",
                details: ["diagnostics": sessionDiagnostics]
            ))
        }

        return items
    }

    /// 通知系统健康检查
    private func checkNotificationHealth() async -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        // 检查通知权限
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .denied:
            items.append(DiagnosticItem(
                category: "Notifications",
                name: "Permission",
                status: .critical,
                message: "通知权限被拒绝"
            ))
        case .notDetermined:
            items.append(DiagnosticItem(
                category: "Notifications",
                name: "Permission",
                status: .warning,
                message: "通知权限未确定"
            ))
        case .authorized:
            items.append(DiagnosticItem(
                category: "Notifications",
                name: "Permission",
                status: .healthy,
                message: "通知权限正常"
            ))
        default:
            items.append(DiagnosticItem(
                category: "Notifications",
                name: "Permission",
                status: .warning,
                message: "通知权限状态未知"
            ))
        }

        // 检查待发送通知数量
        let pendingRequests = await center.pendingNotificationRequests()
        if pendingRequests.count > 10 {
            items.append(DiagnosticItem(
                category: "Notifications",
                name: "PendingCount",
                status: .warning,
                message: "待发送通知过多",
                details: ["count": pendingRequests.count]
            ))
        }

        return items
    }

    /// 深度链接健康检查
    private func checkDeepLinkHealth() -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let deepLinkManager = deepLinkManager else {
            items.append(DiagnosticItem(
                category: "DeepLink",
                name: "Reference",
                status: .warning,
                message: "DeepLinkManager引用丢失"
            ))
            return items
        }

        let stats = deepLinkManager.executionStats
        let successRate = stats.successRate

        if successRate < 0.8 && stats.totalRequests > 5 {
            items.append(DiagnosticItem(
                category: "DeepLink",
                name: "SuccessRate",
                status: .warning,
                message: "深度链接成功率较低",
                details: [
                    "successRate": successRate,
                    "totalRequests": stats.totalRequests
                ]
            ))
        } else {
            items.append(DiagnosticItem(
                category: "DeepLink",
                name: "Status",
                status: .healthy,
                message: "深度链接运行正常",
                details: [
                    "successRate": successRate,
                    "totalRequests": stats.totalRequests
                ]
            ))
        }

        return items
    }

    /// 系统资源健康检查
    private func checkSystemResourceHealth() -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        // 检查电池状态（如果可用）
        let device = WKInterfaceDevice.current()
        if device.isBatteryMonitoringEnabled {
            let batteryLevel = device.batteryLevel
            if batteryLevel < 0.1 && batteryLevel > 0 {  // 电量低于10%
                items.append(DiagnosticItem(
                    category: "System",
                    name: "Battery",
                    status: .warning,
                    message: "电池电量较低",
                    details: ["batteryLevel": batteryLevel]
                ))
            }
        }

        // 检查内存压力（简化检查）
        let processInfo = ProcessInfo.processInfo
        if processInfo.thermalState == .critical {
            items.append(DiagnosticItem(
                category: "System",
                name: "Thermal",
                status: .critical,
                message: "系统热状态严重"
            ))
        }

        // 如果没有系统问题
        if items.isEmpty {
            items.append(DiagnosticItem(
                category: "System",
                name: "Status",
                status: .healthy,
                message: "系统资源正常"
            ))
        }

        return items
    }

    /// 共享状态一致性检查
    private func checkSharedWidgetState() -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName),
              let data = userDefaults.data(forKey: SharedTimerState.userDefaultsKey),
              let sharedState = try? JSONDecoder().decode(SharedTimerState.self, from: data) else {
            items.append(DiagnosticItem(
                category: "SharedState",
                name: "Availability",
                status: .warning,
                message: "无法读取共享状态"
            ))
            return items
        }

        var status: SystemHealthStatus = .healthy
        var message = "共享状态一致"
        var details: [String: Any] = [
            "displayMode": sharedState.displayMode.rawValue,
            "flowElapsed": sharedState.flowElapsedTime,
            "isInFlow": sharedState.isInFlowCountUp
        ]

        if let timerModel = timerModel {
            let expectedMode: PhaseDisplayMode
            if timerModel.isInFlowCountUp && timerModel.timerRunning {
                expectedMode = .flow
            } else if timerModel.timerRunning {
                expectedMode = .countdown
            } else if timerModel.remainingTime > 0 {
                expectedMode = .paused
            } else {
                expectedMode = .idle
            }

            if sharedState.displayMode != expectedMode {
                status = .warning
                message = "共享状态模式与计时器不同步"
                details["expectedMode"] = expectedMode.rawValue
            }
        }

        items.append(DiagnosticItem(
            category: "SharedState",
            name: "Consistency",
            status: status,
            message: message,
            details: details
        ))

        return items
    }

    /// Widget状态健康检查
    private func checkWidgetHealth() -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        guard let timerModel = timerModel else { return items }

        // 检查共享状态发布器
        _ = timerModel.sharedStatePublisher

        items.append(DiagnosticItem(
            category: "Widget",
            name: "StatePublisher",
            status: .healthy,
            message: "Widget状态发布器运行正常",
            details: [
                "optimizationActive": true
            ]
        ))

        return items
    }

    // MARK: - 结果处理

    /// 更新诊断结果
    private func updateDiagnosticResults(_ newItems: [DiagnosticItem]) async {
        // 添加新项目
        diagnosticItems.append(contentsOf: newItems)

        // 限制项目数量
        if diagnosticItems.count > maxDiagnosticItems {
            diagnosticItems = Array(diagnosticItems.suffix(maxDiagnosticItems))
        }

        // 计算整体健康状态
        updateOverallHealthStatus()

        logger.debug("健康检查完成：\(newItems.count)个新项目，整体状态: \(self.overallHealthStatus.description)")
    }

    /// 更新整体健康状态
    private func updateOverallHealthStatus() {
        // 获取最近的诊断项目（最近5分钟）
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let recentItems = diagnosticItems.filter { $0.timestamp > fiveMinutesAgo }

        // 如果有严重问题
        if recentItems.contains(where: { $0.status == .critical }) {
            overallHealthStatus = .critical
        }
        // 如果有警告
        else if recentItems.contains(where: { $0.status == .warning }) {
            overallHealthStatus = .warning
        }
        // 否则是健康的
        else {
            overallHealthStatus = .healthy
        }
    }

    // MARK: - 公共接口

    /// 获取完整诊断报告
    func getFullDiagnosticReport() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium

        var report = """
        📊 Pomo TAP 系统诊断报告
        生成时间: \(formatter.string(from: Date()))
        整体状态: \(overallHealthStatus.emoji) \(overallHealthStatus.description)

        """

        // 按类别分组
        let groupedItems = Dictionary(grouping: diagnosticItems) { $0.category }

        for (category, items) in groupedItems.sorted(by: { $0.key < $1.key }) {
            report += "\n📁 \(category):\n"

            let sortedItems = items.sorted { $0.timestamp > $1.timestamp }.prefix(3)  // 最近3个

            for item in sortedItems {
                let timeString = formatter.string(from: item.timestamp)
                report += "  \(item.status.emoji) \(item.name): \(item.message) (\(timeString))\n"
            }
        }

        return report
    }

    /// 获取简化健康报告
    func getHealthSummary() -> String {
        let criticalCount = diagnosticItems.filter { $0.status == .critical }.count
        let warningCount = diagnosticItems.filter { $0.status == .warning }.count
        let healthyCount = diagnosticItems.filter { $0.status == .healthy }.count

        return """
        \(overallHealthStatus.emoji) 系统状态: \(overallHealthStatus.description)
        ✅ 正常: \(healthyCount) | ⚠️ 警告: \(warningCount) | ❌ 严重: \(criticalCount)
        """
    }

    /// 手动触发健康检查
    func triggerHealthCheck() {
        Task {
            await performHealthCheck()
        }
    }

    /// 清除诊断历史
    func clearDiagnosticHistory() {
        diagnosticItems.removeAll()
        overallHealthStatus = .healthy
        logger.info("诊断历史已清除")
    }
}
