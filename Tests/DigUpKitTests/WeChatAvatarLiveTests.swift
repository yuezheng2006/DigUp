#if os(macOS)
import Foundation
import ImageIO
import Testing
@testable import DigUpKit

@Suite struct WeChatAvatarLiveTests {
    @Test func loadsLocalProfilesAndFetchesQlogoAvatars() async throws {
        let profiles = WeChatProfiles.load()
        #expect(profiles.people.count > 100)
        let person = try #require(profiles.people.values.first {
            !$0.username.hasSuffix("@chatroom") && $0.avatar != nil
                && ($0.avatar!.host?.contains("qlogo.cn") == true)
        })
        let group = try #require(profiles.people.values.first {
            $0.username.hasSuffix("@chatroom") && $0.avatar != nil
                && ($0.avatar!.host?.contains("qlogo.cn") == true)
        })
        for url in [person.avatar!, group.avatar!] {
            #expect(WeChatMedia.allowed(url))
            let data = try await WeChatMedia.image(url: url)
            #expect(CGImageSourceCreateWithData(data as CFData, nil) != nil)
            #expect(data.count > 100)
        }
    }
}
#endif
