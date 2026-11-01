# DigUp Plus（中文）

[English / upstream README](README.md) · [本 fork](https://github.com/yuezheng2006/DigUp)

**DigUp Plus** = 开源 [DigUp](https://github.com/ARahim3/DigUp) 的增强分支：本机语义搜索 + 简体中文界面 + 微信能力 + 分享扩展 + Agent Skill。  
工作分支：`sync/upstream-20261027`。

## 快速开始

```sh
git clone git@github.com:yuezheng2006/DigUp.git
cd DigUp
git checkout sync/upstream-20261027
./scripts/plus-install-from-source.sh
open ~/Applications/DigUp\ Plus.app
```

首次启动按引导下载模型并选择索引目录。  
**无付费 Apple 开发者账号**：请用源码安装或「开发测试包 + 右键打开」，不要期望浏览器下载双击安装。详见 [DIGUP_PLUS_DISTRIBUTION.zh-CN.md](DIGUP_PLUS_DISTRIBUTION.zh-CN.md)。

## 中文文档（请从这里进）

| 文档 | 说明 |
|---|---|
| **[docs/GUIDE.zh-CN.md](docs/GUIDE.zh-CN.md)** | **完整指南**：安装、引导、Skill、微信、排障 |
| [docs/USAGE.zh-CN.md](docs/USAGE.zh-CN.md) | 推荐用法姿势 |
| [docs/SKILL.zh-CN.md](docs/SKILL.zh-CN.md) | Agent Skill 与模糊检索 |
| [WECHAT.zh-CN.md](WECHAT.zh-CN.md) | 微信读取 / HTML 导出 / 合并转发分享 |
| [DIGUP_PLUS_DISTRIBUTION.zh-CN.md](DIGUP_PLUS_DISTRIBUTION.zh-CN.md) | Gatekeeper 与无付费分发 |
| [skills/digup-local/SKILL.md](skills/digup-local/SKILL.md) | Skill 机器可读说明 |

上游英文用户手册仍在 `website/content/docs/`（安装、索引、搜索技巧等）。

## 能力一览

- **语义搜索**：图片、截图、PDF、文档、音视频片段、代码（`code:`）  
- **中文界面**：macOS 引导 / 搜索 / 设置；系统语言可覆盖  
- **微信**：会话浏览、HTML 报告（头像、OCR、页内搜索）、增量导出  
- **合并转发分享**：暂存架、Prompt、Markdown / Obsidian、Claude / Codex  
- **Skill**：`skills/digup-local` 供 Agent 查同一索引  

## 构建说明

需要 macOS 14+、Xcode、Swift 6.2+、git、CMake。`./build.sh` 会编译固定版本 llama.cpp。  
产物默认 Apple Development / 本机签名，**不是** Apple 公证发行包。

开发时指定简体中文：

```sh
build.noindex/DigUp.app/Contents/MacOS/DigUp -AppleLanguages '(zh-Hans)'
```

## 更新

「检查更新」打开本 fork 的 [Releases](https://github.com/yuezheng2006/DigUp/releases)。在具备 Developer ID 公证前，请按测试包说明安装，或始终源码更新。

## 验证

```sh
scripts/check-localization.sh
swift test --filter 'WeChatExportTests|WeChatMarkdownExportTests|DigUpShareCoreTests'
cd skills/digup-local && python3 scripts/digup.py --app ../../build.noindex/DigUp.app doctor
```
