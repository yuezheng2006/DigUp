#if os(macOS)
import Foundation
import Testing
@testable import DigUpKit

@Suite struct WeChatNameTests {
    @Test func preferredNamePrefersRemarkThenNickThenAlias() {
        let remarked = WeChatProfile(
            username: "csworld", alias: "", remark: "雷石武剑", nickName: "Jacky", avatar: nil, isEnterprise: false)
        #expect(remarked.preferredName == "雷石武剑")
        let nickOnly = WeChatProfile(
            username: "wxid_a", alias: "ali", remark: "", nickName: "Aaron 米粒", avatar: nil, isEnterprise: false)
        #expect(nickOnly.preferredName == "Aaron 米粒")
        let aliasOnly = WeChatProfile(
            username: "wxid_b", alias: "mike_alias", remark: "  ", nickName: "", avatar: nil, isEnterprise: false)
        #expect(aliasOnly.preferredName == "mike_alias")
        let bare = WeChatProfile(
            username: "wxid_c", alias: "", remark: "", nickName: "", avatar: nil, isEnterprise: false)
        #expect(bare.preferredName == "wxid_c")
    }

    @Test func directoryMapsUsernameAndUniqueNickInRoom() {
        var profiles = WeChatProfiles()
        profiles.people["csworld"] = WeChatProfile(
            username: "csworld", alias: "", remark: "雷石武剑", nickName: "Jacky", avatar: nil, isEnterprise: false)
        profiles.people["wxid_mike"] = WeChatProfile(
            username: "wxid_mike", alias: "", remark: "", nickName: "Michael", avatar: nil, isEnterprise: false)
        profiles.people["wxid_aaron"] = WeChatProfile(
            username: "wxid_aaron", alias: "", remark: "", nickName: "Aaron 米粒", avatar: nil, isEnterprise: false)
        let members = [
            WeChatMember(username: "csworld", contactDisplay: "雷石武剑", display: "雷石武剑", groupNickname: ""),
            WeChatMember(username: "wxid_mike", contactDisplay: "Michael", display: "Michael", groupNickname: ""),
            WeChatMember(username: "wxid_aaron", contactDisplay: "Aaron 米粒", display: "Aaron 米粒", groupNickname: "")
        ]
        let names = WeChatNameDirectory.build(members: members, profiles: profiles)
        #expect(names.displayName(for: "csworld") == "雷石武剑")
        #expect(names.displayName(for: "Michael") == "Michael")
        #expect(names.displayName(for: "Aaron 米粒") == "Aaron 米粒")
        #expect(names.displayName(for: "wxid_mike") == "Michael")
        #expect(names.username(for: "Michael") == "wxid_mike")
        #expect(names.username(for: "csworld") == "csworld")
        // History `sender` is often the remark / contact_display, not username.
        #expect(names.username(for: "雷石武剑") == "csworld")
        #expect(names.displayName(for: "雷石武剑") == "雷石武剑")
    }

    @Test func directoryResolvesAvatarFromNickOrUsername() {
        let avatar = URL(string: "https://wx.qlogo.cn/mmhead/example")!
        var profiles = WeChatProfiles()
        profiles.people["wxid_mike"] = WeChatProfile(
            username: "wxid_mike", alias: "", remark: "", nickName: "Michael",
            avatar: avatar, isEnterprise: false)
        profiles.people["csworld"] = WeChatProfile(
            username: "csworld", alias: "", remark: "雷石武剑", nickName: "Jacky",
            avatar: URL(string: "https://wx.qlogo.cn/mmhead/jacky"), isEnterprise: false)
        profiles.people["room@chatroom"] = WeChatProfile(
            username: "room@chatroom", alias: "", remark: "", nickName: "测试群",
            avatar: URL(string: "https://wx.qlogo.cn/mmcrhead/group"), isEnterprise: false)
        let members = [
            WeChatMember(username: "wxid_mike", contactDisplay: "Michael", display: "Michael", groupNickname: ""),
            WeChatMember(username: "csworld", contactDisplay: "雷石武剑", display: "雷石武剑", groupNickname: "")
        ]
        let names = WeChatNameDirectory.build(members: members, profiles: profiles)
        #expect(names.avatarURL(for: "Michael", in: profiles) == avatar)
        #expect(names.avatarURL(for: "wxid_mike", in: profiles) == avatar)
        #expect(names.avatarURL(for: "雷石武剑", in: profiles)?.absoluteString.contains("jacky") == true)
        #expect(profiles.people["room@chatroom"]?.avatar?.absoluteString.contains("mmcrhead") == true)
    }

    @Test func directoryMapsPrivatePeerWithoutMembersList() {
        let avatar = URL(string: "https://wx.qlogo.cn/mmhead/zhou")!
        var profiles = WeChatProfiles()
        profiles.people["wxid_peer"] = WeChatProfile(
            username: "wxid_peer", alias: "xzdgsZQF", remark: "周青峰", nickName: "高山",
            avatar: avatar, isEnterprise: false)
        let peer = WeChatMember(
            username: "wxid_peer", contactDisplay: "周青峰", display: "周青峰", groupNickname: "")
        let names = WeChatNameDirectory.build(members: [peer], profiles: profiles)
        #expect(names.displayName(for: "wxid_peer") == "周青峰")
        #expect(names.avatarURL(for: "wxid_peer", in: profiles) == avatar)
        // Empty-members path (wx members fails on private chats): still resolve via profiles.
        let global = WeChatNameDirectory.build(members: [], profiles: profiles)
        #expect(global.displayName(for: "wxid_peer") == "周青峰")
        #expect(global.avatarURL(for: "周青峰", in: profiles) == avatar)
    }

    @Test func directoryIgnoresSharedGroupNicknameQuirk() {
        var profiles = WeChatProfiles()
        profiles.people["csworld"] = WeChatProfile(
            username: "csworld", alias: "", remark: "雷石武剑", nickName: "Jacky", avatar: nil, isEnterprise: false)
        profiles.people["yuezheng2006"] = WeChatProfile(
            username: "yuezheng2006", alias: "", remark: "", nickName: "vincent_yang", avatar: nil, isEnterprise: false)
        // Observed wx bug: many members share group_nickname == another member's username.
        let members = [
            WeChatMember(username: "csworld", contactDisplay: "雷石武剑", display: "雷石武剑", groupNickname: ""),
            WeChatMember(username: "yuezheng2006", contactDisplay: "vincent_yang", display: "csworld", groupNickname: "csworld")
        ]
        let names = WeChatNameDirectory.build(members: members, profiles: profiles)
        #expect(names.displayName(for: "csworld") == "雷石武剑")
        #expect(names.displayName(for: "yuezheng2006") == "vincent_yang")
    }

    @Test func membersParserAcceptsBareArray() throws {
        let payload = Data("""
        [{"username":"csworld","contact_display":"雷石武剑","display":"雷石武剑","group_nickname":""},
         {"username":"wxid_a","contact_display":"Aaron 米粒","display":"Aaron 米粒","group_nickname":""}]
        """.utf8)
        let reader = WeChatReader { args in
            #expect(args == ["members", "room@chatroom", "--json"])
            return payload
        }
        let members = try reader.members(session: WeChatSession(id: "room@chatroom", name: "Room"))
        #expect(members.map(\.username) == ["csworld", "wxid_a"])
        #expect(members[0].contactDisplay == "雷石武剑")
    }
}
#endif
