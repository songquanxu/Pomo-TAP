//
//  WristStateManager.swift
//  Pomo TAP Watch App
//
//  Created by Claude Code on 2025/10/05.
//

import SwiftUI
import WatchKit

// MARK: - 抬腕状态管理器
class WristStateManager: NSObject, ObservableObject {
    @Published var isWristRaised = true

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willActivate),
            name: WKApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didDeactivate),
            name: WKApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func willActivate() {
        DispatchQueue.main.async {
            self.isWristRaised = true
        }
    }

    @objc private func didDeactivate() {
        DispatchQueue.main.async {
            self.isWristRaised = false
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
