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
    /// Chromium/Electron apps expose web content only after an assistive client opts
    /// in; until then AXFocusedUIElement is nil or a window-level shell. Native apps
    /// answer immediately, so only categories known to host web content warm up.
    private static let warmUpCategories: Set<ApplicationCategory> = [.browser, .development, .messaging, .writing, .unknown]
    private static let shellRoles: Set<String> = [kAXWindowRole as String, kAXScrollAreaRole as String]

    static func read(_ base: AppContext) -> AppContext {
        var context = base
        guard AXIsProcessTrusted() else { context.hasAccessibility = false; return context }
        var probeReader = BoundedAXReader()
        let app = AXUIElementCreateApplication(base.processID)
        var focused = probeReader.element(app, kAXFocusedUIElementAttribute as CFString)
        if isShellResult(focused, reader: &probeReader),
           warmUpCategories.contains(ApplicationCategory.classify(bundleID: base.bundleID)),
           let warmed = warmUpFocusedElement(app: app) {
            focused = warmed
        }
        var reader = BoundedAXReader()
        guard let focused else {
            if let window = reader.element(app, kAXFocusedWindowAttribute as CFString) {
                context.windowTitle = reader.string(window, kAXTitleAttribute as CFString, limit: 240)
            }
            return context
        }
        // A real click on a rich web composer can leave DOM focus on a wrapper
        // group while the editable element sits one level down.
        let field = reader.string(focused, kAXRoleAttribute as CFString, limit: 80) == kAXGroupRole as String
            ? reader.editableChild(of: focused) ?? focused : focused
        context.fieldRole = reader.string(field, kAXRoleAttribute as CFString, limit: 80)
        let subrole = reader.string(field, kAXSubroleAttribute as CFString, limit: 80)
        if subrole == kAXSecureTextFieldSubrole as String {
            context.isSecure = true
            return context
        }
        for attribute in [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            let label = reader.string(field, attribute as CFString, limit: 240)
            if !label.isEmpty { context.fieldLabel = label; break }
        }
        var selection: CFRange?
        var windowSelection: NSRange?
        if let raw = reader.value(field, kAXSelectedTextRangeAttribute as CFString),
           CFGetTypeID(raw) == AXValueGetTypeID() {
            let rangeValue = raw as! AXValue
            var range = CFRange()
            if AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range),
               range.location >= 0, range.location < 1_000_000_000,
               range.length >= 0, range.length < 1_000_000_000 { selection = range }
        }
        let characterCount = (reader.value(field, kAXNumberOfCharactersAttribute as CFString) as? NSNumber)?.intValue
        if let selection {
            let start = max(0, selection.location - 700)
            let desiredEnd = selection.location + min(selection.length, 500) + 500
            let end = characterCount.map { min(max(0, $0), desiredEnd) } ?? desiredEnd
            if end > start {
                var range = CFRange(location: start, length: min(end - start, 1_700))
                if let value = AXValueCreate(.cfRange, &range) {
                    context.surroundingText = reader.parameterizedString(field, kAXStringForRangeParameterizedAttribute as CFString,
                                                                        parameter: value, limit: 1_700)
                    if !context.surroundingText.isEmpty {
                        windowSelection = NSRange(location: selection.location - start, length: selection.length)
                    }
                }
            }
            if selection.length > 0, selection.length <= 1_200 {
                context.selectedText = reader.string(field, kAXSelectedTextAttribute as CFString, limit: 1_200)
            }
        }
        if context.surroundingText.isEmpty,
           (characterCount.map { $0 >= 0 && $0 <= 8_192 } ?? (context.fieldRole == kAXTextFieldRole as String)),
           let value = reader.value(field, kAXValueAttribute as CFString) as? String {
            let text = String(value.prefix(8_192)) as NSString
            let caret = min(selection?.location ?? text.length, text.length)
            let requestedStart = max(0, caret - 900)
            let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: requestedStart,
                                                                            length: min(1_700, text.length - requestedStart)))
            let start = range.location
            context.surroundingText = text.substring(with: range)
            if let selection, selection.location <= text.length {
                windowSelection = NSRange(location: selection.location - start, length: selection.length)
            }
        }
        if characterCount == 0, selection?.location == 0, selection?.length == 0 {
            windowSelection = NSRange(location: 0, length: 0)
        }
        if let window = reader.element(app, kAXFocusedWindowAttribute as CFString) {
            context.windowTitle = reader.string(window, kAXTitleAttribute as CFString, limit: 240)
        }
        let nearby = reader.nearbyStaticText(field)
        context.surroundingText = FocusText.render(textWindow: context.surroundingText,
                                                  selection: windowSelection, selectedText: context.selectedText,
                                                  nearbyText: nearby, hostName: context.appName)
        return context
    }

    private static func isShellResult(_ element: AXUIElement?, reader: inout BoundedAXReader) -> Bool {
        guard let element else { return true }
        return shellRoles.contains(reader.string(element, kAXRoleAttribute as CFString, limit: 80))
    }

    /// Opt the app into web accessibility, then give its renderer a moment to build
    /// the tree. Current Chrome acknowledges AXManualAccessibility with a
    /// cannotComplete error yet still enables the tree about two seconds later, so
    /// the poll — not the set result — is the source of truth.
    private static func warmUpFocusedElement(app: AXUIElement) -> AXUIElement? {
        _ = AXUIElementSetMessagingTimeout(app, 0.15)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let deadline = ProcessInfo.processInfo.systemUptime + 3.0
        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let element = value as! AXUIElement
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            if let role = roleValue as? String, !shellRoles.contains(role) { return element }
        }
        return nil
    }
}

