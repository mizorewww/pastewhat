import AppKit
import Carbon

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let isDemo = CommandLine.arguments.contains("--demo")
    private lazy var store = ClipboardStore(persist: !isDemo && UserDefaults.standard.bool(forKey: "rememberHistory"))
    private let contextReader = ContextReader()
    private let engine = EngineBridge(configuration: .discover())
    private let hotKey = GlobalHotKey()
    private lazy var panel = ClipboardPanel()
    private lazy var panelController = ClipboardPanelController()
    private var statusItem: NSStatusItem!
    private var settingsController: SettingsController?
    private var context = AppContext()
    private var lastExternalApp: NSRunningApplication?
    private var contextTask: Task<Void, Never>?
    private var rankingTask: Task<Void, Never>?
    private var presentationID = UUID()
    private var requestID: String?
    private var contextReady = false
    private var feedbackTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var outsideMonitor: Any?
    private var demoEntries: [ClipboardEntry] = []
    private var storageStatus: String?
    private var shortcutStatus: String?
    private var terminating = false

    private var entries: [ClipboardEntry] { isDemo ? demoEntries : store.entries }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.register(defaults: ["rememberHistory": true])
        applyAppearance()
        installApplicationMenu()
        panel.contentViewController = panelController
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.panelController.handleKey(event) ?? false }
        panelController.onClose = { [weak self] in self?.closePanel() }
        panelController.onSettings = { [weak self] in self?.showSettings() }
        panelController.onCopy = { [weak self] entry, plain in self?.copy(entry, plainText: plain) }
        panelController.onPaste = { [weak self] entry in self?.paste(entry) }
        panelController.onDelete = { [weak self] entry in self?.delete(entry) }
        panelController.onPause = { [weak self] in self?.togglePause() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "PasteWhat 剪贴板")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "PasteWhat · ⌥⇧V 打开剪贴板"
        }
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.lastExternalApp = app
                if self.panel.isVisible && app.processIdentifier != self.context.processID && !self.isDemo {
                    self.closePanel()
                }
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        store.onChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panelController.setEntries(self.entries)
            self.recommend()
        }
        store.onStatus = { [weak self] message in
            self?.storageStatus = message
            if let message { self?.panelController.setStatus(message) }
        }
        engine.onStatus = { [weak self] message in
            guard let self, self.panel.isVisible else { return }
            self.panelController.setStatus(self.storageStatus ?? message)
        }
        configureHotKey()
        if isDemo {
            demoEntries = DemoContent.entries
            showPanel()
        } else {
            store.start()
            if !UserDefaults.standard.bool(forKey: "hasLaunched") {
                UserDefaults.standard.set(true, forKey: "hasLaunched")
                showPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        rankingTask?.cancel()
        contextTask?.cancel()
        store.stop()
        engine.stop()
        hotKey.unregister()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPanel() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        closePanel()
        store.stop()
        engine.stop()
        Task {
            await store.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置…", action: #selector(settingsMenuClicked), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 PasteWhat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            let menu = NSMenu()
            menu.addItem(withTitle: "打开剪贴板", action: #selector(togglePanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: store.isPaused ? "继续记录" : "暂停记录", action: #selector(pauseMenuClicked), keyEquivalent: "").target = self
            menu.addItem(withTitle: "设置…", action: #selector(settingsMenuClicked), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 PasteWhat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { togglePanel() }
    }

    @objc private func togglePanel() { panel.isVisible ? closePanel() : showPanel() }
    @objc private func settingsMenuClicked() { showSettings() }
    @objc private func pauseMenuClicked() { togglePause() }

    private func showPanel() {
        presentationID = UUID()
        let generation = presentationID
        contextTask?.cancel()
        rankingTask?.cancel()
        requestID = nil
        contextReady = false
        let app = NSWorkspace.shared.frontmostApplication
        let target = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : app
        if isDemo {
            context = DemoContent.context
        } else {
            context = AppContext(appName: target?.localizedName ?? "当前应用", bundleID: target?.bundleIdentifier ?? "",
                                 processID: target?.processIdentifier ?? 0, hasAccessibility: ContextReader.isTrusted)
        }
        panelController.begin(context: context, entries: entries, demo: isDemo)
        panelController.setPaused(store.isPaused)
        panelController.setStatus(storageStatus ?? shortcutStatus ?? (entries.isEmpty ? "等待下一次复制" : "正在读取当前语境…"))
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panelController.focusSearch()
        if isDemo { contextReady = true; recommend(); return }
        guard let target else { contextReady = true; recommend(); return }
        contextTask = Task { [weak self] in
            guard let self else { return }
            let captured = await contextReader.capture(app: target)
            guard !Task.isCancelled, presentationID == generation, panel.isVisible else { return }
            context = captured
            contextReady = true
            panelController.updateContext(captured)
            recommend()
        }
    }

    private func positionPanel() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(780, visible.width), height: min(590, visible.height))
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        if !isDemo, let button = statusItem.button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: min(max(anchor.maxX - size.width, visible.minX), visible.maxX - size.width),
                             y: min(anchor.minY - size.height - 9, visible.maxY - size.height))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func closePanel() {
        presentationID = UUID()
        requestID = nil
        contextTask?.cancel()
        rankingTask?.cancel()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { closePanel() }
    }

    private func recommend() {
        rankingTask?.cancel()
        guard !entries.isEmpty, panel.isVisible, contextReady else { return }
        let id = UUID().uuidString
        requestID = id
        let request = RecommendationRequest(id: id, context: context, entries: entries.prefix(20).map(\.candidate))
        panelController.setStatus(storageStatus ?? "Laya 正在寻找合适的内容…")
        rankingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await engine.rank(request)
                guard !Task.isCancelled, requestID == id, panel.isVisible else { return }
                panelController.setRecommendation(response)
                let modelStatus = response.mode == "laya" ? "Laya · \(engine.configuration.backend.uppercased()) · 已在本机推荐" : (response.message ?? "本地匹配 · Laya 暂不可用")
                panelController.setStatus(storageStatus ?? (store.isPaused ? "记录已暂停 · \(modelStatus)" : modelStatus))
            } catch {
                guard !Task.isCancelled, requestID == id, panel.isVisible else { return }
                panelController.setRecommendation(nil)
                panelController.setStatus(storageStatus ?? "按复制时间排列 · 请在设置中配置 Laya")
            }
        }
    }

    private func copy(_ entry: ClipboardEntry, plainText: Bool) {
        do {
            try store.copy(entry: entry, plainText: plainText)
            panelController.setStatus(plainText ? "已复制纯文本，按 ⌘V 粘贴" : "已复制，按 ⌘V 粘贴")
        } catch { panelController.setStatus("复制失败：\(error.localizedDescription)") }
    }

    private func paste(_ entry: ClipboardEntry) {
        do { try store.copy(entry: entry) }
        catch { panelController.setStatus("复制失败：\(error.localizedDescription)"); return }
        if isDemo { panelController.setStatus("已复制演示内容，按 ⌘V 粘贴"); return }
        if !contextReady {
            panelController.setStatus("已复制，正在确认输入位置；稍后按回车，或手动 ⌘V 粘贴")
            return
        }
        if context.isSecure {
            panelController.setStatus("已复制，安全输入框请按 esc 关闭后手动 ⌘V 粘贴")
            return
        }
        if !ContextReader.isTrusted {
            panelController.setStatus("已复制，按 esc 关闭后 ⌘V 粘贴 · 自动粘贴需辅助功能权限")
            return
        }
        let destination = context
        closePanel()
        Task { [weak self] in
            let message = await PasteController.paste(to: destination)
            if let message {
                self?.showPasteFeedback(message)
            }
        }
    }

    private func showPasteFeedback(_ message: String) {
        panelController.setStatus(message)
        statusItem.button?.toolTip = "PasteWhat · \(message)"
        statusItem.button?.title = " 粘贴未完成"
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.statusItem.button?.title = ""
        }
    }

    private func delete(_ entry: ClipboardEntry) {
        if isDemo {
            demoEntries.removeAll { $0.id == entry.id }
            panelController.setEntries(demoEntries)
            recommend()
        } else { store.remove(id: entry.id) }
    }

    private func togglePause() {
        store.isPaused.toggle()
        panelController.setPaused(store.isPaused)
        if !store.isPaused { panelController.setStatus("正在记录 · 最近 20 条") }
    }

    private func showSettings() {
        closePanel()
        if settingsController == nil {
            let settings = SettingsController(configuration: engine.configuration)
            settings.onSaveEngine = { [weak self] configuration in
                try configuration.save()
                self?.engine.configure(configuration)
            }
            settings.onPersistenceChanged = { [weak self] enabled in self?.store.setPersistenceEnabled(enabled) }
            settings.onShortcutChanged = { [weak self] in self?.configureHotKey() }
            settings.onAppearanceChanged = { [weak self] in self?.applyAppearance() }
            settings.onClearHistory = { [weak self] in
                if self?.isDemo == true { self?.demoEntries = [] } else { self?.store.clear() }
            }
            settingsController = settings
        }
        settingsController?.show()
    }

    private func configureHotKey() {
        let choice = UserDefaults.standard.integer(forKey: "shortcutChoice")
        let captions = ["⌥⇧V", "⌘⇧V", "⌃⌥V", "点击图标"]
        statusItem.button?.toolTip = "PasteWhat · \(captions.indices.contains(choice) ? captions[choice] : captions[0]) 打开剪贴板"
        hotKey.unregister()
        guard choice != 3 else { return }
        let modifiers: UInt32 = choice == 1 ? UInt32(cmdKey | shiftKey) : choice == 2 ? UInt32(controlKey | optionKey) : UInt32(optionKey | shiftKey)
        do {
            try hotKey.register(keyCode: 9, modifiers: modifiers) { [weak self] in self?.togglePanel() }
            shortcutStatus = nil
        } catch { shortcutStatus = "快捷键已被占用，可在设置中更换" }
    }

    private func applyAppearance() {
        let choice = UserDefaults.standard.integer(forKey: "appearanceChoice")
        NSApp.appearance = choice == 1 ? NSAppearance(named: .aqua) : choice == 2 ? NSAppearance(named: .darkAqua) : nil
    }
}
