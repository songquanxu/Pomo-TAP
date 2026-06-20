import Foundation

enum PhaseDisplayMode: String, Codable {
    case countdown
    case flow
    case paused
    case idle
}

enum PhaseCategory: String, Codable {
    case work
    case shortBreak
    case longBreak
    case unknown
}

struct SharedTimerState: Codable {
    let currentPhaseIndex: Int
    let remainingTime: Int
    let timerRunning: Bool
    let currentPhaseName: String
    let lastUpdateTime: Date
    let totalTime: Int
    let phases: [PhaseInfo]
    let completedCycles: Int
    let phaseCompletionStatus: [PhaseCompletionStatus]
    let hasSkippedInCurrentCycle: Bool
    let isCurrentPhaseWorkPhase: Bool

    // Heart flow additions
    let isInFlowCountUp: Bool
    let flowElapsedTime: Int
    let displayMode: PhaseDisplayMode
    let currentPhaseType: PhaseCategory
    let phaseEndDate: Date?
    let flowStartDate: Date?

    var progress: Double {
        switch displayMode {
        case .flow:
            return 1.0
        case .countdown, .paused:
            guard totalTime > 0 else { return 0 }
            return 1.0 - Double(remainingTime) / Double(totalTime)
        case .idle:
            return 0
        }
    }

    var standardizedPhaseName: String {
        switch currentPhaseType {
        case .work:
            return "work"
        case .shortBreak:
            return "shortBreak"
        case .longBreak:
            return "longBreak"
        case .unknown:
            return currentPhaseName.lowercased()
        }
    }

    static let userDefaultsKey = "TimerState"
    static let suiteName = "group.songquan.Pomo-TAP"

    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
        case currentPhaseIndex
        case remainingTime
        case timerRunning
        case currentPhaseName
        case lastUpdateTime
        case totalTime
        case phases
        case completedCycles
        case phaseCompletionStatus
        case hasSkippedInCurrentCycle
        case isCurrentPhaseWorkPhase
        case isInFlowCountUp
        case flowElapsedTime
        case displayMode
        case currentPhaseType
        case phaseEndDate
        case flowStartDate
    }

    init(currentPhaseIndex: Int,
         remainingTime: Int,
         timerRunning: Bool,
         currentPhaseName: String,
         lastUpdateTime: Date,
         totalTime: Int,
         phases: [PhaseInfo],
         completedCycles: Int,
         phaseCompletionStatus: [PhaseCompletionStatus],
         hasSkippedInCurrentCycle: Bool,
         isCurrentPhaseWorkPhase: Bool,
         isInFlowCountUp: Bool,
         flowElapsedTime: Int,
         displayMode: PhaseDisplayMode,
         currentPhaseType: PhaseCategory,
         phaseEndDate: Date?,
         flowStartDate: Date?) {
        self.currentPhaseIndex = currentPhaseIndex
        self.remainingTime = remainingTime
        self.timerRunning = timerRunning
        self.currentPhaseName = currentPhaseName
        self.lastUpdateTime = lastUpdateTime
        self.totalTime = totalTime
        self.phases = phases
        self.completedCycles = completedCycles
        self.phaseCompletionStatus = phaseCompletionStatus
        self.hasSkippedInCurrentCycle = hasSkippedInCurrentCycle
        self.isCurrentPhaseWorkPhase = isCurrentPhaseWorkPhase
        self.isInFlowCountUp = isInFlowCountUp
        self.flowElapsedTime = flowElapsedTime
        self.displayMode = displayMode
        self.currentPhaseType = currentPhaseType
        self.phaseEndDate = phaseEndDate
        self.flowStartDate = flowStartDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPhaseIndex = try container.decode(Int.self, forKey: .currentPhaseIndex)
        remainingTime = try container.decode(Int.self, forKey: .remainingTime)
        timerRunning = try container.decode(Bool.self, forKey: .timerRunning)
        currentPhaseName = try container.decode(String.self, forKey: .currentPhaseName)
        lastUpdateTime = try container.decode(Date.self, forKey: .lastUpdateTime)
        totalTime = try container.decode(Int.self, forKey: .totalTime)
        phases = try container.decode([PhaseInfo].self, forKey: .phases)
        completedCycles = try container.decode(Int.self, forKey: .completedCycles)
        phaseCompletionStatus = try container.decode([PhaseCompletionStatus].self, forKey: .phaseCompletionStatus)
        hasSkippedInCurrentCycle = try container.decode(Bool.self, forKey: .hasSkippedInCurrentCycle)
        isCurrentPhaseWorkPhase = try container.decodeIfPresent(Bool.self, forKey: .isCurrentPhaseWorkPhase) ?? false
        isInFlowCountUp = try container.decodeIfPresent(Bool.self, forKey: .isInFlowCountUp) ?? false
        flowElapsedTime = try container.decodeIfPresent(Int.self, forKey: .flowElapsedTime) ?? 0
        displayMode = try container.decodeIfPresent(PhaseDisplayMode.self, forKey: .displayMode)
            ?? (timerRunning ? .countdown : .paused)
        currentPhaseType = try container.decodeIfPresent(PhaseCategory.self, forKey: .currentPhaseType)
            ?? (isCurrentPhaseWorkPhase ? .work : .unknown)
        phaseEndDate = try container.decodeIfPresent(Date.self, forKey: .phaseEndDate)
        flowStartDate = try container.decodeIfPresent(Date.self, forKey: .flowStartDate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentPhaseIndex, forKey: .currentPhaseIndex)
        try container.encode(remainingTime, forKey: .remainingTime)
        try container.encode(timerRunning, forKey: .timerRunning)
        try container.encode(currentPhaseName, forKey: .currentPhaseName)
        try container.encode(lastUpdateTime, forKey: .lastUpdateTime)
        try container.encode(totalTime, forKey: .totalTime)
        try container.encode(phases, forKey: .phases)
        try container.encode(completedCycles, forKey: .completedCycles)
        try container.encode(phaseCompletionStatus, forKey: .phaseCompletionStatus)
        try container.encode(hasSkippedInCurrentCycle, forKey: .hasSkippedInCurrentCycle)
        try container.encode(isCurrentPhaseWorkPhase, forKey: .isCurrentPhaseWorkPhase)
        try container.encode(isInFlowCountUp, forKey: .isInFlowCountUp)
        try container.encode(flowElapsedTime, forKey: .flowElapsedTime)
        try container.encode(displayMode, forKey: .displayMode)
        try container.encode(currentPhaseType, forKey: .currentPhaseType)
        try container.encodeIfPresent(phaseEndDate, forKey: .phaseEndDate)
        try container.encodeIfPresent(flowStartDate, forKey: .flowStartDate)
    }
}