private struct BoundedAXReader {
    // The 0.85s deadline is the responsiveness guard; the op count only bounds
    // worst-case chatter, with room for the one-level web label unwrap.
    private var remaining = 64
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.85

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

    /// A narrow neighborhood, never a recursive window/document scrape. Other
    /// editable fields are excluded, including secure fields and their values.
    /// Web pages nest visible labels one wrapper deep (div → AXGroup → text),
    /// unlike flat native layouts, so container siblings get one bounded peek inside.
    mutating func nearbyStaticText(_ focused: AXUIElement) -> [String] {
        guard let parent = element(focused, kAXParentAttribute as CFString),
              let children = elements(parent, kAXChildrenAttribute as CFString, limit: 32),
              let index = children.firstIndex(where: { CFEqual($0, focused) }) else { return [] }
        let positions = [index - 1, index + 1, index - 2, index + 2, index - 3, index + 3]
        var result: [String] = []
        for position in positions where children.indices.contains(position) {
            collectLabel(children[position], into: &result, unwrapContainer: true)
            if result.count == 4 { break }
        }
        return result
    }

    private mutating func collectLabel(_ element: AXUIElement, into result: inout [String], unwrapContainer: Bool) {
        let role = string(element, kAXRoleAttribute as CFString, limit: 80)
        if [kAXStaticTextRole as String, kAXHeadingRole as String].contains(role) {
            if (value(element, kAXHiddenAttribute as CFString) as? Bool) == true { return }
            var label = string(element, kAXValueAttribute as CFString, limit: 240)
            if label.isEmpty { label = string(element, kAXTitleAttribute as CFString, limit: 240) }
            if !label.isEmpty { result.append(label) }
            return
        }
        guard unwrapContainer, role == kAXGroupRole as String,
              let nested = elements(element, kAXChildrenAttribute as CFString, limit: 6) else { return }
        for child in nested {
            collectLabel(child, into: &result, unwrapContainer: false)
            if result.count == 4 { return }
        }
    }

    /// Real clicks on rich web composers can land DOM focus on a wrapper group
    /// while the editable element sits one level down; prefer the focused child.
    mutating func editableChild(of element: AXUIElement) -> AXUIElement? {
        let textRoles = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        guard let children = elements(element, kAXChildrenAttribute as CFString, limit: 8) else { return nil }
        var fallback: AXUIElement?
        for child in children where textRoles.contains(string(child, kAXRoleAttribute as CFString, limit: 80)) {
            if (value(child, kAXFocusedAttribute as CFString) as? Bool) == true { return child }
            if fallback == nil { fallback = child }
        }
        return fallback
    }

    mutating func elements(_ element: AXUIElement, _ attribute: CFString, limit: Int) -> [AXUIElement]? {
        guard prepare(element) else { return nil }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute, 0, limit, &values) == .success,
              let values = values as? [AXUIElement] else { return nil }
        return values
    }
}
