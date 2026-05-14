import SwiftUI

enum Tokens {
    static let bg            = Color(hex: "#060608")
    static let bgDeep        = Color(hex: "#020203")
    static let surface       = Color(white: 1, opacity: 0.04)
    static let surfaceTop    = Color(white: 1, opacity: 0.07)
    static let hairline      = Color(white: 1, opacity: 0.08)
    static let hairlineSoft  = Color(white: 1, opacity: 0.05)
    static let text          = Color(white: 1, opacity: 0.86)
    static let text2         = Color(white: 1, opacity: 0.56)
    static let text3         = Color(white: 1, opacity: 0.32)
    static let text4         = Color(white: 1, opacity: 0.18)
    static let warm          = Color(hex: "#F2EBE0")
    static let accent        = Color(hex: "#A89070")
    static let accentSoft    = Color(red: 168.0 / 255.0, green: 144.0 / 255.0, blue: 112.0 / 255.0, opacity: 0.7)
    static let accentDim     = Color(red: 168.0 / 255.0, green: 144.0 / 255.0, blue: 112.0 / 255.0, opacity: 0.32)
    static let danger        = Color(hex: "#C26A5C")
    static let onAccent      = Color(hex: "#1A150E")

    enum Font {
        static let body              = SwiftUI.Font.system(size: 17, weight: .regular, design: .default)
        static let bodyEmphasized    = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        static let title             = SwiftUI.Font.system(size: 22, weight: .medium, design: .default)
        static let largeTitle        = SwiftUI.Font.system(size: 34, weight: .bold, design: .default)
        static let mono              = SwiftUI.Font.system(size: 13, weight: .regular, design: .monospaced)
        static let monoSmall         = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)

        static let subtitleCurrent   = SwiftUI.Font.system(size: 26, weight: .medium, design: .default)
        static let subtitlePast      = SwiftUI.Font.system(size: 23, weight: .regular, design: .default)
        static let subtitlePastFar   = SwiftUI.Font.system(size: 22, weight: .regular, design: .default)
        static let subtitleFuture    = SwiftUI.Font.system(size: 23, weight: .regular, design: .default)
        static let subtitleFutureFar = SwiftUI.Font.system(size: 22, weight: .regular, design: .default)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }

        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)

        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255.0
            g = Double((value & 0x00FF00) >> 8) / 255.0
            b = Double(value & 0x0000FF) / 255.0
            a = 1.0
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255.0
            g = Double((value & 0x00FF0000) >> 16) / 255.0
            b = Double((value & 0x0000FF00) >> 8) / 255.0
            a = Double(value & 0x000000FF) / 255.0
        default:
            r = 0; g = 0; b = 0; a = 1
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
