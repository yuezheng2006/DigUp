# DigUp Plus 分发与 Gatekeeper

Mac mini 实测（`v0.7.0-plus.1`）：包完整、签名校验通过，但 **`spctl --assess` → `rejected`**。  
换机 / 浏览器下载都会撞同一道拦截。

## 先说结论（没有付费 Apple 开发者账号时）

**Apple 不给「免费」的对外双击安装通道。**  
`Developer ID` + `notarytool` 公证绑定在付费 Apple Developer Program（约 $99/年）上；没有它，任何下载的 `.app` / `.dmg` / `.zip` 在别人电脑上都会被 Gatekeeper 拦（或必须右键打开）。

因此 DigUp Plus **默认按「源码自建 / 开发测试」交付**，不假装可正式公证分发。

| 路径 | 要不要付费账号 | 别人能不能双击 | 适用 |
|---|---|---|---|
| **A. 源码安装**（推荐） | 否 | 本机编译的应用，无「下载隔离」问题 | 会用终端的用户、Mac mini 验收 |
| **B. 开发测试 ZIP + 右键打开** | 否（现有 Development 证书即可） | 不能双击；需右键 / 隐私设置 | 熟人内测 |
| **C. Developer ID + 公证** | 是 | 可以 | 对外公开发布（暂不做） |

---

## 路径 A — 源码安装（推荐、零付费）

在目标 Mac（含 Mac mini）上：

```bash
git clone git@github.com:yuezheng2006/DigUp.git
cd DigUp
git checkout sync/upstream-20261027   # 或你指定的 Plus 分支
./scripts/plus-install-from-source.sh
```

脚本会：`./build.sh` → 把 `build.noindex/DigUp.app` 拷到 `~/Applications/DigUp Plus.app`（可改 `INSTALL_DIR`）。

要点：

- 应用在**本机编译**，一般没有浏览器下载的 quarantine，Gatekeeper 不按「不明开发者下载包」拦截  
- 仍需 Xcode / CLT；首次编译较慢  
- 分享扩展：系统设置 → 通用 → 登录项与扩展 → 分享 → 勾选 DigUp Plus  
- 读微信库另需本机 `wx`；合并转发分享路径不依赖 wx  

---

## 路径 B — 开发测试包（不付费、需手动放行）

用现有 **Apple Development** 签名打 ZIP/DMG 可以，但 Release 必须写明：

> **开发测试包 · 非公证 · 请右键打开，不要指望双击安装**

用户步骤：

1. 下载后解压  
2. **右键 App → 打开** → 仍提示再点打开  
3. 或：系统设置 → 隐私与安全性 → 仍要打开  
4. 自愿测试者可：`xattr -dr com.apple.quarantine /path/to/DigUp.app`（不能当正式方案）  
5. 勾选分享扩展（同上）

限制：

- Share / App Group 换机可能不稳定（Development / 个人 Team 限制）  
- 不要把这类包标成「正式版」

预检（有 Developer ID 才会放行正式发布脚本）：

```bash
./scripts/check-plus-distribution.sh
```

无付费证书时预检失败是**预期行为**，表示：别走 `plus-release.sh` 假装公证。

---

## 路径 C — 付费账号后的正式分发（可选、以后再说）

若以后办了 Apple Developer Program：

1. 创建 `Developer ID Application`（Team 与 App Group 一致）  
2. `xcrun notarytool store-credentials …`  
3. `NOTARY_PROFILE=… ./scripts/plus-release.sh`  
4. 另一台 Mac：`spctl --assess` 必须为 `accepted`

细节仍见下文「正式解法」；当前产品策略**不依赖**这一条。

<details>
<summary>正式解法步骤（有付费账号时展开）</summary>

1. Apple Developer → Certificates → `Developer ID Application`  
2. 登记 App Group：`3396ALL92C.group.com.yuezheng.digupplus.shared`  
3. `xcrun notarytool store-credentials DigUpPlus --apple-id … --team-id …`  
4. `NOTARY_PROFILE=DigUpPlus ./scripts/plus-release.sh`  
5. `spctl --assess --type execute --verbose=2 DigUp.app` → `accepted`

</details>

---

## 发布门禁

| 检查项 | 源码安装 | Development 测试包 | Developer ID + 公证 |
|---|---|---|---|
| 无付费账号 | ✅ | ✅（右键） | ❌ |
| 浏览器双击 | n/a | ❌ | ✅ |
| 对外文案 | 「从源码安装」 | 「开发测试 / 右键打开」 | 「正式安装」 |

`scripts/plus-release.sh` 在缺少 Developer ID 时直接失败，避免再发「看起来完整、换机必拦」却标成正式的包。

## 相关

- Mac mini 实测：`0.7.0-plus.1` Development → Gatekeeper rejected  
- 上游 / Dukou 正式包均依赖付费 Developer ID  
- 本仓库选择：先把 **路径 A/B** 做稳，付费公证列为可选升级
