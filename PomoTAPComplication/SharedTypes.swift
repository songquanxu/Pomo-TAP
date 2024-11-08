import Foundation

struct SharedTimerState: Codable {
    let currentPhaseIndex: Int
    let remainingTime: Int
    let timerRunning: Bool
    let currentPhaseName: String
    let lastUpdateTime: Date
    let totalTime: Int
    let phases: [PhaseInfo]
    
    static let userDefaultsKey = "SharedTimerState"
    static let suiteName = "group.com.songquan.pomoTAP.shared"
}

struct PhaseInfo: Codable {
    let duration: Int
    let name: String
    let status: String
} 