struct PhaseInfo: Codable {
    let duration: Int
    let name: String
    let status: String
    let adjustedDuration: Int?

    enum CodingKeys: String, CodingKey {
        case duration
        case name
        case status
        case adjustedDuration
    }

    init(duration: Int, name: String, status: String, adjustedDuration: Int?) {
        self.duration = duration
        self.name = name
        self.status = status
        self.adjustedDuration = adjustedDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decode(Int.self, forKey: .duration)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        adjustedDuration = try container.decodeIfPresent(Int.self, forKey: .adjustedDuration)
    }
}

// MARK: - Phase Completion Status
enum PhaseCompletionStatus: String, Codable {
    case notStarted
    case current
    case normalCompleted
    case skipped

    var displayColor: String {
        switch self {
        case .normalCompleted:
            return "orange"
        case .skipped:
            return "green"
        case .current:
            return "blue"
        case .notStarted:
            return "gray"
        }
    }
}

// MARK: - Control ↔ App 桥接（App Group）
/// Control Center 控件的意图运行在 widget 扩展进程，无法直接驱动 app 内的计时器引擎
/// （`DispatchSourceTimer` + `WKExtendedRuntimeSession` + 通知都在主 app 进程）。
/// 因此控件把"待处理动作"（一个 `pomoTAP://` 深度链接）写入 App Group，并通过
/// `openAppWhenRun` 唤起 app；app 在激活时取出并经既有的、幂等的 `DeepLinkManager` 执行。
/// 这复用了矩形复杂功能点击切换所走的同一条成熟路径。
enum ControlActionBridge {
    /// Start/Pause 控件的 kind（用于 `ControlCenter.reloadControls(ofKind:)`）
    static let startPauseControlKind = "PomoTAPStartPauseControl"
    /// 智能叠放相关度小组件的 kind
    static let relevanceWidgetKind = "PomoTAPSmartFocus"
    /// App Group 中存放待处理动作的键
    static let pendingActionKey = "PendingControlAction"
    /// 启停计时器的深度链接（与矩形复杂功能一致）
    static let toggleURLString = "pomoTAP://toggle"

    /// 写入待处理动作（在控件意图中调用）
    static func setPendingAction(_ urlString: String) {
        UserDefaults(suiteName: SharedTimerState.suiteName)?.set(urlString, forKey: pendingActionKey)
    }

    /// 取出并清除待处理动作（一次性消费，在 app 激活时调用）
    static func takePendingAction() -> String? {
        guard let defaults = UserDefaults(suiteName: SharedTimerState.suiteName),
              let value = defaults.string(forKey: pendingActionKey) else {
            return nil
        }
        defaults.removeObject(forKey: pendingActionKey)
        return value
    }
}
