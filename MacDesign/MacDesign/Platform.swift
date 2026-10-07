import SwiftUI
import TSDKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few places where macOS and iPadOS differ: sounds, haptics, colours and fonts.
enum Platform {
    /// Error sound on the Mac; a warning tap on iPad.
    static func beep() {
        #if os(macOS)
        NSSound.beep()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// The trackpad's alignment click, or the iPad's selection tick.
    static func snapHaptic() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #else
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static var accentColor: CGColor {
        #if os(macOS)
        NSColor.controlAccentColor.cgColor
        #else
        UIColor.tintColor.cgColor
        #endif
    }

    static var accentColorTranslucent: CGColor {
        #if os(macOS)
        NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        #else
        UIColor.tintColor.withAlphaComponent(0.12).cgColor
        #endif
    }

    static var guideColor: CGColor {
        #if os(macOS)
        NSColor.systemPink.cgColor
        #else
        UIColor.systemPink.cgColor
        #endif
    }

    /// Installed font families, for the font pickers.
    static var fontFamilies: [String] {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies.sorted()
        #else
        UIFont.familyNames.sorted()
        #endif
    }

    /// Background for the option cards in sheets.
    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var isPad: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
}

// MARK: - Colour bridging

extension RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    init?(_ color: Color) {
        #if os(macOS)
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red = ns.redComponent, green = ns.greenComponent, blue = ns.blueComponent
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif
        self.init(r: UInt8(max(0, min(255, (red * 255).rounded()))),
                  g: UInt8(max(0, min(255, (green * 255).rounded()))),
                  b: UInt8(max(0, min(255, (blue * 255).rounded()))))
    }
}
