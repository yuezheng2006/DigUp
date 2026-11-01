import DigUpShareCore
import Foundation
import Testing

@Suite struct WeChatMarkdownLiveSmokeTests {
    @Test func materializeMarkdownAndObsidianArtifacts() throws {
        let zip = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/github/tmp-digup-share-smoke/forward-md-smoke.zip")
        #expect(FileManager.default.fileExists(atPath: zip.path))
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/github/tmp-digup-share-smoke")
        let mdDir = root.appendingPathComponent("export-markdown-smoke", isDirectory: true)
        let obDir = root.appendingPathComponent("export-obsidian-smoke", isDirectory: true)
        try? FileManager.default.removeItem(at: mdDir)
        try? FileManager.default.removeItem(at: obDir)
        let md = try WeChatMarkdownExport.writeBundle(zipURLs: [zip], to: mdDir, flavor: .markdown)
        let ob = try WeChatMarkdownExport.writeBundle(zipURLs: [zip], to: obDir, flavor: .obsidian)
        #expect(md.recordCount >= 2)
        #expect(ob.recordCount >= 2)
        print("MD_OK \(md.markdownURL.path)")
        print("OB_OK \(ob.markdownURL.path)")
    }
}
