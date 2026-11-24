import SwiftUI

/// 仅对KeyDock自有组件做进程内视觉抽样，不模拟OS原生控件或权限。
public struct KDVisualReviewOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let higherContrast = Self(rawValue: 1 << 0)
    public static let opaqueSurfaces = Self(rawValue: 1 << 1)
    public static let reducedMotion = Self(rawValue: 1 << 2)
    public func increasesContrast(system: ColorSchemeContrast) -> Bool { system == .increased || contains(.higherContrast) }
    public func usesOpaqueSurfaces(system: Bool) -> Bool { system || contains(.opaqueSurfaces) }
    public func reducesMotion(system: Bool) -> Bool { system || contains(.reducedMotion) }
}

public enum KDVisualReviewPreset: Int, CaseIterable, Sendable {
    case system, contrast, opaque, motion, all
    public var options: KDVisualReviewOptions {
        switch self {
        case .system: []
        case .contrast: .higherContrast
        case .opaque: .opaqueSurfaces
        case .motion: .reducedMotion
        case .all: [.higherContrast, .opaqueSurfaces, .reducedMotion]
        }
    }
}

@MainActor public final class KDVisualReviewState: ObservableObject {
    public let allowsChanges: Bool
    @Published public private(set) var preset: KDVisualReviewPreset = .system
    public var options: KDVisualReviewOptions { preset.options }
    public init(previewBuild: Bool = false, isolatedPreview: Bool = false, bundleIdentifier: String? = nil, buildProfile: String? = nil) {
        allowsChanges = previewBuild && isolatedPreview && bundleIdentifier?.hasSuffix(".preview") == true && buildProfile == "preview"
    }
    public func select(_ value: KDVisualReviewPreset) {
        guard allowsChanges else { return }
        preset = value
    }
}

private struct KDVisualReviewKey: EnvironmentKey { static let defaultValue: KDVisualReviewOptions = [] }
extension EnvironmentValues {
    public var kdVisualReview: KDVisualReviewOptions {
        get { self[KDVisualReviewKey.self] }
        set { self[KDVisualReviewKey.self] = newValue }
    }
}

/// 固定宿主壳只发布环境，不以预设重建View或输入控件身份。
public struct KDVisualReviewHost<Content: View>: View {
    @ObservedObject private var review: KDVisualReviewState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private let content: Content
    public init(review: KDVisualReviewState, @ViewBuilder content: () -> Content) { self.review = review; self.content = content() }
    public var body: some View {
        content.environment(\.kdVisualReview, review.options)
            .transaction { if review.options.reducesMotion(system: systemReduceMotion) { $0.animation = nil; $0.disablesAnimations = true } }
    }
}
