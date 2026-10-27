import AppKit
import Foundation

public enum FilePasteboard {
    @discardableResult
    public static func write(_ urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    @discardableResult
    public static func writeText(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
