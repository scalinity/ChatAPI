import SwiftUI

// MARK: - Design Token System (CodeGarden-inspired)

struct AppTheme {

    // MARK: - Backgrounds
    struct Bg {
        static let primary   = Color(red: 0.047, green: 0.047, blue: 0.047)   // #0c0c0c
        static let secondary = Color(red: 0.086, green: 0.086, blue: 0.086)   // #161616
        static let panel     = Color(red: 0.110, green: 0.110, blue: 0.110)   // #1c1c1c
        static let input     = Color(red: 0.075, green: 0.075, blue: 0.075)   // prompt bar
    }

    // MARK: - Borders
    struct Border {
        static let subtle = Color(red: 0.165, green: 0.165, blue: 0.165)      // #2a2a2a
    }

    // MARK: - Text
    struct Txt {
        static let primary   = Color(red: 0.878, green: 0.878, blue: 0.878)   // #e0e0e0
        static let secondary = Color(red: 0.541, green: 0.541, blue: 0.541)   // #8a8a8a
    }

    // MARK: - Accent (warm amber/gold)
    struct Accent {
        static let primary = Color(red: 0.961, green: 0.620, blue: 0.043)     // #f59e0b
        static let bright  = Color(red: 0.984, green: 0.749, blue: 0.141)     // #fbbf24
        static let dim     = Color(red: 0.706, green: 0.325, blue: 0.035)     // #b45309
    }

    // MARK: - Semantic
    struct Semantic {
        static let success = Color(red: 0.204, green: 0.827, blue: 0.600)     // #34d399
        static let warning = Color(red: 0.976, green: 0.451, blue: 0.086)     // #f97316
        static let error   = Color(red: 0.937, green: 0.267, blue: 0.267)     // #ef4444
        static let info    = Color(red: 0.220, green: 0.741, blue: 0.973)     // #38bdf8
    }

    // MARK: - Message Bubbles
    struct Bubble {
        static let user            = Accent.primary.opacity(0.08)
        static let userBorder      = Accent.dim.opacity(0.35)
        static let assistant       = Bg.secondary
        static let assistantBorder = Border.subtle
    }

    // MARK: - Corner Radii (tight, industrial)
    struct Radius {
        static let xs: CGFloat = 2
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
    }

    // MARK: - Typography
    struct Font {
        static func display(size: CGFloat) -> SwiftUI.Font {
            .system(size: size, weight: .heavy, design: .rounded)
        }
        static func body(size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight)
        }
        static func code(size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        static func sectionLabel(size: CGFloat = 11) -> SwiftUI.Font {
            .system(size: size, weight: .semibold)
        }
    }

    // MARK: - Surface Fills
    struct Surface {
        static let card    = Bg.panel
        static let hover   = Color.white.opacity(0.06)
        static let active  = Accent.dim.opacity(0.25)
        static let codeBox = Bg.primary
    }
}

// MARK: - View Modifiers

struct LeftAccentBorder: ViewModifier {
    var color: Color = AppTheme.Accent.primary
    var width: CGFloat = 3

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: width)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }
}

struct CardStyle: ViewModifier {
    var radius: CGFloat = AppTheme.Radius.md

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(AppTheme.Bg.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.Border.subtle, lineWidth: 1)
            )
    }
}

struct SectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(AppTheme.Font.sectionLabel())
            .foregroundStyle(AppTheme.Txt.secondary)
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

extension View {
    func leftAccentBorder(color: Color = AppTheme.Accent.primary, width: CGFloat = 3) -> some View {
        modifier(LeftAccentBorder(color: color, width: width))
    }
    func cardStyle(radius: CGFloat = AppTheme.Radius.md) -> some View {
        modifier(CardStyle(radius: radius))
    }
    func sectionHeader() -> some View {
        modifier(SectionHeaderStyle())
    }
}
