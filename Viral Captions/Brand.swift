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
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isDisabled ? Color.gray.opacity(0.32) : Brand.navy)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isDisabled ? Brand.line : Brand.navy, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            LiquidGlassSurface(cornerRadius: 8, tint: Brand.cyan, interactive: true)
                .allowsHitTesting(false)
                .zIndex(0)

            configuration.label
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.ink)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .zIndex(1)
        }
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct LiquidGlassSurface: View {
    var cornerRadius: CGFloat = 8
    var tint: Color = Brand.cyan
    var interactive = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            shape
                .fill(Brand.surface.opacity(0.86))
                .glassEffect(
                    interactive
                        ? .regular.tint(tint.opacity(0.08)).interactive()
                        : .regular.tint(tint.opacity(0.05)),
                    in: shape
                )
                .overlay {
                    shape.stroke(tint.opacity(0.24), lineWidth: 1)
                }
        } else {
            shape
                .fill(Brand.surface)
                .overlay {
                    shape.stroke(Brand.line, lineWidth: 1)
                }
        }
    }
}

struct BrandCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            LiquidGlassSurface(cornerRadius: 8, tint: Brand.cyan, interactive: false)
                .allowsHitTesting(false)
                .zIndex(0)

            Brand.surface.opacity(0.28)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .allowsHitTesting(false)
                .zIndex(0.5)

            content
                .padding(18)
                .zIndex(1)
        }
    }
}
