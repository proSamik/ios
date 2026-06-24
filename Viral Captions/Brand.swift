import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Brand {
    static let navy = Color(hex: 0x153592)
    static let cyan = Color(hex: 0x26C9D5)
    static let ink = Color.primary
    static let slate = Color.secondary
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.14)

    #if os(macOS)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let softSurface = Color(nsColor: .windowBackgroundColor)
    #else
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let softSurface = Color(uiColor: .systemBackground)
    #endif
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

struct BrandCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LiquidGlassGroup(spacing: 18) {
            content
                .padding(18)
                .nativeGlassPanel(cornerRadius: 8)
        }
    }
}

extension View {
    @ViewBuilder
    func nativeGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    func nativeGlassPanel(cornerRadius: CGFloat = 8, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if interactive {
                self
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(Brand.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func nativeGlassCapsule(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if interactive {
                self
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                self
                    .glassEffect(.regular, in: .capsule)
            }
        } else {
            self
                .background(Brand.surface.opacity(0.88), in: Capsule())
                .overlay {
                    Capsule().stroke(.quaternary, lineWidth: 1)
                }
        }
    }

    func brandedInputField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .nativeGlassPanel(cornerRadius: 7, interactive: true)
    }
}
