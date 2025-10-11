//
//  TimerIntents.swift
//  PomoTAPComplication
//
//  Created for Pomo TAP watchOS app
//  AppIntent definitions for interactive widgets
//

import AppIntents
import Foundation
import WatchKit

// MARK: - Toggle Timer Intent
struct ToggleTimerIntent: AppIntent {
    static var title: LocalizedStringResource { "Toggle Timer" }
    static var description: IntentDescription {
        IntentDescription("Start or pause the Pomodoro timer")
    }

    func perform() async throws -> some IntentResult {
        // Open app with toggle action
        // The deep link will be handled by TimerModel
        guard let url = URL(string: "pomoTAP://toggle") else {
            throw IntentError.invalidURL
        }

        // Request app to open with URL
        await MainActor.run {
            // On watchOS, we need to open the app to perform the action
            // The URL will be caught by the app's URL handler
            #if os(watchOS)
            WKExtension.shared().openSystemURL(url)
            #endif
        }

        return .result()
    }
}

// MARK: - Skip Phase Intent (Optional)
struct SkipPhaseIntent: AppIntent {
    static var title: LocalizedStringResource { "Skip Phase" }
    static var description: IntentDescription {
        IntentDescription("Skip to the next Pomodoro phase")
    }

    func perform() async throws -> some IntentResult {
        guard let url = URL(string: "pomoTAP://skipPhase") else {
            throw IntentError.invalidURL
        }

        await MainActor.run {
            #if os(watchOS)
            WKExtension.shared().openSystemURL(url)
            #endif
        }

        return .result()
    }
}

// MARK: - Intent Errors
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidURL
    case actionFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidURL:
            return "Invalid URL scheme"
        case .actionFailed:
            return "Action failed to complete"
        }
    }
}
