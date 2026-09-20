import Foundation

enum DemoContent {
    static let context = AppContext(
        appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Atlas · 开发者设置",
        fieldRole: "AXTextField", fieldLabel: "Webhook URL · staging 回调地址",
        surroundingText: "填写 Atlas staging 环境的 webhook 回调 URL。", hasAccessibility: true
    )

    static var entries: [ClipboardEntry] {
        let samples: [(String, ClipKind, String)] = [
            ("周五见！设计稿已经更新，记得看看新的交互细节。", .text, "微信"),
            ("https://github.com/example/atlas/issues/481", .url, "Safari"),
            ("let panel = NSPanel()\npanel.level = .floating\npanel.hidesOnDeactivate = false", .code, "Xcode"),
            ("https://api.atlas.example/staging/webhooks", .url, "备忘录"),
            ("design@atlas.example", .email, "邮件"),
            ("#6366F1", .color, "Figma"),
            ("git switch -c feature/contextual-paste", .command, "终端"),
            ("让工具退后一步，让想法向前一步。\n\n好的设计，从一次不被打断的心流开始。", .text, "备忘录")
        ]
        return samples.enumerated().map { index, sample in
            ClipboardEntry(copiedAt: Date().addingTimeInterval(-Double(index + 1) * 90),
                           text: sample.0, kind: sample.1, sourceApp: sample.2,
                           payloads: [PasteboardPayload(representations: ["public.utf8-plain-text": Data(sample.0.utf8)])])
        }
    }
}
