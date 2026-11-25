import Foundation
import AICore
import MCPAdapters
import Darwin

/// 只记录未修改的真实wire结果；请求和生命周期完全委托生产transport。
actor RecordedWire: MCPHTTPTransporting {
    let base: any MCPHTTPTransporting
    private var replies: [JSONValue] = []
    init(_ base:any MCPHTTPTransporting) { self.base = base }
    func send(configuration:MCPServerConfiguration,method:String,params:[String:JSONValue],id:Int?,sessionID:String?) async throws -> MCPHTTPReply {
        let reply = try await base.send(configuration:configuration,method:method,params:params,id:id,sessionID:sessionID)
        replies.append(.object(["method":.string(method),"result":.object(reply.result)]))
        return reply
    }
    func disconnect(configuration:MCPServerConfiguration) async { await base.disconnect(configuration:configuration) }
    func snapshot() -> [JSONValue] { replies }
}

enum ProbeError: Error { case usage, failed(String) }
struct Environment: Decodable { let python:String; let workingDirectory:String; let serviceVersion:String; let sdkVersion:String; let lockSHA256:String }

@main struct MCPInteropProbe {
    static func main() async {
        var output: URL?
        var report: [String:JSONValue] = ["status":.string("FAIL")]
        var client: MCPHTTPClient?
        var wire: RecordedWire?
        var process: MCPStdioTransport?
        var http: MCPHTTPTransport?
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count % 2 == 0 else { throw ProbeError.usage }
            var fields: [String:String] = [:]
            for i in stride(from:0,to:arguments.count,by:2) { guard fields[arguments[i]] == nil else { throw ProbeError.usage }; fields[arguments[i]] = arguments[i+1] }
            guard Set(fields.keys).isSubset(of:["--environment","--transport","--protocol","--endpoint","--report","--scenario","--host-script","--marker-dir"]),
                  let path = fields["--environment"], let target = fields["--report"],
                  let kind = fields["--transport"].flatMap(MCPTransportKind.init(rawValue:)),
                  let version = fields["--protocol"].flatMap(MCPProtocolVersion.init(rawValue:)) else { throw ProbeError.usage }
            let environmentURL = URL(fileURLWithPath:path).standardizedFileURL
            let env = try JSONDecoder().decode(Environment.self,from:Data(contentsOf:environmentURL))
            let reportURL = URL(fileURLWithPath:target).standardizedFileURL
            guard reportURL.path.hasPrefix(environmentURL.deletingLastPathComponent().path+"/"), !FileManager.default.fileExists(atPath:reportURL.path) else { throw ProbeError.usage }
            output = reportURL
            let scenario = fields["--scenario"] ?? "time"
            guard ["time","sdk-lifecycle"].contains(scenario) else { throw ProbeError.usage }
            report["scenario"] = .string(scenario)
            report["protocol"] = .string(version.rawValue); report["transport"] = .string(kind.rawValue)
            report["serviceVersion"] = .string(env.serviceVersion); report["sdkVersion"] = .string(env.sdkVersion); report["lockSHA256"] = .string(env.lockSHA256)
            let configuration: MCPServerConfiguration, base: any MCPHTTPTransporting
            if kind == .stdio {
                var launch = ["-I","-B","-u","-X","pycache_prefix="+env.workingDirectory+"/uncached-"+UUID().uuidString]
                if scenario == "sdk-lifecycle" {
                    guard let script = fields["--host-script"], let marker = fields["--marker-dir"] else { throw ProbeError.usage }
                    launch += [script,"--transport","stdio","--marker-dir",marker]
                } else { launch += ["-m","mcp_server_time","--local-timezone=UTC"] }
                configuration = .init(name:"Official SDK interoperability",stdio:.init(executable:env.python,arguments:launch,workingDirectory:env.workingDirectory),enabled:true,protocolVersion:version,timeoutSeconds:5)
                let channel = try MCPStdioTransport(configuration:configuration); process = channel; base = channel
            } else {
                guard let endpoint = fields["--endpoint"].flatMap(URL.init(string:)), endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.path == "/mcp" else { throw ProbeError.usage }
                configuration = .init(name:"Official Time interoperability",endpoint:endpoint,allowsLocalHTTP:true,enabled:true,protocolVersion:version,timeoutSeconds:5)
                let transport = MCPHTTPTransport(); http = transport; base = MCPTransportRouter(http:transport)
            }
            let recording = RecordedWire(base); wire = recording
            let connection = try MCPHTTPClient(configuration:configuration,transport:recording); client = connection
            let catalog = try await connection.discover()
            report["acceptedTools"] = .array(catalog.tools.map { .string($0.originalName) })
            report["rejectedTools"] = .array(catalog.rejectedTools.map { .object(["name":.string($0.originalName),"reason":.string(String(describing:$0.reason))]) })
            let expected: Set<String> = scenario == "time" ? ["get_current_time","convert_time","get_time_ago"] : ["slow","snapshot"]
            guard Set(catalog.tools.map(\.originalName)) == expected, catalog.rejectedTools.isEmpty else { throw ProbeError.failed("The service tool catalog was not fully accepted") }
            if scenario == "sdk-lifecycle" {
                guard let marker = fields["--marker-dir"] else { throw ProbeError.usage }
                report["lifecycle"] = try await lifecycle(connection,catalog:catalog,marker:URL(fileURLWithPath:marker))
            } else {
            var calls: [JSONValue] = []
            func invoke(_ name:String,_ arguments:[String:JSONValue],error expectedError:Bool = false) async throws -> [String:JSONValue] {
                guard let tool = catalog.tools.first(where:{$0.originalName == name}) else { throw ProbeError.failed("Missing tool") }
                let result = try await connection.call(modelToolName:tool.id,arguments:arguments,catalogRevision:catalog.revision)
                calls.append(.object(["name":.string(name),"text":.string(result.text),"structuredContent":result.structuredContent ?? .null,"isError":.bool(result.isError)]))
                guard result.isError == expectedError else { throw ProbeError.failed("Incorrect isError") }
                if expectedError { return [:] }
                let text = try JSONDecoder().decode([String:JSONValue].self,from:Data(result.text.utf8))
                guard result.structuredContent == .object(text) else { throw ProbeError.failed("Text and structuredContent differ") }
                return text
            }
            let start = Date()
            let current = try await invoke("get_current_time",["timezone":.string("UTC")])
            try checkTime(current,between:start.addingTimeInterval(-2)...Date().addingTimeInterval(2))
            let conversion = try await invoke("convert_time",["source_timezone":.string("UTC"),"time":.string("12:00"),"target_timezone":.string("Asia/Tokyo")])
            guard let source = conversion["source"]?.objectValue, let target = conversion["target"]?.objectValue,
                  source["timezone"] == .string("UTC"), target["timezone"] == .string("Asia/Tokyo"),
                  let sourceDate = source["datetime"]?.stringValue.flatMap(parseDate), let targetDate = target["datetime"]?.stringValue.flatMap(parseDate),
                  abs(sourceDate.timeIntervalSince(targetDate)) < 1,
                  source["datetime"]?.stringValue?.contains("T12:00:00") == true,
                  target["datetime"]?.stringValue?.contains("T21:00:00+09:00") == true else { throw ProbeError.failed("Incorrect UTC to Tokyo conversion") }
            let agoStart = Date()
            let ago = try await invoke("get_time_ago",["timezone":.string("UTC"),"hours_ago":.number(1)])
            try checkTime(ago,between:agoStart.addingTimeInterval(-3602)...Date().addingTimeInterval(-3598))
            _ = try await invoke("get_current_time",["timezone":.string("Invalid/Test")],error:true)
            report["calls"] = .array(calls)
            }
            await connection.invalidate()
            do { _ = try await connection.call(modelToolName:catalog.tools[0].id,arguments:[:],catalogRevision:catalog.revision); throw ProbeError.failed("Old catalog remained callable") }
            catch MCPClientError.catalogChanged { report["oldCatalogRejected"] = .bool(true) }
            report["status"] = .string("PASS")
        } catch { report["error"] = .string(String(describing:error)) }
        if let client { await client.invalidate() }
        if let wire { report["wireReplies"] = .array(await wire.snapshot()) }
        if let http {
            let state = await http.diagnostics()
            report["httpCleanup"] = .object(["cancellationAccepted":.number(Double(state.cancellationAccepted)),"cancellationUnconfirmed":.number(Double(state.cancellationUnconfirmed)),"sessionsDeleted":.number(Double(state.sessionsDeleted)),"sessionsAlreadyGone":.number(Double(state.sessionsAlreadyGone)),"deleteUnsupported":.number(Double(state.sessionDeleteUnsupported)),"deleteUnconfirmed":.number(Double(state.sessionDeleteUnconfirmed)),"initializationUnconfirmed":.number(Double(state.initializationUnconfirmed)),"activeOperations":.number(Double(state.activeOperations)),"retainedSessions":.number(Double(state.retainedSessions))])
            if state.activeOperations != 0 || state.retainedSessions != 0 { report["status"] = .string("FAIL") }
        }
        if let process {
            let diagnostics = await process.diagnostics()
            report["processExited"] = .bool(diagnostics.exited); report["forcedTermination"] = .bool(diagnostics.forcedTermination)
            if !diagnostics.exited || diagnostics.forcedTermination { report["status"] = .string("FAIL") }
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            if let output { try encoder.encode(report).write(to:output,options:.withoutOverwriting) }
            let summary = report.filter { ["status","protocol","transport","error","processExited","forcedTermination"].contains($0.key) }
            print(String(decoding:try encoder.encode(summary),as:UTF8.self))
        } catch { fputs("Could not retain interoperability report\n",stderr); exit(2) }
        exit(report["status"] == .string("PASS") ? 0:1)
    }
    static func parseDate(_ value:String) -> Date? {
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return precise.date(from:value) ?? ISO8601DateFormatter().date(from:value)
    }
    static func lifecycle(_ client:MCPHTTPClient,catalog:MCPToolCatalog,marker:URL) async throws -> JSONValue {
        guard let slow = catalog.tools.first(where:{$0.originalName == "slow"}), let snapshot = catalog.tools.first(where:{$0.originalName == "snapshot"}) else { throw ProbeError.usage }
        let task = Task { try await client.call(modelToolName:slow.id,arguments:[:],catalogRevision:catalog.revision) }
        func state() -> [String:Int]? { (try? Data(contentsOf:marker.appendingPathComponent("state.json"))).flatMap { try? JSONDecoder().decode([String:Int].self,from:$0) } }
        do {
            let started = ContinuousClock.now + .seconds(5)
            while state()?["started"] != 1 { guard ContinuousClock.now < started else { throw ProbeError.failed("Slow SDK tool never started") }; try await Task.sleep(for:.milliseconds(10)) }
            task.cancel()
            do { _ = try await task.value; throw ProbeError.failed("Cancelled SDK call returned success") } catch is CancellationError {}
            let deadline = ContinuousClock.now + .seconds(5)
            while state()?["finalized"] != 1 { guard ContinuousClock.now < deadline else { throw ProbeError.failed("SDK tool did not finalize after cancellation") }; try await Task.sleep(for:.milliseconds(10)) }
            guard state()?["completed"] == 0 else { throw ProbeError.failed("Slow tool completed after cancellation") }
            let result = try await client.call(modelToolName:snapshot.id,arguments:[:],catalogRevision:catalog.revision)
            guard !result.isError, result.structuredContent?.objectValue?["started"] == .number(1), result.structuredContent?.objectValue?["finalized"] == .number(1), result.structuredContent?.objectValue?["completed"] == .number(0) else { throw ProbeError.failed("Connection did not remain usable after cancellation") }
            return .object(["started":.number(1),"finalized":.number(1),"completed":.number(0),"connectionStillUsable":.bool(true)])
        } catch { task.cancel(); _ = await task.result; throw error }
    }
    static func checkTime(_ value:[String:JSONValue],between range:ClosedRange<Date>) throws {
        guard value["timezone"] == .string("UTC"), let date = value["datetime"]?.stringValue.flatMap(parseDate), range.contains(date) else { throw ProbeError.failed("Incorrect UTC time") }
    }
}
