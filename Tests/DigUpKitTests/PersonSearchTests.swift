import Foundation
import Testing
@testable import DigUpKit

#if canImport(NaturalLanguage)
@Suite struct PersonSearchTests {
    @Test func personRequiresEvidenceAndOpensThatEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        var vector = [Float](repeating: 0, count: Vectors.dimension)
        vector[0] = 1
        let unrelated = try store.insert(Candidate(path: "/毛泽东/unrelated.mp4", kind: .video,
            size: 10, mtime: 1, inode: 1, device: 1))
        try store.addSegment(file: unrelated, kind: .frame, modality: .image, loc: 18, vector: vector)
        let relevant = try store.insert(Candidate(path: "/archive/documentary.mp4", kind: .video,
            size: 10, mtime: 1, inode: 2, device: 1))
        try store.addSegment(file: relevant, kind: .frame, modality: .image, loc: 18, vector: vector)
        try store.addSegment(file: relevant, kind: .frame, modality: .text, loc: 60,
            excerpt: "毛泽东的历史资料", text: "毛泽东的历史资料")
        let searcher = try Searcher(store: store)
        for query in ["毛泽东", "毛泽东的视频"] {
            let hits = try searcher.search(query, queryVector: vector, zGate: -1)
            #expect(hits.count == 1)
            #expect(hits.first?.path == "/archive/documentary.mp4")
            #expect(hits.first?.loc == 60)
        }
        #expect(try searcher.search("周恩来", queryVector: vector, zGate: -1).isEmpty)
        #expect(try searcher.search("海边日落", queryVector: vector, zGate: -1).count == 2)
        let keywordOnly = try searcher.search("毛泽东", queryVector: nil)
        #expect(keywordOnly.count == 1)
        #expect(keywordOnly.first?.loc == 60)
        _ = try store.insert(Candidate(path: "/archive/毛泽东.mp4", kind: .video,
            size: 10, mtime: 1, inode: 3, device: 1))
        let refreshed = try Searcher(store: store)
        let titled = try refreshed.search("毛泽东", queryVector: nil, kinds: [.video])
        #expect(titled.count == 2)
        #expect(titled.contains { $0.path == "/archive/毛泽东.mp4" && $0.loc == nil })
    }
}
#endif
