import WatchKit

enum FeedbackPattern {
    case phaseComplete
    case shortBreakStart
    case longBreakStart
    case focusStart
}

class HapticManager {
    static let shared = HapticManager()
    private let device = WKInterfaceDevice.current()
    
    private init() {}
    
    func playPattern(_ pattern: FeedbackPattern) {
        Task {
            switch pattern {
            case .phaseComplete:
                // 完成阶段：成功音效 + 触觉反馈组合
                WKInterfaceDevice.current().play(.notification)
                try? await Task.sleep(nanoseconds: 200_000_000)
                WKInterfaceDevice.current().play(.success)
                
            case .shortBreakStart:
                // 开始短休息：轻柔上升音效 + 触觉反馈
                WKInterfaceDevice.current().play(.start)
                
            case .longBreakStart:
                // 开始长休息：强烈上升音效 + 触觉反馈
                WKInterfaceDevice.current().play(.start)

                
            case .focusStart:
                // 开始专注：坚定下降音效 + 触觉反馈
                WKInterfaceDevice.current().play(.start)
            }
        }
    }
} 
