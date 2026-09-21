import AppKit

final class ClipboardPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 590),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        title = "PasteWhat 剪贴板"
        setAccessibilityLabel("PasteWhat 剪贴板")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class ClipboardPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onCopy: ((ClipboardEntry, Bool) -> Void)?
    var onPaste: ((ClipboardEntry) -> Void)?
    var onDelete: ((ClipboardEntry) -> Void)?
    var onSettings: (() -> Void)?
    var onClose: (() -> Void)?
    var onPause: (() -> Void)?

    private let search = NSSearchField()
    private let table = NSTableView()
    private let destination = Theme.label("准备下一次粘贴", size: 13, weight: .semibold)
    private let contextDetail = Theme.label("从最近 20 条中找到此刻需要的内容", size: 11, color: .secondaryLabelColor)
    private let destinationIcon = NSImageView()
    private let countLabel = Theme.label("最近记录", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let statusLabel = Theme.label("准备就绪", size: 11, color: .secondaryLabelColor)
    private let engineBadge = PillView("本地运行", color: .systemGreen)
    private let previewTitle = Theme.label("留住灵感，顺手粘贴。", size: 16, weight: .semibold)
    private let previewMeta = Theme.label("复制内容后，它就会出现在这里", size: 11, color: .secondaryLabelColor)
    private let previewKind = PillView("剪贴板")
    private let previewText = NSTextView()
    private let previewScroll = NSScrollView()
    private let previewImage = NSImageView()
    private let reasonTitle = Theme.label("随手复制，随时找到", size: 12, weight: .semibold, color: Theme.accent)
    private let reasonLabel = Theme.label("结合当前应用与输入语境，推荐会自动出现在首位。", size: 11, color: .secondaryLabelColor)
    private let emptyLabel = Theme.label("还没有复制记录\n试着复制一段文字、链接或图片", size: 13, color: .secondaryLabelColor)
    private let pauseButton = NSButton()
    private var copyButton: NSButton!
    private var pasteButton: NSButton!
    private var deleteButton: NSButton!
    private var allEntries: [ClipboardEntry] = []
    private var visibleEntries: [ClipboardEntry] = []
    private var recommendation: RecommendationResponse?
    private var context = AppContext()
    private var userHasSelected = false
    private var updating = false

    var selectedEntry: ClipboardEntry? {
        visibleEntries.indices.contains(table.selectedRow) ? visibleEntries[table.selectedRow] : nil
    }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true
        view = effect
        let backdrop = SurfaceView()
        backdrop.cornerRadius = 20
        backdrop.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94)
        backdrop.strokeColor = NSColor.separatorColor.withAlphaComponent(0.45)
        Theme.pin(backdrop, to: effect)
        buildHeader()
        buildContent()
        buildFooter()
    }

    private func buildHeader() {
        let mark = SurfaceView()
        mark.fillColor = Theme.accent.withAlphaComponent(0.13)
        mark.cornerRadius = 10
        let icon = Theme.symbol("square.on.square", size: 21, color: Theme.accent)
        Theme.pin(icon, to: mark, inset: 8)
        let brand = Theme.label("PasteWhat", size: 20, weight: .bold)
        let tagline = Theme.label("下一次粘贴，刚刚好。", size: 11, color: .secondaryLabelColor)
        let settings = Theme.button("", symbol: "gearshape", target: self, action: #selector(settingsClicked))
        settings.bezelStyle = .recessed
        settings.toolTip = "设置与权限"
        settings.setAccessibilityLabel("设置与权限")
        for child in [mark, brand, tagline, settings, engineBadge] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            mark.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            mark.widthAnchor.constraint(equalToConstant: 40), mark.heightAnchor.constraint(equalToConstant: 40),
            brand.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 12),
            brand.topAnchor.constraint(equalTo: mark.topAnchor, constant: 0),
            tagline.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            tagline.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 3),
            settings.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            settings.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            settings.widthAnchor.constraint(equalToConstant: 30), settings.heightAnchor.constraint(equalToConstant: 30),
            engineBadge.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -12),
            engineBadge.centerYAnchor.constraint(equalTo: mark.centerYAnchor)
        ])

        let targetSurface = SurfaceView()
        targetSurface.fillColor = NSColor.labelColor.withAlphaComponent(0.035)
        targetSurface.strokeColor = NSColor.separatorColor.withAlphaComponent(0.35)
        targetSurface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(targetSurface)
        let arrow = Theme.symbol("arrow.turn.down.right", size: 14)
        destinationIcon.imageScaling = .scaleProportionallyDown
        for child in [destinationIcon, destination, contextDetail, arrow] {
            child.translatesAutoresizingMaskIntoConstraints = false
            targetSurface.addSubview(child)
        }
        NSLayoutConstraint.activate([
            targetSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            targetSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            targetSurface.topAnchor.constraint(equalTo: view.topAnchor, constant: 78),
            targetSurface.heightAnchor.constraint(equalToConstant: 58),
            destinationIcon.leadingAnchor.constraint(equalTo: targetSurface.leadingAnchor, constant: 14),
            destinationIcon.centerYAnchor.constraint(equalTo: targetSurface.centerYAnchor),
            destinationIcon.widthAnchor.constraint(equalToConstant: 28), destinationIcon.heightAnchor.constraint(equalToConstant: 28),
            destination.leadingAnchor.constraint(equalTo: destinationIcon.trailingAnchor, constant: 11),
            destination.topAnchor.constraint(equalTo: targetSurface.topAnchor, constant: 11),
            destination.trailingAnchor.constraint(lessThanOrEqualTo: arrow.leadingAnchor, constant: -12),
            contextDetail.leadingAnchor.constraint(equalTo: destination.leadingAnchor),
            contextDetail.topAnchor.constraint(equalTo: destination.bottomAnchor, constant: 4),
            contextDetail.trailingAnchor.constraint(lessThanOrEqualTo: arrow.leadingAnchor, constant: -12),
            arrow.trailingAnchor.constraint(equalTo: targetSurface.trailingAnchor, constant: -15),
            arrow.centerYAnchor.constraint(equalTo: targetSurface.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 20)
        ])

        search.placeholderString = "搜索内容、来源或类型…"
        search.font = .systemFont(ofSize: 13)
        search.controlSize = .large
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.delegate = self
        search.setAccessibilityLabel("搜索剪贴板记录")
        search.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(search)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            search.topAnchor.constraint(equalTo: targetSurface.bottomAnchor, constant: 14),
            search.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func buildContent() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.rowHeight = 76
        table.style = .plain
        table.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(pasteClicked)
        table.setAccessibilityLabel("最近 20 条剪贴板，推荐项在首位")
        scroll.documentView = table
        for child in [countLabel, scroll, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 358),
            divider.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 18),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -53),
            divider.widthAnchor.constraint(equalToConstant: 1),
            countLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 26),
            countLabel.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 17),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -54),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalToConstant: 290)
        ])

        let preview = NSView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 22),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            preview.topAnchor.constraint(equalTo: divider.topAnchor),
            preview.bottomAnchor.constraint(equalTo: divider.bottomAnchor)
        ])

        let previewEyebrow = Theme.label("内容预览", size: 11, weight: .medium, color: .secondaryLabelColor)
        previewTitle.maximumNumberOfLines = 2
        previewTitle.lineBreakMode = .byTruncatingMiddle
        previewScroll.drawsBackground = false
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.borderType = .noBorder
        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.drawsBackground = false
        previewText.font = .systemFont(ofSize: 13)
        previewText.textColor = .labelColor
        previewText.textContainerInset = NSSize(width: 0, height: 5)
        previewText.isHorizontallyResizable = false
        previewText.isVerticallyResizable = true
        previewText.autoresizingMask = [.width]
        previewText.textContainer?.widthTracksTextView = true
        previewText.textContainer?.lineFragmentPadding = 0
        previewText.setAccessibilityLabel("剪贴板完整内容预览")
        previewScroll.documentView = previewText
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.isHidden = true

        let reasonBox = SurfaceView()
        reasonBox.fillColor = Theme.accent.withAlphaComponent(0.055)
        reasonBox.strokeColor = Theme.accent.withAlphaComponent(0.12)
        let spark = Theme.symbol("sparkles", size: 14, color: Theme.accent)
        reasonLabel.maximumNumberOfLines = 2
        reasonLabel.lineBreakMode = .byWordWrapping
        for child in [spark, reasonTitle, reasonLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            reasonBox.addSubview(child)
        }
        copyButton = Theme.button("复制", symbol: "doc.on.doc", target: self, action: #selector(copyClicked))
        pasteButton = Theme.button("粘贴到应用", symbol: "arrow.turn.down.left", target: self, action: #selector(pasteClicked))
        copyButton.controlSize = .large
        pasteButton.controlSize = .large
        pasteButton.bezelColor = Theme.accent
        pasteButton.contentTintColor = .white
        deleteButton = Theme.button("", symbol: "trash", target: self, action: #selector(deleteClicked))
        deleteButton.bezelStyle = .recessed
        deleteButton.toolTip = "删除这条记录"
        deleteButton.setAccessibilityLabel("删除这条记录")

        for child in [previewEyebrow, previewKind, previewTitle, previewMeta, previewScroll,
                      previewImage, reasonBox, copyButton!, pasteButton!, deleteButton!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            preview.addSubview(child)
        }
        NSLayoutConstraint.activate([
            previewEyebrow.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            previewEyebrow.topAnchor.constraint(equalTo: preview.topAnchor),
            previewKind.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            previewKind.centerYAnchor.constraint(equalTo: previewEyebrow.centerYAnchor),
            previewTitle.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            previewTitle.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            previewTitle.topAnchor.constraint(equalTo: previewEyebrow.bottomAnchor, constant: 20),
            previewTitle.heightAnchor.constraint(lessThanOrEqualToConstant: 44),
            previewMeta.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            previewMeta.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            previewMeta.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 7),
            previewScroll.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: previewMeta.bottomAnchor, constant: 13),
            previewScroll.bottomAnchor.constraint(equalTo: reasonBox.topAnchor, constant: -15),
            previewImage.leadingAnchor.constraint(equalTo: previewScroll.leadingAnchor),
            previewImage.trailingAnchor.constraint(equalTo: previewScroll.trailingAnchor),
            previewImage.topAnchor.constraint(equalTo: previewScroll.topAnchor),
            previewImage.bottomAnchor.constraint(equalTo: previewScroll.bottomAnchor),
            reasonBox.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            reasonBox.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            reasonBox.bottomAnchor.constraint(equalTo: pasteButton.topAnchor, constant: -14),
            reasonBox.heightAnchor.constraint(equalToConstant: 72),
            spark.leadingAnchor.constraint(equalTo: reasonBox.leadingAnchor, constant: 12),
            spark.topAnchor.constraint(equalTo: reasonBox.topAnchor, constant: 12),
            spark.widthAnchor.constraint(equalToConstant: 16),
            reasonTitle.leadingAnchor.constraint(equalTo: spark.trailingAnchor, constant: 7),
            reasonTitle.topAnchor.constraint(equalTo: reasonBox.topAnchor, constant: 12),
            reasonTitle.trailingAnchor.constraint(equalTo: reasonBox.trailingAnchor, constant: -12),
            reasonLabel.leadingAnchor.constraint(equalTo: reasonTitle.leadingAnchor),
            reasonLabel.trailingAnchor.constraint(equalTo: reasonTitle.trailingAnchor),
            reasonLabel.topAnchor.constraint(equalTo: reasonTitle.bottomAnchor, constant: 5),
            reasonLabel.bottomAnchor.constraint(lessThanOrEqualTo: reasonBox.bottomAnchor, constant: -9),
            pasteButton.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            pasteButton.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: -8),
            pasteButton.heightAnchor.constraint(equalToConstant: 32),
            pasteButton.widthAnchor.constraint(equalToConstant: 140),
            copyButton.trailingAnchor.constraint(equalTo: pasteButton.leadingAnchor, constant: -9),
            copyButton.centerYAnchor.constraint(equalTo: pasteButton.centerYAnchor),
            copyButton.heightAnchor.constraint(equalToConstant: 32),
            copyButton.widthAnchor.constraint(equalToConstant: 80),
            deleteButton.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            deleteButton.centerYAnchor.constraint(equalTo: pasteButton.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func buildFooter() {
        let line = NSBox()
        line.boxType = .separator
        let keys = Theme.label("↑↓ 选择    ↩ 粘贴    ⌘C 复制    esc 关闭", size: 10, color: .secondaryLabelColor)
        pauseButton.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "暂停记录")
        pauseButton.bezelStyle = .recessed
        pauseButton.isBordered = false
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.toolTip = "暂停记录"
        for child in [line, statusLabel, keys, pauseButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            line.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -43),
            pauseButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            pauseButton.centerYAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
            pauseButton.widthAnchor.constraint(equalToConstant: 24), pauseButton.heightAnchor.constraint(equalToConstant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 5),
            statusLabel.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -15),
            keys.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            keys.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor)
        ])
    }

    func begin(context: AppContext, entries: [ClipboardEntry], demo: Bool = false) {
        _ = view
        self.context = context
        recommendation = nil
        engineBadge.label.stringValue = "最近记录"
        userHasSelected = false
        search.stringValue = ""
        destination.stringValue = "粘贴到 \(context.appName)\(demo ? " · 演示" : "")"
        contextDetail.stringValue = context.detail
        destinationIcon.image = NSRunningApplication(processIdentifier: context.processID)?.icon
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        setEntries(entries)
    }

    func updateContext(_ context: AppContext) {
        self.context = context
        contextDetail.stringValue = context.detail
    }

    func setEntries(_ entries: [ClipboardEntry]) {
        allEntries = entries
        refreshList()
    }

    func setRecommendation(_ response: RecommendationResponse?) {
        recommendation = response
        engineBadge.label.stringValue = response?.recommendedID == nil ? "最近记录"
            : response?.engineLabel ?? "本地匹配"
        refreshList(selectRecommended: !userHasSelected)
    }

    func setStatus(_ text: String) { statusLabel.stringValue = text; statusLabel.toolTip = text }

    func setPaused(_ paused: Bool) {
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.circle" : "pause.circle", accessibilityDescription: paused ? "继续记录" : "暂停记录")
        pauseButton.toolTip = paused ? "继续记录" : "暂停记录"
        if paused { setStatus("记录已暂停") }
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }

    private func refreshList(selectRecommended: Bool = false) {
        let oldID = selectedEntry?.id
        var ordered = allEntries
        if let id = recommendation?.recommendedID, let index = ordered.firstIndex(where: { $0.id.uuidString == id }) {
            let entry = ordered.remove(at: index)
            ordered.insert(entry, at: 0)
        }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleEntries = query.isEmpty ? ordered : ordered.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
        countLabel.stringValue = query.isEmpty ? "最近 \(allEntries.count) 条   /   最多 20 条" : "找到 \(visibleEntries.count) 条记录"
        updating = true
        table.reloadData()
        let selection = !selectRecommended ? visibleEntries.firstIndex(where: { $0.id == oldID }) : nil
        if !visibleEntries.isEmpty {
            table.selectRowIndexes(IndexSet(integer: selection ?? 0), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updating = false
        emptyLabel.isHidden = !visibleEntries.isEmpty
        emptyLabel.stringValue = allEntries.isEmpty ? "还没有复制记录\n试着复制一段文字、链接或图片" : "没有找到匹配内容\n换个关键词试试"
        updatePreview()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        isRecommended(row) ? 96 : 76
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = visibleEntries[row]
        let cell = ClipCellView()
        cell.configure(entry, selected: row == table.selectedRow, recommended: isRecommended(row),
                       recommendationLabel: recommendation?.recommendationTitle ?? "语境匹配", index: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        userHasSelected = true
        for row in 0..<visibleEntries.count {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCellView {
                cell.setSelected(row == table.selectedRow)
            }
        }
        updatePreview()
    }

    func controlTextDidChange(_ obj: Notification) { userHasSelected = true; refreshList() }

    private func isRecommended(_ row: Int) -> Bool {
        visibleEntries.indices.contains(row) && visibleEntries[row].id.uuidString == recommendation?.recommendedID
    }

    private func updatePreview() {
        guard let entry = selectedEntry else {
            previewTitle.stringValue = allEntries.isEmpty ? "留住灵感，顺手粘贴。" : "没有匹配的记录"
            previewMeta.stringValue = allEntries.isEmpty ? "新的复制记录会自动出现在左侧" : "试试搜索内容、来源或类型"
            previewKind.label.stringValue = "剪贴板"
            previewText.string = ""
            previewImage.isHidden = true
            previewScroll.isHidden = false
            reasonTitle.stringValue = "随时找回最近内容"
            reasonLabel.stringValue = "最近 20 条保留在本机。可在设置中选择本地模型或 Jev 云端推荐。"
            copyButton.isEnabled = false; pasteButton.isEnabled = false; deleteButton.isEnabled = false
            return
        }
        copyButton.isEnabled = true; pasteButton.isEnabled = true; deleteButton.isEnabled = true
        previewKind.label.stringValue = entry.kind.label
        previewTitle.stringValue = entry.kind == .url ? (URL(string: entry.text)?.host ?? entry.title) : entry.title
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        let storedText = entry.payloads.compactMap(ClipboardPayloadCodec.text(from:)).joined(separator: "\n")
        let fullText = storedText.isEmpty ? entry.text : storedText
        previewMeta.stringValue = "\(entry.sourceApp)  ·  \(formatter.localizedString(for: entry.copiedAt, relativeTo: Date()))  ·  \(fullText.count) 字符"
        previewText.font = entry.kind == .code || entry.kind == .command
            ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        previewText.string = String(fullText.prefix(100_000))
        if fullText.count > 100_000 { previewText.string += "\n\n预览已截短，粘贴保留完整内容。" }
        previewText.scrollToBeginningOfDocument(nil)
        previewImage.image = nil
        if entry.kind == .image {
            for payload in entry.payloads {
                if let data = payload.representations[NSPasteboard.PasteboardType.png.rawValue]
                    ?? payload.representations[NSPasteboard.PasteboardType.tiff.rawValue] {
                    previewImage.image = NSImage(data: data)
                    break
                }
            }
        }
        previewImage.isHidden = previewImage.image == nil
        previewScroll.isHidden = previewImage.image != nil
        if entry.id.uuidString == recommendation?.recommendedID {
            reasonTitle.stringValue = recommendation?.recommendationTitle ?? "根据当前语境匹配"
            reasonLabel.stringValue = recommendation?.rankings.first(where: { $0.id == entry.id.uuidString })?.reason ?? "结合当前应用、内容类型和复制时间。"
        } else {
            reasonTitle.stringValue = "保留原始内容"
            reasonLabel.stringValue = "文字、格式与文件引用原样保留。双击记录或按回车即可粘贴。"
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        // Let the input method commit/cancel its marked text before using clipboard shortcuts.
        if let editor = view.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { onClose?(); return true }
        if event.keyCode == 125 || event.keyCode == 126 {
            guard !visibleEntries.isEmpty else { return true }
            userHasSelected = true
            let next = min(max(table.selectedRow + (event.keyCode == 125 ? 1 : -1), 0), visibleEntries.count - 1)
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let entry = selectedEntry {
                if flags.contains(.command) { onCopy?(entry, flags.contains(.shift)) } else { onPaste?(entry) }
            }
            return true
        }
        if flags.contains(.command), let characters = event.charactersIgnoringModifiers?.lowercased() {
            if characters == "f" { focusSearch(); return true }
            if characters == "," { onSettings?(); return true }
            if characters == "c" {
                // Preserve normal text selection copying in the preview and search field.
                if let text = view.window?.firstResponder as? NSTextView, text.selectedRange().length > 0 { return false }
                if let entry = selectedEntry { onCopy?(entry, flags.contains(.shift)) }
                return true
            }
            if let number = Int(characters), number > 0, number <= min(9, visibleEntries.count) {
                onPaste?(visibleEntries[number - 1]); return true
            }
            if event.keyCode == 51, let entry = selectedEntry {
                if let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor { return false }
                onDelete?(entry); return true
            }
        }
        return false
    }

    @objc private func copyClicked() { if let entry = selectedEntry { onCopy?(entry, false) } }
    @objc private func pasteClicked() { if let entry = selectedEntry { onPaste?(entry) } }
    @objc private func deleteClicked() { if let entry = selectedEntry { onDelete?(entry) } }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func pauseClicked() { onPause?() }
}

private final class ClipCellView: NSTableCellView {
    private let surface = SurfaceView()
    private let icon = NSImageView()
    private let titleLabel = Theme.label("", size: 13, weight: .medium)
    private let detailLabel = Theme.label("", size: 11, color: .secondaryLabelColor)
    private let badge = Theme.label("", size: 10, weight: .semibold, color: Theme.accent)
    private let shortcut = Theme.label("", size: 10, color: .tertiaryLabelColor)
    private var recommended = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Theme.pin(surface, to: self, inset: 1)
        surface.cornerRadius = 12
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        for child in [icon, titleLabel, detailLabel, badge, shortcut] {
            child.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(child)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 23), icon.heightAnchor.constraint(equalToConstant: 23),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -7),
            titleLabel.centerYAnchor.constraint(equalTo: surface.centerYAnchor, constant: -5),
            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 32),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            badge.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badge.topAnchor.constraint(equalTo: surface.topAnchor, constant: 9),
            shortcut.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            shortcut.widthAnchor.constraint(equalToConstant: 19)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ entry: ClipboardEntry, selected: Bool, recommended: Bool, recommendationLabel: String, index: Int) {
        self.recommended = recommended
        icon.image = NSImage(systemSymbolName: entry.kind.symbol, accessibilityDescription: entry.kind.label)
        icon.contentTintColor = recommended ? Theme.accent : .secondaryLabelColor
        titleLabel.stringValue = entry.title
        detailLabel.stringValue = "\(entry.sourceApp) · \(entry.kind.label)"
        badge.stringValue = "✦  \(recommendationLabel)"
        badge.isHidden = !recommended
        shortcut.stringValue = index < 9 ? "⌘\(index + 1)" : ""
        setSelected(selected)
        setAccessibilityElement(true)
        setAccessibilityLabel("\(recommended ? "推荐，" : "")\(entry.kind.label)，\(entry.title)，来自\(entry.sourceApp)")
    }

    func setSelected(_ selected: Bool) {
        surface.fillColor = selected ? Theme.accent.withAlphaComponent(0.11)
            : recommended ? Theme.accent.withAlphaComponent(0.045) : .clear
        surface.strokeColor = selected ? Theme.accent.withAlphaComponent(0.35) : .clear
    }
}
