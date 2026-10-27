import DigUpShareCore
import Foundation
import Testing
import zlib

@Suite struct WeChatForwardZIPTests {
    @Test func parsesNativeTranscript() throws {
        let body = """
        ·甲
        2026年9月5日 08:05
        你好

        ·乙
        2026年9月5日 08:06
        世界
        """
        let records = try WeChatTranscriptRecord.parse(body)
        #expect(records.count == 2)
        #expect(records[0].sender == "甲")
        #expect(records[0].text == "你好")
        #expect(records[1].sender == "乙")
        #expect(records[1].text == "世界")
    }

    @Test func readsStoredZipTranscript() throws {
        let text = """
        ·vincent_yang
        2026年10月26日 11:36
        hello from DigUp Plus

        ·何继成
        2026年10月26日 11:42
        收到
        """
        let zip = try makeZip(entries: ["聊天记录.txt": Data(text.utf8), "images/a.jpg": Data([0xFF, 0xD8, 0xFF, 0xD9])])
        let transcript = try WeChatForwardZIP.transcript(zip)
        #expect(transcript?.path.hasSuffix("聊天记录.txt") == true)
        #expect(transcript?.records?.count == 2)
        #expect(try WeChatForwardZIP.messageCount(zip) == 2)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = try WeChatForwardZIP.extract(zip, to: dir)
        #expect(names.contains("聊天记录.txt"))
        #expect(names.contains("images/a.jpg"))
    }
}

/// Minimal stored (method 0) ZIP writer for tests.
private func makeZip(entries: [String: Data]) throws -> Data {
    var local = Data()
    var central = Data()
    var offsets: [Int] = []
    for (name, payload) in entries.sorted(by: { $0.key < $1.key }) {
        offsets.append(local.count)
        let nameData = Data(name.utf8)
        let crc = payload.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        local.append(contentsOf: u32(0x04034b50))
        local.append(contentsOf: u16(20)) // version needed
        local.append(contentsOf: u16(0))  // flags
        local.append(contentsOf: u16(0))  // method store
        local.append(contentsOf: u16(0))  // time
        local.append(contentsOf: u16(0))  // date
        local.append(contentsOf: u32(UInt32(crc)))
        local.append(contentsOf: u32(UInt32(payload.count)))
        local.append(contentsOf: u32(UInt32(payload.count)))
        local.append(contentsOf: u16(UInt16(nameData.count)))
        local.append(contentsOf: u16(0)) // extra
        local.append(nameData)
        local.append(payload)

        central.append(contentsOf: u32(0x02014b50))
        central.append(contentsOf: u16(20)) // version made by
        central.append(contentsOf: u16(20)) // version needed
        central.append(contentsOf: u16(0))
        central.append(contentsOf: u16(0))
        central.append(contentsOf: u16(0))
        central.append(contentsOf: u16(0))
        central.append(contentsOf: u32(UInt32(crc)))
        central.append(contentsOf: u32(UInt32(payload.count)))
        central.append(contentsOf: u32(UInt32(payload.count)))
        central.append(contentsOf: u16(UInt16(nameData.count)))
        central.append(contentsOf: u16(0)) // extra
        central.append(contentsOf: u16(0)) // comment
        central.append(contentsOf: u16(0)) // disk
        central.append(contentsOf: u16(0)) // int attr
        central.append(contentsOf: u32(0o100000 << 16)) // ext attr file
        central.append(contentsOf: u32(UInt32(offsets.last!)))
        central.append(nameData)
    }
    let centralOffset = local.count
    local.append(central)
    local.append(contentsOf: u32(0x06054b50))
    local.append(contentsOf: u16(0))
    local.append(contentsOf: u16(0))
    local.append(contentsOf: u16(UInt16(entries.count)))
    local.append(contentsOf: u16(UInt16(entries.count)))
    local.append(contentsOf: u32(UInt32(central.count)))
    local.append(contentsOf: u32(UInt32(centralOffset)))
    local.append(contentsOf: u16(0))
    return local
}

private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func u32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
}
