import AppKit
import SwiftUI

public enum KDTokens {
    public static let launcherWidth: CGFloat = 680
    public static let launcherHeight: CGFloat = 440
    public static let corner: CGFloat = 24
    public static let rowHeight: CGFloat = 50
    public static let space: CGFloat = 16
}

public enum KDLocalizer {
    private static var preferenceKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) ? "KeyDock.Smoke.Language" : "KeyDock.Language"
    }
    public static var language: String { UserDefaults.standard.string(forKey: preferenceKey) ?? "system" }
    public static func setLanguage(_ language: String) { UserDefaults.standard.set(language, forKey: preferenceKey) }
    public static var locale: Locale { language == "system" ? .current : Locale(identifier: language) }
    public static func string(_ key: String, bundle: Bundle) -> String {
        if language != "system", let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) {
            return localized.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

public struct KDKeycap: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.07), lineWidth: 0.5))
    }
}

public struct KDIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    public init(_ symbol: String, label: String, action: @escaping () -> Void) { self.symbol = symbol; self.label = label; self.action = action }
    public var body: some View {
        Group {
            if #available(macOS 26, *) {
                Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 27, height: 27) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
            } else {
                Button(action: action) { Image(systemName: symbol).frame(width: 27, height: 27) }.buttonStyle(.borderless)
            }
        }.help(label).accessibilityLabel(label)
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
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

public struct KDInlineNotice: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View { Label(text, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
}

public struct KDCommandRow: View {
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
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            if selected { KDKeycap("↩") }
            else { Text(category).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 12).frame(height: KDTokens.rowHeight)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
