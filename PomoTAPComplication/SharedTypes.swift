import Foundation

struct SharedTimerState: Codable {
    let currentPhaseIndex: Int
    let remainingTime: Int
    let timerRunning: Bool
    let currentPhaseName: String
    let lastUpdateTime: Date
    let totalTime: Int
    
    static let userDefaultsKey = "SharedTimerState"
    static let suiteName = "group.com.songquan.pomoTAP.shared"
} 