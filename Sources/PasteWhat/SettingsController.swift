import AppKit
import ServiceManagement

@MainActor
final class SettingsController: NSWindowController {
    var onSaveEngine: ((EngineConfiguration) throws -> Void)?
    var onPersistenceChanged: ((Bool) -> Void)?
    var onShortcutChanged: (() -> Void)?
    var onAppearanceChanged: (() -> Void)?
    var onClearHistory: (() -> Void)?
    private let backend = NSPopUpButton()
    private let pythonField = NSTextField()
    private let modelField = NSTextField()
    private let persist = NSButton(checkboxWithTitle: "在本机保留最近 20 条记录", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "登录时启动 PasteWhat", target: nil, action: nil)
    private let shortcuts = NSPopUpButton()
    private let appearances = NSPopUpButton()
    private let permissionLabel = Theme.label("", size: 12, color: .secondaryLabelColor)
    private let feedback = Theme.label("", size: 11, color: .secondaryLabelColor)
    private var configuration: EngineConfiguration

    init(configuration: EngineConfiguration) {
        self.configuration = configuration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 604),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PasteWhat 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        permissionLabel.stringValue = ContextReader.isTrusted ? "已允许 · 可读取输入语境并自动粘贴" : "未开启 · 仍可根据应用推荐与手动复制"
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])

        add(Theme.label("让粘贴顺着你的思路。", size: 21, weight: .bold), to: stack)
        add(Theme.label("内容与推理都在这台 Mac 上。", size: 12, color: .secondaryLabelColor), to: stack)
        separator(stack)
        add(Theme.label("日常使用", size: 13, weight: .semibold), to: stack)
        persist.state = UserDefaults.standard.bool(forKey: "rememberHistory") ? .on : .off
        persist.target = self; persist.action = #selector(persistenceChanged)
        add(persist, to: stack)
        login.target = self; login.action = #selector(loginChanged)
        add(login, to: stack)
        shortcuts.addItems(withTitles: ["⌥⇧V", "⌘⇧V", "⌃⌥V", "关闭"])
        shortcuts.selectItem(at: UserDefaults.standard.integer(forKey: "shortcutChoice"))
        shortcuts.target = self; shortcuts.action = #selector(shortcutChanged)
        appearances.addItems(withTitles: ["跟随系统", "浅色", "深色"])
        appearances.selectItem(at: UserDefaults.standard.integer(forKey: "appearanceChoice"))
        appearances.target = self; appearances.action = #selector(appearanceChanged)
        let shortcutRow = NSStackView(views: [Theme.label("打开剪贴板", size: 12), shortcuts, NSView(), Theme.label("外观", size: 12), appearances])
        shortcutRow.spacing = 12
        add(shortcutRow, to: stack)
        separator(stack)

        add(Theme.label("输入语境与自动粘贴", size: 13, weight: .semibold), to: stack)
        let permissionButton = Theme.button("开启辅助功能…", target: self, action: #selector(permissionClicked))
        let permissionRow = NSStackView(views: [permissionLabel, NSView(), permissionButton])
        permissionRow.spacing = 10
        add(permissionRow, to: stack)
        let permissionInfo = Theme.label("仅读取当前输入框附近文字；安全输入框会跳过。无需屏幕录制权限。", size: 11, color: .secondaryLabelColor)
        permissionInfo.maximumNumberOfLines = 2
        add(permissionInfo, to: stack)
        separator(stack)

        add(Theme.label("Laya 本地引擎", size: 13, weight: .semibold), to: stack)
        backend.addItems(withTitles: ["MLX · multilingual", "Core ML · multilingual"])
        backend.selectItem(at: configuration.backend == "coreml" ? 1 : 0)
        backend.target = self; backend.action = #selector(backendChanged)
        add(backend, to: stack)
        pythonField.stringValue = configuration.pythonPath
        pythonField.placeholderString = "Python 可执行文件"
        modelField.stringValue = configuration.modelPath
        modelField.placeholderString = "本地 Laya multilingual 模型文件夹"
        for field in [pythonField, modelField] {
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingMiddle
            field.cell?.isScrollable = true
        }
        add(pathRow(label: "Python", field: pythonField, action: #selector(choosePython)), to: stack)
        add(pathRow(label: "模型", field: modelField, action: #selector(chooseModel)), to: stack)
        let engineNote = Theme.label("首次使用请运行 scripts/setup-engine.sh。Core ML 需 macOS 15+；不使用 L96 ANE 模型。", size: 11, color: .secondaryLabelColor)
        engineNote.maximumNumberOfLines = 2
        add(engineNote, to: stack)
        let save = Theme.button("保存并重新连接", symbol: "arrow.clockwise", target: self, action: #selector(saveEngine))
        let clear = Theme.button("清空历史…", target: self, action: #selector(clearClicked))
        let actions = NSStackView(views: [clear, NSView(), save])
        add(actions, to: stack)
        feedback.maximumNumberOfLines = 2
        feedback.lineBreakMode = .byWordWrapping
        add(feedback, to: stack)
    }

    private func add(_ child: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func separator(_ stack: NSStackView) {
        let line = NSBox()
        line.boxType = .separator
        add(line, to: stack)
    }

    private func pathRow(label: String, field: NSTextField, action: Selector) -> NSStackView {
        let name = Theme.label(label, size: 12)
        name.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let choose = Theme.button("选择…", target: self, action: action)
        choose.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [name, field, choose])
        row.spacing = 10
        return row
    }

    @objc private func persistenceChanged() {
        let enabled = persist.state == .on
        UserDefaults.standard.set(enabled, forKey: "rememberHistory")
        onPersistenceChanged?(enabled)
        feedback.stringValue = enabled ? "最近 20 条将在本机保存。" : "已关闭磁盘保存；本次会话仍可使用记录。"
    }

    @objc private func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            let status = SMAppService.mainApp.status
            feedback.stringValue = status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许 PasteWhat。" : "已更新登录启动设置。"
            login.state = status == .enabled ? .on : .off
        } catch {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            feedback.stringValue = "无法更新登录启动：\(error.localizedDescription)"
        }
    }

    @objc private func shortcutChanged() {
        UserDefaults.standard.set(shortcuts.indexOfSelectedItem, forKey: "shortcutChoice")
        onShortcutChanged?()
        feedback.stringValue = "已更新快捷键；冲突时仍可点击菜单栏图标打开。"
    }

    @objc private func appearanceChanged() {
        UserDefaults.standard.set(appearances.indexOfSelectedItem, forKey: "appearanceChoice")
        onAppearanceChanged?()
    }

    @objc private func permissionClicked() {
        ContextReader.requestPermission()
        permissionLabel.stringValue = ContextReader.isTrusted ? "已允许 · 可读取输入语境并自动粘贴" : "请在系统设置中允许 PasteWhat，再重新打开面板。"
    }

    @objc private func backendChanged() {
        let previous = backend.indexOfSelectedItem == 0 ? "laya-coreml" : "laya-mlx"
        let selected = backend.indexOfSelectedItem == 0 ? "laya-mlx" : "laya-coreml"
        let candidatePython = pythonField.stringValue.replacingOccurrences(of: "/\(previous)/", with: "/\(selected)/")
        let candidateModel = modelField.stringValue.replacingOccurrences(of: "/\(previous)/", with: "/\(selected)/")
            .replacingOccurrences(of: previous == "laya-mlx" ? "multilingual-mlx" : "multilingual-coreml", with: selected == "laya-mlx" ? "multilingual-mlx" : "multilingual-coreml")
        if FileManager.default.isExecutableFile(atPath: candidatePython) { pythonField.stringValue = candidatePython }
        if FileManager.default.fileExists(atPath: candidateModel) { modelField.stringValue = candidateModel }
    }

    @objc private func saveEngine() {
        let next = EngineConfiguration(backend: backend.indexOfSelectedItem == 0 ? "mlx" : "coreml",
                                       pythonPath: (pythonField.stringValue as NSString).expandingTildeInPath,
                                       modelPath: (modelField.stringValue as NSString).expandingTildeInPath)
        guard FileManager.default.isExecutableFile(atPath: next.pythonPath) else {
            feedback.stringValue = "请选择可执行的 Python 文件。"; return
        }
        guard FileManager.default.fileExists(atPath: next.modelPath + "/rl_agent_config.json") else {
            feedback.stringValue = "模型文件夹中没有 rl_agent_config.json，请选择完整的 Laya 模型。"; return
        }
        let artifact = next.backend == "mlx" ? "model.safetensors" : "coreml_config.json"
        guard FileManager.default.fileExists(atPath: next.modelPath + "/" + artifact) else {
            feedback.stringValue = "模型文件夹与所选引擎不匹配，请选择对应的 multilingual 模型。"; return
        }
        if next.backend == "coreml" {
            guard #available(macOS 15, *) else {
                feedback.stringValue = "Core ML 后端需要 macOS 15 或更新版本；当前系统请使用 MLX。"; return
            }
        }
        do {
            try onSaveEngine?(next)
            configuration = next
            feedback.stringValue = "配置已保存；下次打开剪贴板时加载模型。"
        } catch { feedback.stringValue = "保存失败：\(error.localizedDescription)" }
    }

    @objc private func choosePython() { choosePath(for: pythonField, directory: false) }
    @objc private func chooseModel() { choosePath(for: modelField, directory: true) }

    private func choosePath(for field: NSTextField, directory: Bool) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = directory
        picker.canChooseFiles = !directory
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        picker.message = directory ? "选择已下载的 Laya multilingual 模型文件夹" : "选择安装了 Laya 的 Python 可执行文件"
        if let window {
            picker.beginSheetModal(for: window) { response in
                if response == .OK, let path = picker.url?.path { field.stringValue = path }
            }
        }
    }

    @objc private func clearClicked() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "这会移除 PasteWhat 中保存的记录，系统剪贴板内容不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空历史")
        alert.addButton(withTitle: "取消")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onClearHistory?()
            self?.feedback.stringValue = "历史已清空。"
        }
    }
}
