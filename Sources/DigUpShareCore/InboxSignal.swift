import Foundation

public enum InboxSignal {
    public static let didChange = Notification.Name("com.yuezheng.digupplus.inbox.didChange")

    public static func post() {
        DistributedNotificationCenter.default().postNotificationName(
            didChange,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
