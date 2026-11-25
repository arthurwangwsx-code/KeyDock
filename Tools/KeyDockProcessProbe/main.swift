import Foundation
import Darwin

// 只读指定的同UID进程元数据；不请求task_for_pid、读取argv或控制目标生命周期。
enum ProbeError: String, Error { case invalidArguments, unavailable, wrongOwner, wrongExecutable, notRunning, identityChanged, clockUnavailable }
struct Identity: Encodable, Equatable {
    let pid: Int32
    let uid: UInt32
    let realUID: UInt32
    let startUnixSeconds: UInt64
    let startUnixMicroseconds: UInt64
    let executablePath: String
}
struct Sample: Encodable {
    let schemaVersion = 1
    let kind = "keydock-process-resources"
    let identity: Identity
    let executableUUID: String
    let processStartAbsoluteTicks: UInt64
    let userTimeMachTicks: UInt64
    let systemTimeMachTicks: UInt64
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let absoluteTimeTicks: UInt64
    let continuousTimeTicks: UInt64
    let timebaseNumerator: UInt32
    let timebaseDenominator: UInt32
    let lowPowerMode: Bool
    let thermalState: String
}
func identity(_ pid: Int32) throws -> Identity {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let result = withUnsafeMutableBytes(of: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0.baseAddress, Int32(size)) }
    guard result == size, info.pbi_pid == UInt32(pid) else { throw ProbeError.unavailable }
    guard info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { throw ProbeError.wrongOwner }
    guard info.pbi_status != UInt32(SZOMB) else { throw ProbeError.notRunning }
    // SDK中PROC_PIDPATHINFO_MAXSIZE为4*MAXPATHLEN；复合宏未被Swift importer公开。
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    guard length > 0, length < buffer.count, let path = String(validatingUTF8: buffer), !path.isEmpty else { throw ProbeError.unavailable }
    return .init(pid: pid, uid: info.pbi_uid, realUID: info.pbi_ruid, startUnixSeconds: info.pbi_start_tvsec,
        startUnixMicroseconds: info.pbi_start_tvusec, executablePath: path)
}
func sample(_ pid: Int32, expectedPath: String? = nil) throws -> Sample {
    let before = try identity(pid)
    if let expectedPath, before.executablePath != expectedPath { throw ProbeError.wrongExecutable }
    var usage = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    guard result == 0 else { throw ProbeError.unavailable }
    guard usage.ri_proc_exit_abstime == 0, usage.ri_proc_start_abstime > 0 else { throw ProbeError.notRunning }
    let after = try identity(pid)
    guard before == after else { throw ProbeError.identityChanged }
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 else { throw ProbeError.clockUnavailable }
    let absolute = mach_absolute_time(), continuous = mach_continuous_time()
    let thermal: String
    switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "nominal"; case .fair: thermal = "fair"; case .serious: thermal = "serious"; case .critical: thermal = "critical"; @unknown default: thermal = "unknown" }
    return .init(identity: after, executableUUID: UUID(uuid: usage.ri_uuid).uuidString,
        processStartAbsoluteTicks: usage.ri_proc_start_abstime, userTimeMachTicks: usage.ri_user_time,
        systemTimeMachTicks: usage.ri_system_time, residentBytes: usage.ri_resident_size,
        physicalFootprintBytes: usage.ri_phys_footprint, absoluteTimeTicks: absolute, continuousTimeTicks: continuous,
        timebaseNumerator: timebase.numer, timebaseDenominator: timebase.denom,
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: thermal)
}
struct SelfCheck: Encodable {
    let kind = "keydock-owned-cpu-self-check"
    let before: Sample
    let after: Sample
    let posixCPUSeconds: Double
    let checksum: UInt64
}
func selfCheck() throws -> SelfCheck {
    var first = rusage(), last = rusage()
    guard getrusage(RUSAGE_SELF, &first) == 0 else { throw ProbeError.unavailable }
    let before = try sample(getpid())
    let start = mach_absolute_time()
    let ticks = UInt64(250_000_000 * Double(before.timebaseDenominator) / Double(before.timebaseNumerator))
    var checksum: UInt64 = 1
    while mach_absolute_time() - start < ticks {
        for _ in 0..<5_000 { checksum = checksum &* 6_364_136_223_846_793_005 &+ 1 }
    }
    let after = try sample(getpid())
    guard getrusage(RUSAGE_SELF, &last) == 0 else { throw ProbeError.unavailable }
    let seconds = Double(last.ru_utime.tv_sec - first.ru_utime.tv_sec + last.ru_stime.tv_sec - first.ru_stime.tv_sec)
        + Double(last.ru_utime.tv_usec - first.ru_utime.tv_usec + last.ru_stime.tv_usec - first.ru_stime.tv_usec) / 1_000_000
    return .init(before: before, after: after, posixCPUSeconds: seconds, checksum: checksum)
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if args == ["--self-check"] {
        print(String(decoding: try encoder.encode(selfCheck()), as: UTF8.self)); exit(0)
    }
    if args == ["--self-hold"] {
        // 工程生命周期夹具只等待自己stdin；不接管或终止任何App。
        FileHandle.standardOutput.write(try encoder.encode(sample(getpid())) + Data([10]))
        _ = try FileHandle.standardInput.read(upToCount: 1)
        exit(0)
    }
    let pid: Int32
    let expectedPath: String?
    if args == ["--self"] { pid = getpid(); expectedPath = nil }
    else if args.count == 4, args[0] == "--pid", args[2] == "--executable", !args[3].isEmpty,
            let value = Int32(args[1]), value > 1 { pid = value; expectedPath = args[3] }
    else { throw ProbeError.invalidArguments }
    print(String(decoding: try encoder.encode(sample(pid, expectedPath: expectedPath)), as: UTF8.self))
} catch {
    // 固定错误类别，不把路径、进程名或系统错误正文写入失败日志。
    let reason = (error as? ProbeError)?.rawValue ?? "unavailable"
    print("{\"schemaVersion\":1,\"kind\":\"keydock-process-resources\",\"state\":\"unavailable\",\"reason\":\"" + reason + "\"}")
    exit(1)
}
