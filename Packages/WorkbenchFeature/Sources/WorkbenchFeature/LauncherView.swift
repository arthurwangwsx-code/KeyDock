import AppKit
import SwiftUI
import CommandCore
import KeyDockUI

public struct LauncherView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: LauncherSession
    @State private var pointerPosition = NSEvent.mouseLocation
    public init(store: WorkbenchModel, session: LauncherSession) { self.store = store; self.session = session }
    public var body: some View {
        Group {
            if let draft = session.draft { AIContentView(store: store, draft: draft, compact: true, onBack: { session.reset() }) }
            else { search }
        }.frame(width: KDTokens.launcherWidth, height: KDTokens.launcherHeight)
            .environment(\.locale, KDLocalizer.locale)
            .onAppear { pointerPosition = NSEvent.mouseLocation }
    }
    private var search: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                KDSearchField(text: $session.query, focusRequest: session.focusRequest, placeholder: L("Search apps, windows, or actions"), onMove: session.move, onSubmit: session.execute, onCancel: {
                    if session.actionsVisible { session.actionsVisible = false } else { store.onDismiss?(true) }
                }).frame(height: 34)
                if session.contextCapturePending { ProgressView().controlSize(.small) }
                KDKeycap("esc")
            }.padding(.horizontal, 24).frame(height: 72)
            Divider().opacity(0.55)
            HStack {
                Text(session.query.isEmpty ? L("Suggestions") : L("Results")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).tracking(0.7)
                Spacer()
                if !session.query.isEmpty { Text("\(session.results.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 25).frame(height: 25)
            if session.results.isEmpty {
                KDEmptyState(symbol: "magnifyingglass", title: L("No matching actions"), detail: L("Try an application name, a saved command, or an AI action."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(session.results) { item in
                                resultRow(item)
                            }
                        }.padding(.horizontal, 12).padding(.bottom, 5)
                    // 悬停只改变选择；若它也触发滚动，静止鼠标会不断命中新行并造成连续跳动。
                    }.scrollIndicators(.hidden).onChange(of: session.selectionScrollRequest) { _, _ in
                        // 滚动造成的 mouse-enter 不能覆盖刚发生的键盘选择。
                        pointerPosition = NSEvent.mouseLocation
                        if let id = session.selectedID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            if !store.applicationIndexNotice.isEmpty { KDInlineNotice(store.applicationIndexNotice).lineLimit(2) }
            if store.shortcutsUnavailable { KDInlineNotice(L("Shortcuts are inactive. Choose another shortcut or retry registration.")).lineLimit(2) }
            if !store.launcherNotice.isEmpty { KDInlineNotice(store.launcherNotice).lineLimit(2) }
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                Button { store.onOpenSettings?(nil) } label: { Image(systemName: "gearshape").font(.system(size: 13)) }.buttonStyle(.plain).help(L("Settings")).keyboardShortcut(",", modifiers: .command)
                Button { store.onOpenWorkspace?(.tasks(nil)) } label: {
                    HStack(spacing: 5) { Image(systemName: "rectangle.stack"); if store.tasks.contains(where: \.isRunning) { Text("\(store.tasks.filter(\.isRunning).count)").font(.system(size: 10, design: .monospaced)) } }
                }.buttonStyle(.plain).help(L("Running tasks"))
                Spacer()
                KDKeycap("↑↓"); Text(L("Select")).font(.system(size: 10)).foregroundStyle(.secondary)
                KDKeycap("↩"); Text(session.selection.map { primaryAction($0.kind) } ?? L("Open")).font(.system(size: 10)).foregroundStyle(.secondary)
                Button { session.actionsVisible.toggle() } label: { HStack(spacing: 5) { Text(L("Actions")).font(.system(size: 10)); KDKeycap("⌘K") } }.buttonStyle(.plain).keyboardShortcut("k", modifiers: .command)
                    .popover(isPresented: $session.actionsVisible, arrowEdge: .bottom) { actionMenu }
            }.foregroundStyle(.secondary).padding(.horizontal, 22).frame(height: 36)
        }
    }
    private func resultRow(_ item: CommandItem) -> some View {
        let icon: NSImage? = item.kind == .application ? NSWorkspace.shared.icon(forFile: item.payload) : nil
        let spoken = [item.title, category(item.kind), item.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        return Button { session.selectedID = item.id; session.execute() } label: {
            KDCommandRow(icon: icon, symbol: symbol(item.kind), title: item.title, subtitle: subtitle(item), category: category(item.kind), selected: item.id == session.selectedID)
        }.buttonStyle(.plain).id(item.id)
            .onHover { hovering in
                let position = NSEvent.mouseLocation
                if hovering, position != pointerPosition { pointerPosition = position; session.selectedID = item.id }
            }
            .accessibilityLabel(Text(spoken))
            .accessibilityAddTraits(item.id == session.selectedID ? .isSelected : [])
    }
    private var actionMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = session.selection {
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).padding(.bottom, 3)
                Button(primaryAction(item.kind)) { session.actionsVisible = false; session.execute() }
                Button(store.configuration.preferences.favorites.contains(item.id) ? L("Remove favorite") : L("Add favorite")) { store.toggleFavorite(item); session.actionsVisible = false }
                Divider()
                Button(L("Edit shortcuts and aliases")) { session.actionsVisible = false; store.onOpenSettings?(.shortcuts) }
            }
        }.buttonStyle(.borderless).padding(16).frame(width: 245, alignment: .leading)
    }
    private func primaryAction(_ kind: CommandKind) -> String { switch kind { case .command, .ai: L("Run"); case .window: L("Switch"); default: L("Open") } }
    private func subtitle(_ item: CommandItem) -> String {
        if item.kind == .application {
            let copies = session.results.lazy.filter { $0.kind == .application && $0.title.localizedCaseInsensitiveCompare(item.title) == .orderedSame }.prefix(2).count
            return copies > 1 ? item.subtitle : L("Application")
        }
        if item.kind == .command { return item.subtitle.split(separator: "/").last.map(String.init) ?? item.subtitle }
        return item.subtitle
    }
    private func category(_ kind: CommandKind) -> String { switch kind { case .application: L("App"); case .window: L("Window"); case .command: L("Command"); case .clipboard: L("Clipboard"); case .ai: L("AI"); case .utility: L("Tool") } }
    private func symbol(_ kind: CommandKind) -> String { switch kind { case .application: "app"; case .window: "macwindow"; case .command: "terminal"; case .clipboard: "clipboard"; case .ai: "sparkles"; case .utility: "square.grid.2x2" } }
}
