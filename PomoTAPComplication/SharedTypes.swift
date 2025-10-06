import Foundation

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
    let isCurrentPhaseWorkPhase: Bool  // NEW: Track if current phase is work phase

    var progress: Double {
        1.0 - Double(remainingTime) / Double(totalTime)
    }

    var standardizedPhaseName: String {
        switch currentPhaseName.lowercased() {
        case "work", "专注":
            return "work"
        case "short break", "短休息":
            return "shortBreak"
        case "long break", "长休息":
            return "longBreak"
        default:
            return "work"
        }
    }

    static let userDefaultsKey = "TimerState"
    static let suiteName = "group.songquan.Pomo-TAP"
}

struct PhaseInfo: Codable {
    let duration: Int
    let name: String
    let status: String
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
