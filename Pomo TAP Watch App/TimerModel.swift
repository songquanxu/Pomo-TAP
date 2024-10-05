import SwiftUI
import WatchKit
import Combine
import UserNotifications
import os
import CoreData

class TimerModel: ObservableObject {
    @Published var currentPhase = 0
    @Published var remainingTime = 25 * 60
    @Published var timerRunning = false
    @Published var completedCycles = 0
    @Published var isAppActive = true
    @Published var lastBackgroundDate: Date?
    @Published var hasSkippedInCurrentCycle = false
    @Published var isResetState = false
    @Published var isInDecisionMode = false
    @Published var isInCooldownMode = false
    @Published var currentCycleCompleted = false
    @Published var tomatoRingPosition: Angle = .zero
    @Published var isTransitioning = false
    @Published var transitionProgress: CGFloat = 0
    @Published var decisionStartAngle: Angle = .zero
    @Published var decisionRingPosition: Angle = .zero
    @Published var cooldownStartAngle: Angle = .zero
    @Published var cooldownEndAngle: Angle = .zero
    @Published var cooldownRingPosition: Angle = .zero
    @Published var isInResetMode = false
    @Published var decisionProgress: CGFloat = 0
    @Published var cooldownProgress: CGFloat = 0
    @Published var decisionEndAngle: Angle = .zero  // 添加这行

    var phases: [Phase] = []
    var phaseCompletionStatus: [PhaseStatus] = []
    var cyclePhaseCount = 0
    var lastPhase = 0
    var lastUsageTime: TimeInterval = 0
    var lastCycleCompletionTime: TimeInterval = 0

    private let userDefaults: UserDefaults
    private let logger = Logger(subsystem: "com.yourcompany.pomoTAP", category: "TimerModel")
    private let persistentContainer: NSPersistentContainer
    private var timer: AnyCancellable?
    private var startTime: Date?
    private var savedRemainingTime: Int?
    private var decisionTimer: Timer?
    private var cooldownTimer: Timer?

    init() {
        self.userDefaults = UserDefaults(suiteName: "group.com.yourcompany.pomoTAP")!
        persistentContainer = NSPersistentContainer(name: "PomoTAPModel")
        persistentContainer.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        loadPhases()
        loadState()
        resetPhaseCompletionStatus()
    }

