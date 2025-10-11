//
//  DeepLinkManager.swift
//  Pomo TAP Watch App
//
//  Created by Claude on 2025/10/11.
//  统一深度链接处理器 - 幂等性和防重复执行
//

import SwiftUI
import os

// MARK: - 深度链接操作类型
enum DeepLinkAction: String, CaseIterable {
    case open = "open"
    case startWork = "startWork"
    case startBreak = "startBreak"
    case startLongBreak = "startLongBreak"
    case toggle = "toggle"
    case skipPhase = "skipPhase"

    var description: String {
        switch self {
        case .open:
            return "打开应用"
        case .startWork:
            return "开始工作阶段"
        case .startBreak:
            return "开始短休息"
        case .startLongBreak:
            return "开始长休息"
        case .toggle:
            return "切换计时器状态"
        case .skipPhase:
            return "跳过当前阶段"
        }
    }
}

// MARK: - 深度链接执行结果
enum DeepLinkResult {
    case success(message: String)
    case duplicate(message: String)
    case failed(error: String)
    case unsupported(action: String)
}

// MARK: - 统一深度链接管理器
@MainActor
class DeepLinkManager: ObservableObject {
    // MARK: - Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "DeepLinkManager")
    private weak var timerModel: TimerModel?

    // 幂等性控制：防止重复执行
    private var lastExecutionTime: [DeepLinkAction: Date] = [:]
    private let minimumExecutionInterval: TimeInterval = 1.0  // 1秒内不重复执行相同操作

    // 执行统计
    @Published private(set) var executionStats: ExecutionStats = ExecutionStats()

    // MARK: - 执行统计结构
    struct ExecutionStats {
        var totalRequests: Int = 0
        var successfulExecutions: Int = 0
        var duplicateRequests: Int = 0
        var failedExecutions: Int = 0

        var successRate: Double {
            guard totalRequests > 0 else { return 0 }
            return Double(successfulExecutions) / Double(totalRequests)
        }

        mutating func recordRequest() {
            totalRequests += 1
        }

        mutating func recordSuccess() {
            successfulExecutions += 1
        }

        mutating func recordDuplicate() {
            duplicateRequests += 1
        }

        mutating func recordFailure() {
            failedExecutions += 1
        }
    }

    // MARK: - Initialization
    init(timerModel: TimerModel) {
        self.timerModel = timerModel
    }

    // MARK: - 主要处理方法
    /// 处理深度链接URL - 统一入口点
    /// - Parameter url: 深度链接URL
    /// - Returns: 执行结果
    func handleDeepLink(_ url: URL) async -> DeepLinkResult {
        executionStats.recordRequest()

        // 1. 验证URL格式
        guard url.scheme == "pomoTAP" else {
            let error = "不支持的URL scheme: \(url.scheme ?? "nil")"
            logger.warning("\(error)")
            executionStats.recordFailure()
            return .failed(error: error)
        }

        // 2. 解析操作类型
        guard let host = url.host,
              let action = DeepLinkAction(rawValue: host) else {
            let error = "不支持的操作: \(url.host ?? "nil")"
            logger.warning("\(error)")
            executionStats.recordFailure()
            return .unsupported(action: url.host ?? "unknown")
        }

        // 3. 幂等性检查
        if let duplicate = checkForDuplicateExecution(action: action) {
            executionStats.recordDuplicate()
            return duplicate
        }

        // 4. 执行操作
        let result = await executeAction(action)

        // 5. 记录执行时间（用于幂等性控制）
        lastExecutionTime[action] = Date()

        return result
    }

    // MARK: - 私有方法

    /// 检查重复执行
    private func checkForDuplicateExecution(action: DeepLinkAction) -> DeepLinkResult? {
        if let lastExecution = lastExecutionTime[action] {
            let timeSinceLastExecution = Date().timeIntervalSince(lastExecution)
            if timeSinceLastExecution < minimumExecutionInterval {
                let message = "\(action.description) - 重复请求被忽略（\(String(format: "%.1f", timeSinceLastExecution))秒前已执行）"
                logger.debug("\(message)")
                return .duplicate(message: message)
            }
        }
        return nil
    }

    /// 执行具体操作
    private func executeAction(_ action: DeepLinkAction) async -> DeepLinkResult {
        guard let timerModel = timerModel else {
            let error = "TimerModel 引用丢失"
            logger.error("\(error)")
            executionStats.recordFailure()
            return .failed(error: error)
        }

        logger.info("🔗 执行深度链接操作: \(action.description)")

        switch action {
        case .open:
            // 打开应用 - 无需具体操作
            executionStats.recordSuccess()
            return .success(message: "应用已打开")

        case .startWork:
            timerModel.startWorkPhaseDirectly()
            executionStats.recordSuccess()
            return .success(message: "工作阶段已开始")

        case .startBreak:
            timerModel.startBreakPhaseDirectly()
            executionStats.recordSuccess()
            return .success(message: "短休息已开始")

        case .startLongBreak:
            timerModel.startLongBreakPhaseDirectly()
            executionStats.recordSuccess()
            return .success(message: "长休息已开始")

        case .toggle:
            await timerModel.toggleTimer()
            let message = timerModel.timerRunning ? "计时器已启动" : "计时器已暂停"
            executionStats.recordSuccess()
            return .success(message: message)

        case .skipPhase:
            await timerModel.skipCurrentPhase()
            executionStats.recordSuccess()
            return .success(message: "已跳过当前阶段")
        }
    }

    // MARK: - 诊断和监控方法

    /// 获取执行统计报告
    func getExecutionReport() -> String {
        let stats = executionStats
        return """
        📊 深度链接执行统计:
        • 总请求数: \(stats.totalRequests)
        • 成功执行: \(stats.successfulExecutions)
        • 重复请求: \(stats.duplicateRequests)
        • 执行失败: \(stats.failedExecutions)
        • 成功率: \(String(format: "%.1f", stats.successRate * 100))%
        """
    }

    /// 重置统计数据
    func resetStatistics() {
        executionStats = ExecutionStats()
        lastExecutionTime.removeAll()
        logger.info("深度链接统计数据已重置")
    }

    /// 获取最近执行历史
    func getRecentExecutions() -> [String] {
        return lastExecutionTime.map { action, time in
            let timeAgo = Date().timeIntervalSince(time)
            return "\(action.description): \(String(format: "%.1f", timeAgo))秒前"
        }.sorted()
    }
}

// MARK: - 便利扩展
extension DeepLinkManager {
    /// 快速处理URL字符串
    func handleDeepLink(_ urlString: String) async -> DeepLinkResult {
        guard let url = URL(string: urlString) else {
            executionStats.recordFailure()
            return .failed(error: "无效的URL字符串: \(urlString)")
        }
        return await handleDeepLink(url)
    }
}
