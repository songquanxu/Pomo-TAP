import Foundation

struct SharedTimerState: Codable {
    let currentPhaseIndex: Int
    let remainingTime: Int
    let timerRunning: Bool
    let currentPhaseName: String
    let lastUpdateTime: Date
    let totalTime: Int
    let phases: [PhaseInfo]
    
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