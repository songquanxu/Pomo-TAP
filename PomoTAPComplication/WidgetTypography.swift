//
//  WidgetTypography.swift
//  PomoTAPComplication
//
//  Typography standards following Apple HIG for watchOS widgets
//

import SwiftUI

// MARK: - Widget Typography Standards (Apple HIG)
struct WidgetTypography {
    // MARK: - Accessory Circular
    struct Circular {
        static let icon = Font.system(size: 20, weight: .medium)
        static let iconSmall = Font.system(size: 16, weight: .medium)
    }

    // MARK: - Accessory Rectangular
    struct Rectangular {
        static let title = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 17, weight: .semibold, design: .rounded)
        static let caption = Font.system(size: 13, weight: .regular)
        static let largeNumber = Font.system(size: 26, weight: .bold, design: .rounded)
    }

    // MARK: - Accessory Inline
    struct Inline {
        static let text = Font.system(size: 15, weight: .regular, design: .rounded)
        static let textSemibold = Font.system(size: 15, weight: .semibold, design: .rounded)
    }

    // MARK: - Accessory Corner
    struct Corner {
        static let icon = Font.system(size: 12, weight: .medium)
        static let label = Font.system(size: 13, weight: .regular, design: .rounded)
    }

    // MARK: - Smart Stack Rectangular
    struct SmartStack {
        static let title = Font.system(size: 13, weight: .semibold)
        static let time = Font.system(size: 15, weight: .medium, design: .rounded)
    }
}
