# DigUp Plus 完整指南（中文）

产品名：**DigUp Plus**。本机语义搜索 + 微信能力 + Agent Skill。  
**不依赖付费 Apple 开发者账号**对外公证；安装默认走源码自建或「开发测试包 + 右键打开」。

## 文档地图

| 文档 | 内容 |
|---|---|
| [README.zh-CN.md](../README.zh-CN.md) | 仓库总览、构建入口 |
| [docs/USAGE.zh-CN.md](USAGE.zh-CN.md) | 日常用法姿势 |
| [docs/SKILL.zh-CN.md](SKILL.zh-CN.md) | Agent Skill 安装与模糊检索 |
| [WECHAT.zh-CN.md](../WECHAT.zh-CN.md) | 微信读取 / 导出 / 分享扩展 |
| [DIGUP_PLUS_DISTRIBUTION.zh-CN.md](../DIGUP_PLUS_DISTRIBUTION.zh-CN.md) | Gatekeeper / 无付费分发 |
| [docs/wechat-extension.md](wechat-extension.md) | 微信扩展边界 |
| 上游英文站 `website/content/docs/` | 索引、文件夹、排障等（英文） |

## 1. 安装（推荐：源码）

```sh
git clone git@github.com:yuezheng2006/DigUp.git
cd DigUp
git checkout sync/upstream-20261027
./scripts/plus-install-from-source.sh
open ~/Applications/DigUp\ Plus.app
```

需要：macOS 14+、Xcode / CLT、Swift 6.2+、网络（首次拉 llama.cpp）。

首次打开：按应用引导 **下载模型** → **选择要索引的文件夹**（建议包含 `Documents/github`、笔记库、下载目录等你常找的地方）。

## 2. 日常使用引导

1. 设置里打开「登录时打开」，应用驻留菜单栏。  
2. 关掉搜索窗口没关系，**不要退出应用**。  
3. 用快捷键唤起面板，用自然语言描述「记得的内容」。  
4. 微信：主窗口「微信」页；合并转发见设置「微信分享」。  
5. 导出：会话导出 HTML（含头像 / OCR 可选）或暂存架 → Markdown / Obsidian。

## 3. Agent Skill（截图同款引导）

Skill 目录：`skills/digup-local/`（含 `SKILL.md` + `scripts/digup.py`）。

把该目录交给 Claude Code / Cursor / Codex 等支持 Skill 的客户端，或在对话里 `@` 该 Skill。  
详细命令与模糊检索示例见 [SKILL.zh-CN.md](SKILL.zh-CN.md)。

最小自检：

```sh
cd skills/digup-local
python3 scripts/digup.py --app /Applications/DigUp.app doctor
python3 scripts/digup.py --app /Applications/DigUp.app status
python3 scripts/digup.py --app /Applications/DigUp.app search '记得的内容' --limit 5
```

源码构建可用：

```sh
python3 scripts/digup.py --app ../../build.noindex/DigUp.app doctor
```

## 4. 微信两条线（别混）

| 能力 | 依赖 | 说明 |
|---|---|---|
| 会话浏览 / HTML 导出 / OCR | 本机 `wx` | 能力优先，有协议风险提示 |
| 合并转发 → 分享扩展 | 系统分享 + App Group | 不依赖 wx；Development 包换机可能不稳 |

## 5. 无付费账号时怎么给别人用

见 [DIGUP_PLUS_DISTRIBUTION.zh-CN.md](../DIGUP_PLUS_DISTRIBUTION.zh-CN.md)：

- **优先**：对方机器源码安装  
- **次选**：开发测试 ZIP + 右键打开，Release 文案写明非公证  
- **不做**：假装「双击即可」的公证包

## 6. 排障速查

| 现象 | 处理 |
|---|---|
| 别人双击打不开 | 预期；走源码或右键打开 |
| Skill 说未安装 | `--app` 指到真实 `.app` |
| 搜索空 | 看 `status`；确认文件夹已索引、模型已下载 |
| 微信读不到 | 配置 wx；勿把「未配置」说成「没有聊天」 |
| 分享列表没有 DigUp | 系统设置 → 分享 → 勾选扩展 |
