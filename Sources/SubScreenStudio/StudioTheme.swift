import AppKit
import SwiftUI

enum StudioTheme {
    static func chrome(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.075, green: 0.078, blue: 0.095) : Color(red: 0.965, green: 0.969, blue: 0.98)
    }

    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.095, green: 0.10, blue: 0.12) : .white
    }

    static func workspace(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.035, green: 0.038, blue: 0.05) : Color(red: 0.89, green: 0.905, blue: 0.93)
    }

    static func raised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045)
    }

    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.12)
    }
}
