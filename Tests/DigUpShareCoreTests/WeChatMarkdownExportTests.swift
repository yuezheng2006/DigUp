import DigUpShareCore
import Foundation
import Testing

@Suite struct WeChatMarkdownExportTests {
    @Test func rendersRecordsWithFrontMatter() throws {
        let records = try WeChatTranscriptRecord.parse("""
        ·甲
        2026年10月26日 11:36
        你好

        ·乙
        2026年10月26日 11:42
        世界
        """)
        let md = WeChatMarkdownExport.render(
            title: "测试群",
            records: records,
            body: "",
            mediaRelativePaths: ["images/a.jpg"],
            flavor: .markdown
        )
        #expect(md.contains("title: \"测试群\""))
        #expect(md.contains("generator: DigUp Plus"))
        #expect(md.contains("## 2026-10-26"))
        #expect(md.contains("### 甲 · 11:36"))
        #expect(md.contains("你好"))
        #expect(!md.contains("tags:"))
        #expect(md.contains("![a.jpg](images/a.jpg)") || md.contains("[a.jpg](images/a.jpg)"))
    }

    @Test func obsidianFlavorAddsTagsAndCssclasses() throws {
        let records = try WeChatTranscriptRecord.parse("""
        ·甲
        2026年10月26日 11:36
        方案定稿
        """)
        let md = WeChatMarkdownExport.render(
            title: "验收群",
            records: records,
            body: "",
            flavor: .obsidian
        )
        #expect(md.contains("tags:"))
        #expect(md.contains("- wechat"))
        #expect(md.contains("- digup-plus"))
        #expect(md.contains("cssclasses:"))
        #expect(md.contains("- digup-wechat"))
        #expect(md.contains("### 甲 · 11:36"))
        #expect(md.contains("方案定稿"))
    }

    @Test func writeBundleMarkdownAndObsidianFromForwardZIP() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("digup-md-bundle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let zip = root.appendingPathComponent("forward.zip")
        // Reuse fixture next to this test via Documents smoke zip when present; else synthesize.
        let smoke = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/github/tmp-digup-share-smoke/forward-md-smoke.zip")
        if FileManager.default.fileExists(atPath: smoke.path) {
            try FileManager.default.copyItem(at: smoke, to: zip)
        } else {
            throw WeChatReadError.invalidTranscript
        }

        let mdOut = root.appendingPathComponent("md", isDirectory: true)
        let mdResult = try WeChatMarkdownExport.writeBundle(
            zipURLs: [zip], to: mdOut, flavor: .markdown)
        #expect(FileManager.default.fileExists(atPath: mdResult.markdownURL.path))
        #expect(mdResult.recordCount >= 2)
        #expect(mdResult.mediaCount >= 1)
        let mdText = try String(contentsOf: mdResult.markdownURL, encoding: .utf8)
        #expect(mdText.contains("generator: DigUp Plus"))
        #expect(!mdText.contains("tags:"))
        #expect(mdText.contains("方案定稿") || mdText.contains("你好"))
        #expect(mdText.contains("![") || mdText.contains("images/"))

        let obOut = root.appendingPathComponent("obsidian", isDirectory: true)
        let obResult = try WeChatMarkdownExport.writeBundle(
            zipURLs: [zip], to: obOut, flavor: .obsidian)
        let obText = try String(contentsOf: obResult.markdownURL, encoding: .utf8)
        #expect(obText.contains("tags:"))
        #expect(obText.contains("cssclasses:"))
        #expect(obResult.recordCount == mdResult.recordCount)
        #expect(FileManager.default.fileExists(
            atPath: obOut.appendingPathComponent("batch-1/images/a.jpg").path)
            || FileManager.default.fileExists(
                atPath: obOut.appendingPathComponent("batch-1/images").path))
    }

    @Test func preferencesRoundTrip() {
        var prefs = SharePreferences()
        prefs.attachPromptToForwards = false
        prefs.customTargets = [
            ForwardTarget(bundleIdentifier: "com.example.app", displayName: "Example")
        ]
        prefs.normalize()
        #expect(prefs.selectedPrompt != nil)
        #expect(prefs.promptTextForForward() == nil)
        prefs.attachPromptToForwards = true
        #expect(prefs.promptTextForForward()?.contains("总结") == true)
    }
}
