import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
enum PasteController {
    private static var isPasting = false

    /// The caller has already written the chosen entry and dismissed its panel.
    /// A nil result means the paste events were dispatched; apps may still decline to handle them.
    static func paste(to context: AppContext, clipboardVersion: Int) async -> String? {
        guard !Task.isCancelled else { return "已复制，粘贴操作已取消" }
        guard !isPasting else { return "已复制，另一条粘贴操作尚未完成" }
        guard ContextReader.isTrusted, CGPreflightPostEventAccess() else {
            return "已复制，请按 ⌘V 粘贴；启用辅助功能权限后可直接粘贴"
        }
        guard !context.isSecure else { return "已复制，安全输入框请手动粘贴" }
        guard context.processID > 0, context.processID != ProcessInfo.processInfo.processIdentifier,
              let target = NSRunningApplication(processIdentifier: context.processID), !target.isTerminated,
              context.bundleID.isEmpty || target.bundleIdentifier == context.bundleID else {
            return "已复制，原应用已退出，请手动粘贴"
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        func destinationIsStillSafe() -> Bool {
            guard !target.isTerminated else { return false }
            guard let front = NSWorkspace.shared.frontmostApplication else { return true }
            return front.processIdentifier == ownPID || front.processIdentifier == context.processID
        }
        guard destinationIsStillSafe() else { return "已复制，前台应用已切换，请手动粘贴" }
        isPasting = true
        defer { isPasting = false }
        if !target.isActive {
            if NSApp.isActive { NSApp.yieldActivation(to: target) }
            guard target.activate(options: []) else { return "已复制，无法切回原应用，请手动粘贴" }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        while !target.isActive {
            guard destinationIsStillSafe() else { return "已复制，前台应用已切换，请手动粘贴" }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return "已复制，原应用尚未获得焦点，请手动粘贴" }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return "已复制，粘贴操作已取消" }
        }
        // Give the dismissed nonactivating panel one run-loop turn to release keyboard focus.
        do { try await Task.sleep(for: .milliseconds(30)) }
        catch { return "已复制，粘贴操作已取消" }
        guard !Task.isCancelled, destinationIsStillSafe(), target.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processID else {
            return "已复制，输入焦点已变化，请手动粘贴"
        }
        guard NSPasteboard.general.changeCount == clipboardVersion else {
            return "剪贴板已被更新，已取消自动粘贴"
        }
        guard ContextReader.isTrusted, CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return "已复制，无法发送粘贴快捷键，请手动粘贴"
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(context.processID)
        up.postToPid(context.processID)
        return nil
    }
}
