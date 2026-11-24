import AppKit
import SwiftUI

/// hosting view 生命周期固定；系统显示选项仅改变材料参数，避免中断输入法和焦点。
@MainActor public enum KDLauncherSurface {
    public static func make<Content: View>(root: Content, review: KDVisualReviewState? = nil) -> NSView {
        let review = review ?? KDVisualReviewState()
        let hosting = ClearHostingView(rootView: KDVisualReviewHost(review: review) { root.modifier(LauncherMaterialModifier()) })
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }
}

@MainActor private struct LauncherMaterialModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.kdVisualReview) private var review
    private var opaqueSurface: Bool { review.usesOpaqueSurfaces(system: reduceTransparency) }
    private var reducedMotion: Bool { review.reducesMotion(system: reduceMotion) }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.environment(\.kdOnGlassSurface, true)
                // 材料只作用于背景，前景不再由glassEffect包裹。
                .background {
                    RoundedRectangle(cornerRadius: KDTokens.corner, style: .continuous)
                        .fill(opaqueSurface ? Color(nsColor: .windowBackgroundColor) : .clear)
                        .glassEffect(opaqueSurface ? .identity : .regular, in: .rect(cornerRadius: KDTokens.corner))
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: KDTokens.corner, style: .continuous))
                .transaction { transaction in
                    if reducedMotion { transaction.animation = nil; transaction.disablesAnimations = true }
                }
        } else {
            content.environment(\.kdOnGlassSurface, true)
                .background {
                    if opaqueSurface {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        LegacyLauncherMaterial()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: KDTokens.corner, style: .continuous))
                .transaction { transaction in
                    if reducedMotion { transaction.animation = nil; transaction.disablesAnimations = true }
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
