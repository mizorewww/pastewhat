import AppKit
import ApplicationServices

@MainActor
final class ContextReader {
    private let queue = DispatchQueue(label: "app.pastewhat.accessibility", qos: .userInitiated)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        // The SDK exposes this constant as a mutable C global; the documented key is stable.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func capture(app: NSRunningApplication) async -> AppContext {
        let base = AppContext(appName: app.localizedName ?? "当前应用", bundleID: app.bundleIdentifier ?? "",
                              processID: app.processIdentifier, hasAccessibility: Self.isTrusted)
        guard base.hasAccessibility, !app.isTerminated, !Task.isCancelled else { return base }
        return await withCheckedContinuation { continuation in
            // Only Sendable values cross the queue boundary; AX references stay on this serial queue.
            queue.async {
                continuation.resume(returning: AXContextSnapshot.read(base))
            }
        }
    }
}

private enum AXContextSnapshot {
    static func read(_ base: AppContext) -> AppContext {
        var context = base
        guard AXIsProcessTrusted() else { context.hasAccessibility = false; return context }
        var reader = BoundedAXReader()
        let app = AXUIElementCreateApplication(base.processID)
        guard let focused = reader.element(app, kAXFocusedUIElementAttribute as CFString) else {
            if let window = reader.element(app, kAXFocusedWindowAttribute as CFString) {
                context.windowTitle = reader.string(window, kAXTitleAttribute as CFString, limit: 240)
            }
            return context
        }
        context.fieldRole = reader.string(focused, kAXRoleAttribute as CFString, limit: 80)
        let subrole = reader.string(focused, kAXSubroleAttribute as CFString, limit: 80)
        if subrole == kAXSecureTextFieldSubrole as String {
            context.isSecure = true
            return context
        }
        for attribute in [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            let label = reader.string(focused, attribute as CFString, limit: 240)
            if !label.isEmpty { context.fieldLabel = label; break }
        }
        var selection: CFRange?
        if let raw = reader.value(focused, kAXSelectedTextRangeAttribute as CFString),
           CFGetTypeID(raw) == AXValueGetTypeID() {
            let rangeValue = raw as! AXValue
            var range = CFRange()
            if AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range),
               range.location >= 0, range.location < 1_000_000_000,
               range.length >= 0, range.length < 1_000_000_000 { selection = range }
        }
        let characterCount = (reader.value(focused, kAXNumberOfCharactersAttribute as CFString) as? NSNumber)?.intValue
        if let selection {
            let start = max(0, selection.location - 700)
            let desiredEnd = selection.location + min(selection.length, 500) + 500
            let end = characterCount.map { min(max(0, $0), desiredEnd) } ?? desiredEnd
            if end > start {
                var range = CFRange(location: start, length: min(end - start, 1_700))
                if let value = AXValueCreate(.cfRange, &range) {
                    context.surroundingText = reader.parameterizedString(focused, kAXStringForRangeParameterizedAttribute as CFString,
                                                                        parameter: value, limit: 1_700)
                }
            }
            if selection.length > 0, selection.length <= 1_200 {
                context.selectedText = reader.string(focused, kAXSelectedTextAttribute as CFString, limit: 1_200)
            }
        }
        if context.surroundingText.isEmpty,
           (characterCount.map { $0 >= 0 && $0 <= 8_192 } ?? (context.fieldRole == kAXTextFieldRole as String)) {
            let value = reader.string(focused, kAXValueAttribute as CFString, limit: 8_192)
            let text = value as NSString
            let caret = min(selection?.location ?? text.length, text.length)
            let start = max(0, caret - 900)
            context.surroundingText = text.substring(with: NSRange(location: start, length: min(1_700, text.length - start)))
        }
        if let window = reader.element(app, kAXFocusedWindowAttribute as CFString) {
            context.windowTitle = reader.string(window, kAXTitleAttribute as CFString, limit: 240)
        }
        return context
    }
}

private struct BoundedAXReader {
    private var remaining = 14
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.65

    private mutating func prepare(_ element: AXUIElement) -> Bool {
        let available = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, available > 0 else { return false }
        remaining -= 1
        _ = AXUIElementSetMessagingTimeout(element, Float(min(available, 0.08)))
        return true
    }

    mutating func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    mutating func element(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    mutating func string(_ element: AXUIElement, _ attribute: CFString, limit: Int) -> String {
        guard let value = value(element, attribute) as? String else { return "" }
        return String(value.prefix(limit))
    }

    mutating func parameterizedString(_ element: AXUIElement, _ attribute: CFString,
                                     parameter: CFTypeRef, limit: Int) -> String {
        guard prepare(element) else { return "" }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value) == .success,
              let text = value as? String else { return "" }
        return String(text.prefix(limit))
    }
}