    private func loadPhases() {
        do {
            if let url = Bundle.main.url(forResource: "phases", withExtension: "json"),
               let data = try? Data(contentsOf: url) {
                phases = try JSONDecoder().decode([Phase].self, from: data)
                logger.info("Successfully loaded phases from JSON")
            } else {
                throw NSError(domain: "com.yourcompany.pomoTAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find or load phases.json"])
            }
        } catch {
            logger.error("Error loading phases: \(error.localizedDescription)")
            useDefaultPhases()
        }
    }

    private func useDefaultPhases() {
        phases = [
            Phase(duration: 1500, name: "Work"),
            Phase(duration: 300, name: "Short Break"),
            Phase(duration: 1500, name: "Work"),
            Phase(duration: 900, name: "Long Break")
        ]
        logger.warning("Using default phases due to loading error")
    }

    private func loadState() {
        currentPhase = userDefaults.integer(forKey: "currentPhase")
        remainingTime = userDefaults.integer(forKey: "remainingTime")
        timerRunning = userDefaults.bool(forKey: "timerRunning")
        completedCycles = userDefaults.integer(forKey: "completedCycles")
        hasSkippedInCurrentCycle = userDefaults.bool(forKey: "hasSkippedInCurrentCycle")
        currentCycleCompleted = userDefaults.bool(forKey: "currentCycleCompleted")
        lastUsageTime = userDefaults.double(forKey: "lastUsageTime")
        lastCycleCompletionTime = userDefaults.double(forKey: "lastCycleCompletionTime")
    }

    func saveState() {
        userDefaults.set(currentPhase, forKey: "currentPhase")
        userDefaults.set(remainingTime, forKey: "remainingTime")
        userDefaults.set(timerRunning, forKey: "timerRunning")
        userDefaults.set(completedCycles, forKey: "completedCycles")
        userDefaults.set(hasSkippedInCurrentCycle, forKey: "hasSkippedInCurrentCycle")
        userDefaults.set(currentCycleCompleted, forKey: "currentCycleCompleted")
        userDefaults.set(lastUsageTime, forKey: "lastUsageTime")
        userDefaults.set(lastCycleCompletionTime, forKey: "lastCycleCompletionTime")
        userDefaults.set(Date(), forKey: "lastUpdateTime")
    }

    func resetPhaseCompletionStatus() {
        phaseCompletionStatus = Array(repeating: .notStarted, count: phases.count)
        phaseCompletionStatus[currentPhase] = .current
    }

    func startDecisionMode() {
        DispatchQueue.main.async {
            self.isInDecisionMode = true
            self.isInCooldownMode = false
            self.decisionProgress = 0
            self.isResetState = true
            
            self.decisionStartAngle = self.tomatoRingPosition
            self.decisionEndAngle = Angle(degrees: 360)
            self.decisionRingPosition = self.decisionStartAngle
            
            let duration = 3.0
            
            self.decisionTimer?.invalidate()
            self.decisionTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                self.decisionProgress += 0.01 / duration
                self.decisionRingPosition = self.decisionStartAngle + Angle(degrees: (self.decisionEndAngle.degrees - self.decisionStartAngle.degrees) * self.decisionProgress)
                
                if self.decisionProgress >= 0.66 && self.decisionProgress < 0.67 {
                    WKInterfaceDevice.current().play(.notification)
                } else if self.decisionProgress >= 0.33 && self.decisionProgress < 0.34 {
                    WKInterfaceDevice.current().play(.notification)
                }
                
                if self.decisionProgress >= 1 {
                    self.completeSkip()
                    timer.invalidate()
                }
            }
        }
    }

    func cancelDecisionMode() {
        DispatchQueue.main.async {
            self.isInDecisionMode = false
            self.decisionTimer?.invalidate()
            self.startCooldownMode()
        }
    }

    func startCooldownMode() {
        DispatchQueue.main.async {
            self.isInCooldownMode = true
            self.isInDecisionMode = false
            self.isResetState = true
            self.cooldownProgress = 0
            
            self.cooldownStartAngle = self.tomatoRingPosition
            self.cooldownEndAngle = self.decisionRingPosition
            self.cooldownRingPosition = self.cooldownEndAngle
            
            self.cooldownTimer?.invalidate()
            self.cooldownTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                self.cooldownProgress += 0.01 / 3.0
                self.cooldownRingPosition = self.cooldownEndAngle - Angle(degrees: (self.cooldownEndAngle.degrees - self.cooldownStartAngle.degrees) * self.cooldownProgress)
                if self.cooldownProgress >= 1 {
                    self.isInCooldownMode = false
                    self.isResetState = false
                    self.cooldownProgress = 0
                    timer.invalidate()
                }
            }
        }
    }

    func completeSkip() {
        DispatchQueue.main.async {
            self.isInDecisionMode = false
            self.isInCooldownMode = false
            self.decisionProgress = 0
            self.skipPhase()
        }
    }

    func skipPhase() {
        hasSkippedInCurrentCycle = true
        stopTimer()
        moveToNextPhase(autoStart: true)
        isResetState = false
        WKInterfaceDevice.current().play(.notification)
    }

    func startNextPhase() {
        moveToNextPhase(autoStart: true)
    }

    func moveToNextPhase(autoStart: Bool = false) {
        if !isAppActive {
            sendNotification()
            return
        }
        
        startTransitionAnimation()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.phaseCompletionStatus[self.currentPhase] = self.hasSkippedInCurrentCycle ? .skipped : .normalCompleted
            self.currentPhase = (self.currentPhase + 1) % self.phases.count
            
            if self.currentPhase == 0 {
                self.completeCycle()
            } else {
                self.phaseCompletionStatus[self.currentPhase] = .current
            }
            
            self.remainingTime = self.phases[self.currentPhase].duration
            self.cyclePhaseCount += 1
            
            self.lastPhase = self.currentPhase
            self.lastUsageTime = Date().timeIntervalSince1970
            
            self.stopTimer()
            self.timerRunning = false
            
            self.tomatoRingPosition = .zero
            
            if autoStart {
                self.startTimer()
                self.timerRunning = true
            }
            
            self.saveState()
        }
    }

    private func completeCycle() {
        if !hasSkippedInCurrentCycle {
            completedCycles += 1
            lastCycleCompletionTime = Date().timeIntervalSince1970
        }
        cyclePhaseCount = 0
        hasSkippedInCurrentCycle = false
        checkAndUpdateCompletedCycles()
        resetPhaseCompletionStatus()
        currentCycleCompleted = true
    }

    func startTimer() {
        if let savedTime = savedRemainingTime {
            remainingTime = savedTime
            savedRemainingTime = nil
        }
        
        startTime = Date().addingTimeInterval(-Double(phases[currentPhase].duration - remainingTime))
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateTimer()
            }
    }

    func stopTimer() {
        timer?.cancel()
        timer = nil
        savedRemainingTime = remainingTime
        startTime = nil
    }

    func updateTimer() {
        let elapsedTime: Int
        if let lastBackgroundDate = lastBackgroundDate {
            elapsedTime = Int(Date().timeIntervalSince(lastBackgroundDate))
            self.lastBackgroundDate = nil
        } else {
            elapsedTime = Int(Date().timeIntervalSince(self.startTime ?? Date()))
        }
        
        let newRemainingTime = max(0, min(phases[currentPhase].duration, phases[currentPhase].duration - elapsedTime))
        
        if newRemainingTime == 0 && remainingTime > 0 {
            WKInterfaceDevice.current().play(.success)
        }
        
        remainingTime = newRemainingTime
        updateTomatoRingPosition()
        
        if remainingTime == 0 {
            moveToNextPhase(autoStart: false)
        }
    }

    func updateTomatoRingPosition() {
        let progress = 1 - Double(remainingTime) / Double(phases[currentPhase].duration)
        tomatoRingPosition = Angle(degrees: 360 * progress)
    }

    func toggleTimer() {
        if timerRunning {
            stopTimer()
        } else {
            startTimer()
        }
        timerRunning.toggle()
        saveState()
    }

    func resetCycle() {
        DispatchQueue.main.async {
            self.currentPhase = 0
            self.remainingTime = self.phases[self.currentPhase].duration
            self.cyclePhaseCount = 0
            self.hasSkippedInCurrentCycle = false
            self.isInResetMode = false
            self.stopTimer()
            self.timerRunning = false
            self.isResetState = false
            self.isInDecisionMode = false
            self.isInCooldownMode = false
            self.resetPhaseCompletionStatus()
            self.currentCycleCompleted = false
            self.tomatoRingPosition = .zero
            self.updateTomatoRingPosition()
            WKInterfaceDevice.current().play(.retry)
            self.saveState()
        }
    }

    func checkAndUpdateCompletedCycles() {
        let currentTime = Date().timeIntervalSince1970
        if currentTime - lastCycleCompletionTime >= 86400 {
            completedCycles = 0
            lastCycleCompletionTime = currentTime
            saveState()
        }
    }

    func startTransitionAnimation() {
        isTransitioning = true
        transitionProgress = 0
        
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in  // 修改这行
            self.transitionProgress += 0.05
            if self.transitionProgress >= 1 {
                self.isTransitioning = false
                timer.invalidate()
            }
        }
    }

    func sendNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Pomodoro Completed", comment: "")
        content.body = NSLocalizedString("Great job! You've completed a Pomodoro cycle.", comment: "")
        content.sound = .default
        
        let startAction = UNNotificationAction(identifier: "START", title: NSLocalizedString("Start Next Phase", comment: ""), options: .foreground)
        let ignoreAction = UNNotificationAction(identifier: "IGNORE", title: NSLocalizedString("Ignore", comment: ""), options: .destructive)
        
        let category = UNNotificationCategory(identifier: "TIMER_ENDED", actions: [startAction, ignoreAction], intentIdentifiers: [])
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
        content.categoryIdentifier = "TIMER_ENDED"
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.logger.error("Error sending notification: \(error.localizedDescription)")
            }
        }
    }

    enum PhaseStatus {
        case notStarted, current, normalCompleted, skipped
    }

    struct Phase: Codable {
        let duration: Int
        let name: String
    }
}