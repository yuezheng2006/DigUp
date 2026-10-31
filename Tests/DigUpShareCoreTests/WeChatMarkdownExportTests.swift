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
            mediaRelativePaths: ["images/a.jpg"]
        )
        #expect(md.contains("title: \"测试群\""))
        #expect(md.contains("generator: DigUp Plus"))
        #expect(md.contains("## 2026-10-26"))
        #expect(md.contains("**甲**"))
        #expect(md.contains("你好"))
        #expect(md.contains("![a.jpg](images/a.jpg)") || md.contains("[a.jpg](images/a.jpg)"))
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
