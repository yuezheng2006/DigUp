#if os(macOS)
import Foundation
import Testing
@testable import DigUpKit

@Suite struct WeChatMomentsTests {
    @Test func rejectsErrorsAndInvalidRanges() throws {
        let reader = WeChatMomentsProvider(run: { _ in Data("{\"error\":\"unavailable\"}".utf8) })
        #expect(throws: (any Error).self) { try reader.moments(query: "", author: "", since: nil, until: nil) }
        let noCall = WeChatMomentsProvider(run: { _ in Issue.record("Invalid input reached reader"); return Data("[]".utf8) })
        #expect(throws: (any Error).self) { try noCall.moments(query: "", author: "", since: "2026-02-30", until: nil) }
        #expect(throws: (any Error).self) { try noCall.moments(query: "", author: "", since: "2026-10-22", until: "2026-10-21") }
        #expect(throws: (any Error).self) { try noCall.moments(query: "--init", author: "", since: nil, until: nil) }
    }
    @Test func routesSearchAndDoesNotExposeMediaSecrets() throws {
        let reader = WeChatMomentsProvider(run: { args in
            #expect(args.prefix(2) == ["sns-search", "旅行"])
            #expect(args.contains("--user"))
            return Data(#"[{"tid":1,"author":"Author","content":"Text","timestamp":1234,"media":[{"url_key":"secret"}]}]"#.utf8)
        })
        let rows = try reader.moments(query: "旅行", author: "Author", since: nil, until: nil)
        #expect(rows.count == 1)
        #expect(rows[0].mediaCount == 1)
        #expect(rows[0].content == "Text")
    }
}
#endif
