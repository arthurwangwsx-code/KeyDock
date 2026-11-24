import Foundation
import Testing
import Darwin
import AICore
import AgentCore
import ExecutionCore

@Suite(.serialized,.timeLimit(.minutes(1))) struct AgentProcessDrainTests {
    @Test func cancelledToolWaitsForOwnedProcessReapingBeforeClosing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-agent-drain-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let marker = dir.appendingPathComponent("owned.pid")
        // 合成进程忽略TERM，验证ProcessRunner最终回收后才解除父运行容量。
        let command = SavedCommand(name:"Owned cancellation fixture",executable:"/bin/sh",arguments:["-c","trap '' TERM; printf '%s' \"$$\" > owned.pid; while :; do /bin/sleep 1; done"],workingDirectory:dir.path,timeout:30)
        let runner = ProcessRunner(), journal = try InvocationStore(directory:dir.appendingPathComponent("receipts"))
        let tool = try SavedCommandAITool.make(command:command,resourceFingerprint:"owned-process",runner:runner)
        let broker = try ScopedToolBroker(runID:UUID(),tools:[tool],journal:journal) { _ in true }
        let name = tool.definition.name
        let operation = Task { try await broker.invoke(.init(id:"owned-call",name:name,arguments:"{}"),allowed:[name]) }
        do {
        for _ in 0..<300 { if FileManager.default.fileExists(atPath:marker.path) { break }; try await Task.sleep(for:.milliseconds(10)) }
        let pidText = try String(contentsOf:marker,encoding:.utf8), pid = try #require(Int32(pidText))
        operation.cancel(); await broker.close(cancel:true)
        if case .success = await operation.result { Issue.record("Cancelled process unexpectedly succeeded") }
        #expect(kill(pid,0) == -1 && errno == ESRCH)
        #expect(await journal.list().first?.state == .interrupted)
        #expect(await broker.unknownInvocationCount() == 1)
        } catch { operation.cancel(); await broker.close(cancel:true); throw error }
    }
}
