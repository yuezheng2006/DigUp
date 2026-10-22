import Foundation

public enum MomentsFilter {
    /// A reversible content heuristic, not a statement about the author's identity.
    public static func suspectedAdvertisement(_ text: String) -> Bool {
        let terms = ["限时优惠", "扫码下单", "招商加盟", "代理招募", "加我咨询", "优惠券", "全国包邮", "特价促销", "团购价", "现货批发"]
        return terms.contains { text.contains($0) }
    }
}
