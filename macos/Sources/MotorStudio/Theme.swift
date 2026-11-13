import SwiftUI

enum StudioTheme {
    static let mint = Color(red: 0.46, green: 0.94, blue: 0.80)
    static let lavender = Color(red: 0.69, green: 0.66, blue: 1)
    static let blue = Color(red: 0.43, green: 0.72, blue: 1)
}

struct StudioBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.045, green: 0.06, blue: 0.08)
                Ellipse().fill(StudioTheme.mint.opacity(0.13))
                    .frame(width: geometry.size.width * 0.8, height: 560)
                    .blur(radius: 120).offset(x: 170, y: -260)
                Ellipse().fill(StudioTheme.lavender.opacity(0.15))
                    .frame(width: 600, height: 600)
                    .blur(radius: 140).offset(x: -300, y: 300)
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            }
        }.ignoresSafeArea()
    }
}

private struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(red: 0.12, green: 0.15, blue: 0.17), in: RoundedRectangle(cornerRadius: radius))
        } else {
            modern(content)
        }
    }
    @ViewBuilder private func modern(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular,
                                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else { fallback(content) }
        #else
        fallback(content)
        #endif
    }
    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.025), .white.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
    }
}

extension View {
    func studioGlass(radius: CGFloat = 22, interactive: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, interactive: interactive))
    }
}

struct Panel<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let content: Content
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if let subtitle { Text(subtitle).font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary) }
            }
            content
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).studioGlass()
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = StudioTheme.mint
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color.opacity(0.7), radius: 5)
            Text(title).font(.system(size: 11, weight: .medium))
        }.padding(.horizontal, 12).padding(.vertical, 7)
            .background(color.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.2), lineWidth: 0.7))
    }
}

struct ActionStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white.opacity(0.9))
            .background(fill.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 0.8))
            .opacity(enabled ? 1 : 0.35)
    }
    private var fill: Color {
        destructive ? .red.opacity(0.7) : prominent ? StudioTheme.mint : .white.opacity(0.075)
    }
}
