import Foundation
import CommandCore

/// 只由编译期宿主入口选择；外部内容不能注册动作或覆盖执行效果。
enum HostOperation: String, Hashable, Sendable, CaseIterable {
    case openApplication, activateWindow, runCommand, prepareAI, generateText
    case proposeCommand, runReadOnlyAgent, runAgent, copyText, replaceSelection, pasteClipboard, readClipboard, navigate, layoutWindow, importContext, captureScreen, revealFile, openURL
    case applyDesktopWorkspace, discoverModels
    case cycleWindow, minimizeWindow, hideApplication, showApplication, showAllApplicationWindows, quitApplication
}

/// 同一份声明同时供目录展示和真实执行使用，版本、效果与执行引用只在此定义。
enum HostActionCatalog {
    static func operation(for kind: CommandKind) -> HostOperation {
        switch kind {
        case .application: .openApplication
        case .window: .activateWindow
        case .command: .runCommand
        case .ai: .prepareAI
        case .clipboard: .readClipboard
        case .utility: .navigate
        }
    }

    static func descriptor(
        id: String, title: String, keywords: [String] = [], operations: [HostOperation],
        availability: CommandAvailability = .available,
        actionAvailability: [HostOperation: CommandAvailability] = [:]
    ) throws -> CommandDescriptor {
        let actions = try operations.map { operation in
            try action(operation, title: title, availability: actionAvailability[operation] ?? .available)
        }
        return try CommandDescriptor(id: id, version: operations.contains(.layoutWindow) || operations.contains(.openApplication) ? 2 : 1, title: title,
            providerID: "keydock.provider.host", keywords: keywords,
            availability: availability, actions: actions)
    }

    static func action(
        _ operation: HostOperation, title: String, availability: CommandAvailability = .available
    ) throws -> ActionDescriptor {
        let input: CommandValueType
        let output: CommandValueType
        let context: Set<CommandContextRequirement>
        let effects: Set<CommandEffect>
        switch operation {
        case .openURL:
            input = .structuredData; output = .none; context = []; effects = [.network,.activateApplication]
        case .revealFile:
            input = .structuredData; output = .none; context = []; effects = [.activateApplication]
        case .openApplication:
            input = .application; output = .none; context = []; effects = [.activateApplication, .changeApplicationVisibility]
        case .activateWindow:
            input = .window; output = .none; context = [.window]; effects = [.activateWindow]
        case .applyDesktopWorkspace:
            input = .structuredData; output = .none; context = []; effects = [.modifyWindow, .activateApplication, .activateWindow, .changeApplicationVisibility]
        case .layoutWindow, .minimizeWindow:
            input = .window; output = .none; context = [.window]; effects = [.modifyWindow, .activateApplication]
        case .cycleWindow:
            input = .window; output = .none; context = [.window]; effects = [.activateWindow, .activateApplication]
        case .hideApplication:
            input = .application; output = .none; context = []; effects = [.changeApplicationVisibility]
        case .showApplication:
            input = .application; output = .none; context = []; effects = [.changeApplicationVisibility, .activateApplication]
        case .showAllApplicationWindows:
            input = .application; output = .none; context = []; effects = [.changeApplicationVisibility, .activateApplication, .activateWindow]
        case .quitApplication:
            input = .application; output = .none; context = []; effects = [.terminateApplication]
        case .runCommand:
            input = .structuredData; output = .text; context = [.workingDirectory]; effects = [.executeProcess]
        case .prepareAI:
            // 打开输入界面不触发网络，也不要求选区、输入或 API 已配置。
            input = .none; output = .none; context = []; effects = [.read]
        case .generateText:
            input = .text; output = .text; context = [.explicitInput]; effects = [.network]
        case .discoverModels:
            input = .none; output = .structuredData; context = []; effects = [.network]
        case .proposeCommand:
            input = .text; output = .commandProposal; context = [.explicitInput]; effects = [.network]
        case .runReadOnlyAgent, .runAgent:
            // 此动作批准用户发起的模型请求，工具仍由只读 Broker 逐次授权。
            input = .text; output = .text; context = [.explicitInput]; effects = [.network]
        case .copyText:
            input = .text; output = .none; context = []; effects = [.writeClipboard]
        case .replaceSelection:
            input = .text; output = .none; context = [.selection]; effects = [.replaceText]
        case .pasteClipboard:
            input = .text; output = .none; context = [.window, .explicitInput]; effects = [.writeClipboard, .replaceText, .activateApplication]
        case .readClipboard:
            input = .clipboardItem; output = .text; context = [.clipboard]; effects = [.read]
        case .navigate:
            input = .none; output = .none; context = []; effects = [.read]
        case .importContext, .captureScreen:
            input = .structuredData; output = .text; context = [.explicitInput]; effects = [.read]
        }
        return try ActionDescriptor(
            id: "keydock.action." + operation.rawValue, version: operation == .layoutWindow || operation == .openApplication ? 2 : 1, title: title,
            inputType: input, outputType: output, availability: availability,
            requiredContext: context, effects: effects,
            execution: CommandExecutionReference(toolID: "keydock.tool." + operation.rawValue, toolVersion: operation == .layoutWindow || operation == .openApplication ? 2 : 1))
    }
}
