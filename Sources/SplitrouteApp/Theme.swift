import AppKit
import CoreText
import SwiftUI

/// Токены из design/app.pen.
enum Theme {
    static let bg = Color(hex: 0x0A0A0A)
    static let surface = Color(hex: 0x141414)
    static let surface2 = Color(hex: 0x1C1C1C)
    static let line = Color(hex: 0x262626)
    static let text = Color(hex: 0xF2F2F2)
    static let text2 = Color(hex: 0x9A9A9A)
    static let text3 = Color(hex: 0x5E5E5E)
    static let lime = Color(hex: 0xC8F542)
    static let violet = Color(hex: 0xA78BFA)
    static let blue = Color(hex: 0x6FA8FF)
    static let coral = Color(hex: 0xFF6B5E)
    static let amber = Color(hex: 0xF5C542)

    /// Цвета туннельных выходов по порядку; «Напрямую» всегда синий, «Блок» — коралловый.
    static let tunnelPalette: [Color] = [lime, violet, Color(hex: 0x4FD1C5), amber, Color(hex: 0xF472B6)]

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Manrope", size: size).weight(weight)
    }

    static let mono = Font.system(size: 12, design: .monospaced)

    /// В .app шрифт подключается через ATSApplicationFontsPath; при `swift run` регистрируем вручную.
    static func registerFonts() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts/Manrope.ttf"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Resources/Fonts/Manrope.ttf").standardized,
        ]
        guard NSFont(name: "Manrope", size: 12) == nil else { return }
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            return
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Format {
    static func bytes(_ b: Int64) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var v = Double(b)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(b) Б" }
        return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        bytes(bytesPerSecond) + "/с"
    }

    static func apps(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "приложение" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "приложения" }
        else { word = "приложений" }
        return "\(n) \(word)"
    }
}
