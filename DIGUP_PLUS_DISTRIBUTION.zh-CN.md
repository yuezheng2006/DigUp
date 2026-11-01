# DigUp Plus 分发与 Gatekeeper

Mac mini 实测（`v0.7.0-plus.1`）：包本身完整、签名校验通过，但 **`spctl --assess` → `rejected`**。  
原因不是芯片架构或 ZIP 损坏，而是 **当前用 Apple Development 签名，未做 Developer ID + 公证**。  
换机 / 浏览器下载的用户都会撞上同一道拦截。

## 用户会看到什么

- 双击提示「无法打开，因为无法验证开发者」或「已损坏」类文案  
- 分享扩展、App Group 在未正确 Team 签名时不稳定  
- 开发机本机 `./build.sh` 跑通 ≠ 别人下载后能双击安装

## 正确解法（对外可双击）

与上游 DigUp / Dukou 同一条路：

1. **Apple Developer → Certificates** 创建  
   `Developer ID Application`（Team：`3396ALL92C`）  
   装入本机钥匙串后：
   ```bash
   security find-identity -v -p codesigning
   # 应出现：Developer ID Application: … (3396ALL92C)
   ```
2. **登记 App Group**（若尚未登记）  
   `3396ALL92C.group.com.yuezheng.digupplus.shared`
3. **保存公证凭据（一次）**
   ```bash
   xcrun notarytool store-credentials DigUpPlus \
     --apple-id '你的AppleID' \
     --team-id 3396ALL92C
   # 使用 appleid.apple.com 生成的 App 专用密码
   ```
4. **发布**
   ```bash
   ./scripts/check-plus-distribution.sh          # 预检
   SIGN_ID='Developer ID Application: … (3396ALL92C)' \
     NOTARY_PROFILE=DigUpPlus \
     ./scripts/plus-release.sh
   ```
5. 用新 DMG 在**另一台 Mac**跑：
   ```bash
   spctl --assess --type execute --verbose=2 /path/to/DigUp.app
   # 期望：accepted
   ```

上游脚本即 `scripts/release.sh`；`plus-release.sh` 只是 DigUp Plus 预检 + 版本展示包装。

## 公证完成前（仅测试用户）

不要把 Development 包标成「正式安装」。Release 说明应写清：

1. 下载后：**右键 App → 打开** → 仍提示则再点打开  
2. 或：系统设置 → 隐私与安全性 → 仍要打开  
3. 分享扩展：系统设置 → 通用 → 登录项与扩展 → 分享 → 勾选 DigUp Plus 各项  
4. 直接读微信历史另需本机 `wx`（与合并转发分享路径独立）

临时绕过隔离属性（仅自愿测试者）：

```bash
xattr -dr com.apple.quarantine /Applications/DigUp.app
```

这**不能**替代公证；也不能保证 Share / App Group 在所有机器可用。

## 发布门禁（给维护者）

| 检查项 | Development 包 | Developer ID + 公证 |
|---|---|---|
| 本机 `./build.sh` 开发 | ✅ | ✅ |
| 浏览器下载双击 | ❌ Gatekeeper | ✅ |
| `spctl --assess` | rejected | accepted |
| 分享扩展 / App Group 换机 | 不可靠 | 应用 Team 后可用 |
| 对外 Release 标签 | 仅标「开发测试」 | 可标正式 |

`./scripts/check-plus-distribution.sh` 在缺少 Developer ID 或 notary 配置时会非零退出，避免再发出「看起来完整、换机必拦」的包。

## 相关

- Mac mini 实测评论（ISSUE-303）：`0.7.0-plus.1` Development 签名被拒  
- 上游对照：ARahim3/DigUp 正式包为 Developer ID + Notarized  
- Dukou 正式包同为 Developer ID Application
