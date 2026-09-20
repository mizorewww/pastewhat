import AppKit

@MainActor
enum Theme {
    static let accent = NSColor(name: "PasteWhatAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.70, green: 0.65, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.34, green: 0.26, blue: 0.77, alpha: 1)
    }
    static let muted = NSColor.secondaryLabelColor

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func symbol(_ name: String, size: CGFloat = 16, color: NSColor = .secondaryLabelColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        button.setAccessibilityLabel(title)
        return button
    }

    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

class SurfaceView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var strokeColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 12

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class PillView: SurfaceView {
    let label: NSTextField

    init(_ text: String, color: NSColor = Theme.accent) {
        label = Theme.label(text, size: 10, weight: .semibold, color: color)
        super.init(frame: .zero)
        cornerRadius = 7
        fillColor = color.withAlphaComponent(0.10)
        Theme.pin(label, to: self, inset: 5)
    }

    required init?(coder: NSCoder) { nil }
}
