import AppKit
import SwiftUI

/// hosting view 生命周期固定；系统显示选项仅改变材料参数，避免中断输入法和焦点。
@MainActor public enum KDLauncherSurface {
    public static func make<Content: View>(root: Content) -> NSView {
        let hosting = ClearHostingView(rootView: root.modifier(LauncherMaterialModifier()))
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }
}

@MainActor private struct LauncherMaterialModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                // 保留动态 NSColor，由 SwiftUI 随有效外观重新解析；不冻结成 CGColor。
                .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear)
                .glassEffect(
                    reduceTransparency ? .identity : .regular.interactive(!reduceMotion),
                    in: .rect(cornerRadius: KDTokens.corner)
                )
                .clipShape(RoundedRectangle(cornerRadius: KDTokens.corner, style: .continuous))
                .transaction { transaction in
                    if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
                }
        } else {
            content
                .background {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        LegacyLauncherMaterial()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: KDTokens.corner, style: .continuous))
                .transaction { transaction in
                    if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
                }
        }
    }
}

@MainActor private struct LegacyLauncherMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // 系统标准材料自行响应有效外观；前景输入控件不会因材料变化被移除。
    }
}

@MainActor private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
