import Foundation

/// 固定诊断类别，不携带PID数值、路径、时间、正文或凭据。
public enum DesktopReviewTargetDiagnostic: String, Sendable {
    case applicationUnavailable, applicationTerminated, pidChanged
    case launchDateUnavailable, launchDateChanged
    case bundleIdentifierUnavailable, bundleIdentifierChanged
    case bundlePathUnavailable, bundlePathChanged
    case executablePathUnavailable, executablePathChanged
}

/// 同一次原生查询的可空元数据；不在失败后再查一次来猜测当时缺失的字段。
struct DesktopReviewProcessSnapshot: Sendable {
    var pid: Int32
    var isTerminated: Bool
    var launchTime: Double?
    var bundleIdentifier: String?
    var appPath: String?
    var executablePath: String?
}
extension DesktopReviewProcessSnapshot {
    init(_ identity: DesktopReviewProcessIdentity) {
        self.init(pid: identity.pid, isTerminated: false, launchTime: identity.launchTime,
                  bundleIdentifier: identity.bundleIdentifier, appPath: identity.appPath, executablePath: identity.executablePath)
    }
}

enum DesktopReviewTargetIdentityCheck {
    static func failure(expected: DesktopReviewProcessIdentity, actual: DesktopReviewProcessSnapshot?) -> DesktopReviewTargetDiagnostic? {
        guard let actual else { return .applicationUnavailable }
        guard !actual.isTerminated else { return .applicationTerminated }
        guard actual.pid == expected.pid else { return .pidChanged }
        guard let launch = actual.launchTime, launch.isFinite, launch > 0 else { return .launchDateUnavailable }
        guard launch == expected.launchTime else { return .launchDateChanged }
        guard let id = actual.bundleIdentifier else { return .bundleIdentifierUnavailable }
        guard id == expected.bundleIdentifier else { return .bundleIdentifierChanged }
        guard let path = actual.appPath else { return .bundlePathUnavailable }
        guard path == expected.appPath else { return .bundlePathChanged }
        guard let executable = actual.executablePath else { return .executablePathUnavailable }
        guard executable == expected.executablePath else { return .executablePathChanged }
        return nil
    }
}
