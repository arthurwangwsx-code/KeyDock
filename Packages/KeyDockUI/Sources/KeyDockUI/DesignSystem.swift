import AppKit
import SwiftUI

public enum KDTokens {
    public static let launcherWidth: CGFloat = 680
    public static let launcherHeight: CGFloat = 456
    public static let launcherNoticeHeight: CGFloat = 56
    public static let corner: CGFloat = 24
    public static let rowHeight: CGFloat = 50
    public static let space: CGFloat = 16
    public static let searchHeight: CGFloat = 72
    public static let footerHeight: CGFloat = 44
    public static let controlSize: CGFloat = 30
    public static let contentInset: CGFloat = 24
    public static let rowCorner: CGFloat = 12

    public enum Typography {
        public static var search: Font { .system(size: 22) }
        public static var title: Font { .system(size: 13, weight: .medium) }
        public static var detail: Font { .system(size: 11) }
        public static var caption: Font { .system(size: 11, weight: .medium) }
    }
}

public enum KDLocalizer {
    private static var preferenceKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) ? "KeyDock.Smoke.Language" : "KeyDock.Language"
    }
    public static var language: String { UserDefaults.standard.string(forKey: preferenceKey) ?? "system" }
    public static func setLanguage(_ language: String) {
        UserDefaults.standard.set(["system", "en", "zh-Hans"].contains(language) ? language : "system", forKey: preferenceKey)
    }
    /// 各 bundle、菜单和 SwiftUI 环境使用同一个受支持语言；系统语言在下次启动时重新解析。
    public static func resolveLanguage(preference: String, preferredLanguages: [String]) -> String {
        if ["en", "zh-Hans"].contains(preference) { return preference }
        return Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferredLanguages).first ?? "en"
    }
    private static let systemLanguage = resolveLanguage(preference: "system", preferredLanguages: Locale.preferredLanguages)
    public static var resolvedLanguage: String { ["en", "zh-Hans"].contains(language) ? language : systemLanguage }
    public static var locale: Locale { Locale(identifier: resolvedLanguage) }
    public static func string(_ key: String, bundle: Bundle) -> String {
        if let path = bundle.path(forResource: resolvedLanguage, ofType: "lproj"), let localized = Bundle(path: path) {
            return localized.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

public struct KDKeycap: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.kdVisualReview) private var review
    private var highContrast: Bool { review.increasesContrast(system: contrast) }
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(highContrast ? .primary : .secondary).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.primary.opacity(highContrast ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(highContrast ? 0.45 : 0.12), lineWidth: highContrast ? 1 : 0.5))
    }
}

private struct KDOnGlassSurfaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var kdOnGlassSurface: Bool {
        get { self[KDOnGlassSurfaceKey.self] }
        set { self[KDOnGlassSurfaceKey.self] = newValue }
    }
}

public enum KDIconButtonStyle { case automatic, toolbar }

public struct KDIconButton: View {
    @Environment(\.kdOnGlassSurface) private var onGlassSurface
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.kdVisualReview) private var review
    let symbol: String
    let label: String
    let style: KDIconButtonStyle
    let role: ButtonRole?
    let action: () -> Void
    public init(_ symbol: String, label: String, style: KDIconButtonStyle = .automatic, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.style = style; self.role = role; self.action = action
    }
    private var button: some View {
        Button(role: role, action: action) {
            Label(label, systemImage: symbol).labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .frame(width: KDTokens.controlSize, height: KDTokens.controlSize)
                .contentShape(Rectangle())
        }
    }
    public var body: some View {
        Group {
            if style == .toolbar { button }
            else if onGlassSurface { button.buttonStyle(.borderless) }
            else if review.usesOpaqueSurfaces(system: reduceTransparency) { button.buttonStyle(.bordered).buttonBorderShape(.circle) }
            else if #available(macOS 26, *) {
                button.buttonStyle(.glass).buttonBorderShape(.circle)
            } else {
                button.buttonStyle(.borderless)
            }
        }.help(label).accessibilityLabel(label)
    }
}

public struct KDKeyboardHint: View {
    let keys: String
    let label: String
    public init(_ keys: String, label: String) { self.keys = keys; self.label = label }
    public var body: some View {
        HStack(spacing: 5) { KDKeycap(keys); Text(label).font(KDTokens.Typography.detail).foregroundStyle(.secondary) }
            .accessibilityElement(children: .ignore).accessibilityLabel(label + ", " + keys)
    }
}

public struct KDResultSectionHeader: View {
    let title: String
    let count: Int?
    public init(_ title: String, count: Int? = nil) { self.title = title; self.count = count }
    public var body: some View {
        HStack {
            Text(title).font(KDTokens.Typography.caption)
            Spacer()
            if let count { Text(count, format: .number).font(KDTokens.Typography.detail).monospacedDigit() }
        }.foregroundStyle(.secondary).padding(.horizontal, KDTokens.contentInset)
            .frame(height: 28).accessibilityAddTraits(.isHeader)
    }
}

/// 正文层保持系统阅读背景；不在玻璃之上再叠一层玻璃。
public struct KDReadingSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.kdVisualReview) private var review
    private var highContrast: Bool { review.increasesContrast(system: contrast) }
    public init() {}
    public func body(content: Content) -> some View {
        content.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: KDTokens.rowCorner))
            .overlay(RoundedRectangle(cornerRadius: KDTokens.rowCorner).stroke(.primary.opacity(highContrast ? 0.4 : 0.08), lineWidth: highContrast ? 1 : 0.5))
    }
}

public struct KDEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    public init(symbol: String, title: String, detail: String) { self.symbol = symbol; self.title = title; self.detail = detail }
    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

public struct KDInlineNotice: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View { Label(text, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
}

public struct KDCommandRow: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.kdVisualReview) private var review
    private var highContrast: Bool { review.increasesContrast(system: contrast) }
    let icon: NSImage?
    let symbol: String
    let title: String
    let subtitle: String
    let category: String
    let selected: Bool
    public init(icon: NSImage? = nil, symbol: String, title: String, subtitle: String, category: String, selected: Bool) {
        self.icon = icon; self.symbol = symbol; self.title = title; self.subtitle = subtitle; self.category = category; self.selected = selected
    }
    public var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: symbol).font(.system(size: 21, weight: .regular)).foregroundStyle(.secondary) }
            }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(KDTokens.Typography.title).foregroundStyle(.primary).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(KDTokens.Typography.detail).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            if selected { KDKeycap("↩") }
            else { Text(category).font(KDTokens.Typography.detail).foregroundStyle(.secondary) }
        }.padding(.horizontal, 12).frame(height: KDTokens.rowHeight)
            .background(selected ? Color.accentColor.opacity(highContrast ? 0.28 : 0.14) : .clear, in: RoundedRectangle(cornerRadius: KDTokens.rowCorner))
            .overlay(RoundedRectangle(cornerRadius: KDTokens.rowCorner).stroke(selected ? Color.accentColor.opacity(highContrast ? 0.9 : 0.24) : .clear, lineWidth: highContrast ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: KDTokens.rowCorner))
    }
}
