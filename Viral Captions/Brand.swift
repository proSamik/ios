import SwiftUI

enum Brand {
    static let navy = Color(hex: 0x153592)
    static let cyan = Color(hex: 0x26C9D5)
    static let ink = Color(hex: 0x0F172A)
    static let slate = Color(hex: 0x475569)
    static let muted = Color(hex: 0x64748B)
    static let line = Color(hex: 0xD9E2F2)
    static let surface = Color.white
    static let softSurface = Color(hex: 0xF8FAFC)
    static let glow = Color(hex: 0xE6FAFC)
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var isDisabled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background {
                LiquidGlassSurface(
                    cornerRadius: 8,
                    fill: isDisabled ? Color.gray : Brand.navy,
                    tint: isDisabled ? Brand.line : Brand.cyan,
                    fillOpacity: isDisabled ? 0.32 : 0.95,
                    strokeOpacity: isDisabled ? 0.36 : 0.28,
                    interactive: !isDisabled
                )
            }
            .liquidGlass(cornerRadius: 8, tint: isDisabled ? Brand.line : Brand.cyan, interactive: !isDisabled)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Brand.ink)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background {
                LiquidGlassSurface(
                    cornerRadius: 8,
                    fill: Brand.surface,
                    tint: Brand.cyan,
                    fillOpacity: 0.9,
                    strokeOpacity: 0.24,
                    shadowOpacity: 0.02,
                    interactive: true
                )
            }
            .liquidGlass(cornerRadius: 8, tint: Brand.cyan, interactive: true)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    var content: Content

    init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct LiquidGlassSurface: View {
    var cornerRadius: CGFloat = 8
    var fill: Color = Brand.surface
    var tint: Color = Brand.cyan
    var fillOpacity: Double = 0.9
    var strokeOpacity: Double = 0.24
    var shadowOpacity: Double = 0.04
    var interactive = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        shape
            .fill(fill.opacity(fillOpacity))
            .overlay {
                shape.stroke(tint.opacity(strokeOpacity), lineWidth: 1)
            }
            .shadow(color: Brand.navy.opacity(shadowOpacity), radius: 18, x: 0, y: 8)
    }
}

struct LiquidGlassCapsuleSurface: View {
    var fill: Color = Brand.surface
    var tint: Color = Brand.cyan
    var fillOpacity: Double = 0.9
    var strokeOpacity: Double = 0.24
    var shadowOpacity: Double = 0.02
    var interactive = false

    var body: some View {
        Capsule()
            .fill(fill.opacity(fillOpacity))
            .overlay {
                Capsule().stroke(tint.opacity(strokeOpacity), lineWidth: 1)
            }
            .shadow(color: Brand.navy.opacity(shadowOpacity), radius: 10, x: 0, y: 4)
    }
}

struct BrandCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background {
                LiquidGlassSurface(
                    cornerRadius: 8,
                    fill: Brand.surface,
                    tint: Brand.cyan,
                    fillOpacity: 0.96,
                    strokeOpacity: 0.2,
                    shadowOpacity: 0.025,
                    interactive: false
                )
            }
    }
}

extension View {
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 8, tint: Color = Brand.cyan, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(
                interactive
                    ? .regular.tint(tint.opacity(0.1)).interactive()
                    : .regular.tint(tint.opacity(0.06)),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func liquidGlassCapsule(tint: Color = Brand.cyan, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(
                interactive
                    ? .regular.tint(tint.opacity(0.1)).interactive()
                    : .regular.tint(tint.opacity(0.06)),
                in: .capsule
            )
        } else {
            self
        }
    }
}
