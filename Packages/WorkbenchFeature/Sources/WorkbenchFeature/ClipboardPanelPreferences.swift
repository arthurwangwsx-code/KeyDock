import Combine
import CryptoKit
import Foundation
import CommandCore
import MacAdapters

public enum ClipboardPrimaryAction: String, CaseIterable, Sendable {
    case insert, copy
    public var alternate: Self { self == .insert ? .copy : .insert }
    public var title: String { self == .insert ? L("Insert") : L("Copy") }
}

extension ClipboardSeparator {
    var title: String { switch self { case .newline: L("New line"); case .blankLine: L("Blank line"); case .space: L("Space"); case .none: L("No separator") } }
}

/// 仅保存两项无正文的界面偏好；独立于旧版本会重写的configuration.json。
@MainActor public final class ClipboardPanelPreferences: ObservableObject {
    @Published public var primaryAction: ClipboardPrimaryAction {
        didSet { defaults.set(primaryAction.rawValue, forKey: "clipboard.panel.primaryAction"); revision = UUID() }
    }
    @Published public var separator: ClipboardSeparator {
        didSet { defaults.set(separator.rawValue, forKey: "clipboard.panel.separator"); revision = UUID() }
    }
    @Published private(set) var revision = UUID()
    private let defaults: UserDefaults
    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, reviewDirectory: nil)
    }
    let reviewDirectory: URL?
    private init(defaults: UserDefaults, reviewDirectory: URL?) {
        self.defaults = defaults
        self.reviewDirectory = reviewDirectory
        primaryAction = defaults.string(forKey: "clipboard.panel.primaryAction").map { ClipboardPrimaryAction(rawValue: $0) ?? .copy } ?? .insert
        separator = defaults.string(forKey: "clipboard.panel.separator").flatMap(ClipboardSeparator.init(rawValue:)) ?? .newline
    }
    static func desktopReviewSuiteName(_ directory: URL) -> String {
        let hash = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return DesktopReviewScope.bundleIdentifier + ".preferences." + hash
    }
    static func desktopReview(directory: URL) throws -> ClipboardPanelPreferences {
        guard let defaults = UserDefaults(suiteName: desktopReviewSuiteName(directory)) else { throw DesktopReviewError.invalidScope }
        if let raw = defaults.object(forKey: "clipboard.panel.primaryAction") {
            guard let value = raw as? String, ClipboardPrimaryAction(rawValue: value) != nil else { throw DesktopReviewError.invalidScope }
        }
        if let raw = defaults.object(forKey: "clipboard.panel.separator") {
            guard let value = raw as? String, ClipboardSeparator(rawValue: value) != nil else { throw DesktopReviewError.invalidScope }
        }
        return .init(defaults: defaults, reviewDirectory: directory)
    }
}
