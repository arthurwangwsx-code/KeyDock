import AppKit
import Foundation
import Security

/// 参数只选择签名元数据许可的会话，不能从命令行扩展宿主或数据目录。
public struct DesktopReviewLaunch: Sendable {
    public let root: URL
    public let binding: DesktopReviewBuildBinding
    @MainActor public static func parse(arguments: [String], bundleIdentifier: String?, safeSmoke: Bool,
                             metadata: Data, infoCommit: String?) throws -> Self {
        guard arguments.count == 3, arguments[1] == "--desktop-review-root",
              bundleIdentifier == DesktopReviewScope.bundleIdentifier, safeSmoke,
              metadata.count <= 65_536,
              let info = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              info["profile"] as? String == "desktop-review", info["architecture"] as? String == "arm64",
              let source = info["source"] as? [String: Any], source["dirty"] as? Bool == false,
              let commit = source["commit"] as? String, commit == infoCommit,
              commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let object = info["desktopReview"] as? [String: Any],
              Set(object.keys) == ["rootParent", "reviewBundleIdentifier", "fixtureBundleIdentifier", "fixtureAppPath", "fixtureBinarySHA256", "fixtureInfoSHA256"] else { throw DesktopReviewError.invalidScope }
        let binding = try JSONDecoder().decode(DesktopReviewBuildBinding.self, from: JSONSerialization.data(withJSONObject: object))
        guard binding.reviewBundleIdentifier == DesktopReviewScope.bundleIdentifier,
              binding.fixtureBundleIdentifier == DesktopReviewScope.fixtureBundleIdentifier,
              arguments[2].hasPrefix("/"), arguments[2].utf8.count <= 4096,
              !arguments[2].split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw DesktopReviewError.invalidScope }
        return Self(root: URL(fileURLWithPath: arguments[2], isDirectory: true), binding: binding)
    }
    @MainActor public static func current() throws -> Self {
        let bundle = Bundle.main
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              let url = bundle.url(forResource: "BuildInfo", withExtension: "json") else { throw DesktopReviewError.invalidScope }
        return try parse(arguments: ProcessInfo.processInfo.arguments, bundleIdentifier: bundle.bundleIdentifier,
                         safeSmoke: bundle.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true,
                         metadata: Data(contentsOf: url), infoCommit: bundle.object(forInfoDictionaryKey: "KeyDockGitCommit") as? String)
    }
}
