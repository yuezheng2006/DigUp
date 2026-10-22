#if os(macOS)
import Foundation
import ImageIO

public enum WeChatMedia {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: Redirects(), delegateQueue: nil)
    }()
    public static func allowed(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return ["qpic.cn", "qlogo.cn"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    public static func image(url: URL, media: WeChatMomentMedia? = nil) async throws -> Data {
        guard allowed(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw WeChatReadError.invalidResponse }
        parts.scheme = "https"
        if let media, !media.token.isEmpty {
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "token", value: media.token), URLQueryItem(name: "idx", value: media.index)]
        }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let target = parts.url else { throw WeChatReadError.invalidResponse }
        let (stream, response) = try await session.bytes(from: target)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 8 * 1024 * 1024 else { throw WeChatReadError.invalidResponse }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < 8 * 1024 * 1024 else { throw WeChatReadError.outputLimit }
            data.append(byte)
        }
        if let media, let seed = UInt64(media.key), CGImageSourceCreateWithData(data as CFData, nil).map({ CGImageSourceGetCount($0) }) ?? 0 == 0 {
            data = MomentsCipher.decode(data, seed: seed)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 800,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw WeChatReadError.invalidResponse }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { throw WeChatReadError.invalidResponse }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw WeChatReadError.invalidResponse }
        return result as Data
    }
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map { WeChatMedia.allowed($0) && $0.scheme == "https" } == true ? request : nil)
        }
    }
}
#endif
