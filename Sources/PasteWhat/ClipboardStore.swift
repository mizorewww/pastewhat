import AppKit
import CryptoKit
import Darwin

@MainActor
final class ClipboardStore {
    private(set) var entries: [ClipboardEntry] = []
    var onChange: (() -> Void)?
    var onStatus: ((String?) -> Void)? {
        didSet { onStatus?(captureStatus ?? persistenceStatus) }
    }
    var isPaused = false {
        didSet {
            if timer != nil { lastChangeCount = NSPasteboard.general.changeCount }
        }
    }

    private var timer: Timer?
    private var lastChangeCount: Int?
    private var ownChangeCount: Int?
    private var lastAccessBehavior: Int?
    private var persistenceEnabled: Bool
    private var historyLoaded: Bool
    private var historyLoadFailed = false
    private var changedWhileLoading = false
    private var clearedWhileLoading = false
    private var removedWhileLoading: Set<UUID> = []
    private var persistenceRevision = 0
    private var writeInFlight = false
    private var pendingSave = false
    private var isFlushing = false
    private var deletionRequested = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var captureStatus: String?
    private var persistenceStatus: String?
    private let ioQueue = DispatchQueue(label: "app.pastewhat.history", qos: .utility)
    private let historyURL: URL

    init(persist: Bool = true) {
        persistenceEnabled = persist
        historyLoaded = !persist
        historyURL = AppPaths.support.appendingPathComponent("history.json")
        if persist { loadHistory() }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Await this from applicationShouldTerminate before replying to a .terminateLater request.
    func flush() async {
        stop()
        if isFlushing {
            await withCheckedContinuation { flushWaiters.append($0) }
            return
        }
        isFlushing = true
        if !historyLoaded {
            await withCheckedContinuation { loadWaiters.append($0) }
        }
        // Finish initial loading before taking a snapshot, so a quick quit cannot erase old history.
        while true {
            persistenceRevision += 1
            let revision = persistenceRevision
            pendingSave = false
            let snapshot = entries
            let persist = persistenceEnabled
            let delete = deletionRequested
            let preserveUnreadHistory = historyLoadFailed && !changedWhileLoading && !clearedWhileLoading
            let url = historyURL
            let error: String? = await withCheckedContinuation { continuation in
                ioQueue.async {
                    let error = Self.persistenceError {
                        if persist, !preserveUnreadHistory { try ClipboardHistoryFile.save(snapshot, at: url) }
                        else if delete { try ClipboardHistoryFile.remove(at: url) }
                    }
                    continuation.resume(returning: error)
                }
            }
            // A settings or deletion action may arrive while shutdown is waiting on disk I/O.
            guard persistenceRevision == revision else { continue }
            if !preserveUnreadHistory || !persist {
                persistenceStatus = error
                publishStatus()
            }
            break
        }
        isFlushing = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func clear() {
        entries.removeAll()
        clearedWhileLoading = true
        changedWhileLoading = true
        onChange?()
        saveHistory()
    }

    func remove(id: UUID) {
        removedWhileLoading.insert(id)
        entries.removeAll { $0.id == id }
        changedWhileLoading = true
        onChange?()
        saveHistory()
    }

    func setPersistenceEnabled(_ enabled: Bool) {
        guard persistenceEnabled != enabled else { return }
        persistenceEnabled = enabled
        if enabled {
            deletionRequested = false
            saveHistory()
        } else {
            deletionRequested = true
            clearedWhileLoading = true
            pendingSave = false
            persistenceRevision += 1
            let revision = persistenceRevision
            let url = historyURL
            ioQueue.async { [weak self] in
                let error = Self.persistenceError { try ClipboardHistoryFile.remove(at: url) }
                Task { @MainActor [weak self] in
                    guard let self, self.persistenceRevision == revision else { return }
                    self.persistenceStatus = error
                    self.publishStatus()
                }
            }
        }
    }

    func copy(entry: ClipboardEntry, plainText: Bool = false) throws {
        let items: [NSPasteboardItem]
        if plainText || entry.payloads.isEmpty {
            guard !entry.text.isEmpty else { throw ClipboardStoreError.noPlainText }
            // Image/file labels are descriptions, not a plain-text representation.
            if plainText, !entry.payloads.isEmpty,
               !entry.payloads.contains(where: { ClipboardPayloadCodec.text(from: $0) != nil }) {
                throw ClipboardStoreError.noPlainText
            }
            let text = entry.payloads.compactMap(ClipboardPayloadCodec.text(from:)).joined(separator: "\n")
            let item = NSPasteboardItem()
            item.setString(text.isEmpty ? entry.text : text, forType: .string)
            items = [item]
        } else {
            guard ClipboardPayloadCodec.isValid(entry.payloads) else { throw ClipboardStoreError.invalidPayload }
            items = entry.payloads.map { payload in
                let item = NSPasteboardItem()
                for (type, data) in payload.representations {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            }
        }
        guard let first = items.first else { throw ClipboardStoreError.invalidPayload }
        first.setString(UUID().uuidString, forType: ClipboardPayloadCodec.ownerType)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            lastChangeCount = pasteboard.changeCount
            throw ClipboardStoreError.writeFailed
        }
        ownChangeCount = pasteboard.changeCount
        lastChangeCount = ownChangeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard !isPaused else {
            lastChangeCount = pasteboard.changeCount
            return
        }
        if #available(macOS 15.4, *) {
            let behavior = pasteboard.accessBehavior
            if lastAccessBehavior != behavior.rawValue {
                lastAccessBehavior = behavior.rawValue
                lastChangeCount = nil
            }
            if behavior == .alwaysDeny {
                lastChangeCount = nil
                setCaptureStatus("剪贴板访问受限，请在系统设置中允许 PasteWhat 读取剪贴板")
                return
            }
        }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        if count == ownChangeCount {
            lastChangeCount = count
            return
        }
        let source = NSWorkspace.shared.frontmostApplication
        if ClipboardPayloadCodec.isPasswordManager(source?.bundleIdentifier) {
            lastChangeCount = count
            setCaptureStatus(nil)
            return
        }
        guard let items = pasteboard.pasteboardItems else {
            lastChangeCount = count
            setCaptureStatus("暂时无法读取剪贴板，请检查系统中的剪贴板访问设置")
            return
        }
        guard !items.isEmpty else {
            lastChangeCount = count
            setCaptureStatus(nil)
            return
        }
        guard items.count <= ClipboardPayloadCodec.maximumItems else {
            lastChangeCount = count
            setCaptureStatus("已跳过项目过多的剪贴板内容")
            return
        }
        if items.contains(where: { item in item.types.contains(where: ClipboardPayloadCodec.isExcluded) }) {
            lastChangeCount = count
            setCaptureStatus(nil)
            return
        }
        var payloads: [PasteboardPayload] = []
        var byteCount = 0
        for item in items {
            var representations: [String: Data] = [:]
            for type in item.types where ClipboardPayloadCodec.supportedTypes.contains(type.rawValue) {
                guard let data = item.data(forType: type) else { continue }
                guard data.count <= ClipboardPayloadCodec.maximumBytes - byteCount else {
                    lastChangeCount = count
                    setCaptureStatus("已跳过超过 8 MB 的剪贴板内容")
                    return
                }
                byteCount += data.count
                representations[type.rawValue] = data
            }
            // Dropping an unsupported item would silently turn a multi-item copy into a partial copy.
            guard !representations.isEmpty else {
                lastChangeCount = count
                setCaptureStatus(nil)
                return
            }
            payloads.append(PasteboardPayload(representations: representations))
        }
        guard pasteboard.changeCount == count else { return }
        lastChangeCount = count
        setCaptureStatus(nil)
        guard ClipboardPayloadCodec.isValid(payloads) else { return }
        let summary = ClipboardPayloadCodec.summary(payloads)
        guard !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fingerprint = ClipboardPayloadCodec.fingerprint(payloads)
        var entry = ClipboardEntry(
            text: summary.text,
            kind: summary.kind,
            sourceApp: source?.localizedName ?? "未知应用",
            sourceBundleID: source?.bundleIdentifier,
            payloads: payloads,
            fingerprint: fingerprint
        )
        if let previous = entries.first(where: { $0.fingerprint == fingerprint }) {
            entry.id = previous.id
        }
        entries.removeAll { $0.fingerprint == fingerprint }
        entries.insert(entry, at: 0)
        if entries.count > 20 { entries.removeLast(entries.count - 20) }
        changedWhileLoading = true
        onChange?()
        saveHistory()
    }

    private func loadHistory() {
        let url = historyURL
        ioQueue.async { [weak self] in
            let result: Result<[ClipboardEntry], Error> = Result { try ClipboardHistoryFile.load(at: url) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.historyLoaded = true
                switch result {
                case .success(let stored):
                    if self.persistenceEnabled, !self.clearedWhileLoading {
                        let remaining = stored.filter { !self.removedWhileLoading.contains($0.id) }
                        // Both collections are already validated. Avoid hashing 160 MB again on the main actor.
                        var fingerprints: Set<String> = []
                        var identifiers: Set<UUID> = []
                        self.entries = (self.entries + remaining).compactMap { value in
                            guard fingerprints.insert(value.fingerprint).inserted else { return nil }
                            var entry = value
                            if !identifiers.insert(entry.id).inserted { entry.id = UUID() }
                            return entry
                        }
                        self.entries = Array(self.entries.prefix(20))
                        self.onChange?()
                    }
                case .failure(let error):
                    self.historyLoadFailed = true
                    if self.persistenceEnabled, !self.clearedWhileLoading {
                        self.persistenceStatus = "无法恢复剪贴板历史：\(error.localizedDescription)"
                        self.publishStatus()
                    }
                }
                self.removedWhileLoading.removeAll()
                if self.changedWhileLoading || self.clearedWhileLoading { self.saveHistory() }
                let waiters = self.loadWaiters
                self.loadWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    private func saveHistory() {
        guard persistenceEnabled, historyLoaded else { return }
        persistenceRevision += 1
        pendingSave = true
        beginNextSave()
    }

    private func beginNextSave() {
        guard persistenceEnabled, historyLoaded, pendingSave, !writeInFlight, !isFlushing else { return }
        pendingSave = false
        writeInFlight = true
        let revision = persistenceRevision
        let snapshot = entries
        let url = historyURL
        ioQueue.async { [weak self] in
            let error = Self.persistenceError { try ClipboardHistoryFile.save(snapshot, at: url) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.writeInFlight = false
                if self.persistenceRevision == revision {
                    self.persistenceStatus = error
                    self.publishStatus()
                }
                self.beginNextSave()
            }
        }
    }

    nonisolated private static func persistenceError(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch {
            return "无法保存剪贴板历史：\(error.localizedDescription)"
        }
    }

    private func setCaptureStatus(_ status: String?) {
        guard captureStatus != status else { return }
        captureStatus = status
        publishStatus()
    }

    private func publishStatus() { onStatus?(captureStatus ?? persistenceStatus) }
}

enum ClipboardStoreError: LocalizedError {
    case noPlainText, invalidPayload, writeFailed, invalidHistory

    var errorDescription: String? {
        switch self {
        case .noPlainText: "这条记录没有可复制的纯文本"
        case .invalidPayload: "这条剪贴板记录的内容不可用"
        case .writeFailed: "无法写入系统剪贴板，请重试"
        case .invalidHistory: "历史文件不完整或大小超出限制"
        }
    }
}

enum ClipboardPayloadCodec {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumItems = 128
    static let ownerType = NSPasteboard.PasteboardType("app.pastewhat.clipboard-owner")
    static let supportedTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-external-plain-text", "public.utf16-plain-text",
        "public.plain-text", "public.rtf", "com.apple.flat-rtfd", "public.html",
        "public.utf8-tab-separated-values-text", "public.png", "public.tiff", "com.adobe.pdf",
        "public.file-url", "public.url", "com.apple.cocoa.pasteboard.color"
    ]

    static func isExcluded(_ type: NSPasteboard.PasteboardType) -> Bool {
        let value = type.rawValue.lowercased()
        return type == ownerType || value == "org.nspasteboard.concealedtype"
            || value == "org.nspasteboard.transienttype" || value == "org.nspasteboard.autogeneratedtype"
            || value.contains("1password") || value.contains("onepassword")
    }

    static func isPasswordManager(_ bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return ["com.agilebits.", "com.1password.", "com.bitwarden.", "com.lastpass.",
                "com.dashlane.", "com.enpass.", "in.sinew.enpass", "org.keepassxc.",
                "com.apple.passwords", "com.apple.keychainaccess"].contains { bundleID.hasPrefix($0) }
    }

    static func isValid(_ payloads: [PasteboardPayload]) -> Bool {
        guard !payloads.isEmpty, payloads.count <= maximumItems else { return false }
        var size = 0
        for payload in payloads {
            guard !payload.representations.isEmpty else { return false }
            for (type, data) in payload.representations {
                guard supportedTypes.contains(type), data.count <= maximumBytes - size else { return false }
                size += data.count
            }
        }
        return size > 0
    }

    static func fingerprint(_ payloads: [PasteboardPayload]) -> String {
        var digest = SHA256()
        func appendLength(_ count: Int) {
            var length = UInt64(count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(bufferPointer: $0) }
        }
        appendLength(payloads.count)
        for payload in payloads {
            appendLength(payload.representations.count)
            for key in payload.representations.keys.sorted() {
                let typeBytes = Data(key.utf8)
                let bytes = payload.representations[key]!
                appendLength(typeBytes.count)
                digest.update(data: typeBytes)
                appendLength(bytes.count)
                digest.update(data: bytes)
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func text(from payload: PasteboardPayload) -> String? {
        for type in ["public.utf8-plain-text", "public.plain-text", "public.utf8-tab-separated-values-text",
                     "public.url", "public.file-url"] {
            if let data = payload.representations[type], let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        for type in ["public.utf16-external-plain-text", "public.utf16-plain-text"] {
            if let data = payload.representations[type], let text = String(data: data, encoding: .utf16) {
                return text
            }
        }
        return nil
    }

    static func summary(_ payloads: [PasteboardPayload]) -> (text: String, kind: ClipKind) {
        let types = Set(payloads.flatMap { $0.representations.keys })
        if types.contains("public.file-url") {
            let names = payloads.compactMap { payload -> String? in
                guard let data = payload.representations["public.file-url"],
                      let string = String(data: data, encoding: .utf8), let url = URL(string: string) else { return nil }
                return url.lastPathComponent
            }
            return (String(names.joined(separator: "\n").prefix(32_000)), .file)
        }
        let text = payloads.compactMap(Self.text(from:)).joined(separator: "\n")
        if !text.isEmpty { return (String(text.prefix(32_000)), kind(for: text)) }
        if !types.isDisjoint(with: ["public.png", "public.tiff", "com.adobe.pdf"]) {
            return (payloads.count > 1 ? "\(payloads.count) 张图片" : "图片", .image)
        }
        if types.contains("com.apple.cocoa.pasteboard.color") { return ("颜色", .color) }
        return ("富文本", .text)
    }

    static func kind(for text: String) -> ClipKind {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: "^#[0-9a-fA-F]{3,8}$", options: .regularExpression) != nil { return .color }
        if value.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil { return .email }
        if let url = URL(string: value), ["https", "http", "ftp", "mailto"].contains(url.scheme?.lowercased() ?? ""),
           !value.contains(where: \.isWhitespace) { return .url }
        if value.range(of: "^[+()0-9 .-]{7,25}$", options: .regularExpression) != nil,
           value.filter(\.isNumber).count >= 7 { return .phone }
        if ["$ ", "git ", "sudo ", "npm ", "npx ", "brew ", "python ", "python3 ", "curl ",
            "swift ", "cd ", "ls ", "ssh ", "docker ", "make ", "xcodebuild "].contains(where: value.hasPrefix) { return .command }
        if ["import ", "func ", "let ", "const ", "def ", "class ", "struct ", "SELECT ", "#!/"].contains(where: value.hasPrefix)
            || (value.contains("\n") && (value.contains("{") || value.contains("=>"))) { return .code }
        return .text
    }

    static func normalized(_ values: [ClipboardEntry]) -> [ClipboardEntry] {
        var seenFingerprints: Set<String> = []
        var seenIDs: Set<UUID> = []
        var result: [ClipboardEntry] = []
        for var entry in values {
            guard isValid(entry.payloads), !isPasswordManager(entry.sourceBundleID) else { continue }
            entry.fingerprint = fingerprint(entry.payloads)
            guard seenFingerprints.insert(entry.fingerprint).inserted else { continue }
            if !seenIDs.insert(entry.id).inserted { entry.id = UUID() }
            let description = summary(entry.payloads)
            entry.text = description.text
            entry.kind = description.kind
            entry.sourceApp = String(entry.sourceApp.prefix(160))
            entry.sourceBundleID = entry.sourceBundleID.map { String($0.prefix(240)) }
            result.append(entry)
            if result.count == 20 { break }
        }
        return result
    }
}

enum ClipboardHistoryFile {
    static func load(at url: URL) throws -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 240 * 1024 * 1024 else {
            throw ClipboardStoreError.invalidHistory
        }
        let decoded = try JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: url))
        return ClipboardPayloadCodec.normalized(decoded)
    }

    static func save(_ entries: [ClipboardEntry], at url: URL) throws {
        guard !entries.isEmpty else { try remove(at: url); return }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(entries)
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer {
            Darwin.close(descriptor)
            try? fileManager.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        guard fsync(descriptor) == 0, Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func remove(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }
}
