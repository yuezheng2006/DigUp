# DigUp Plus CLI 使用指南

适用于 DigUp Plus 0.7.0-plus.2（build 15）。本页描述增强版安装包的能力；当前公开仓库源码与上游应用不一定包含这些功能。增强版应用和 Skill 预览包请从项目维护者提供的渠道获取，本页不承诺已有公开下载包。

## 1. 找到安装版 CLI

macOS 安装包自带 helper，无需另外运行索引服务：

```sh
DIGUP_APP='/Applications/DigUp.app'
# 如果源码安装在用户目录，改用：
# DIGUP_APP="$HOME/Applications/DigUp Plus.app"
DIGUP_CLI="$DIGUP_APP/Contents/Helpers/digup"
test -x "$DIGUP_CLI"
"$DIGUP_CLI" --help
"$DIGUP_CLI" status
```

文件搜索需要先在应用中完成目录授权、模型准备和首次索引。微信查询另外需要本机兼容读取器及有效配置；装好应用不等于微信已接入。不要把读取错误解释为没有消息。

## 2. 搜索文件、图片与视频

```sh
"$DIGUP_CLI" search '上次讨论的开发环境配置' --kind doc -n 5 --json
"$DIGUP_CLI" search '海边日落' --kind image -n 5 --json
"$DIGUP_CLI" search '会议演示片段' --kind video -n 5 --json
```

类型可选 `screenshot,image,pdf,doc,audio,video`。自定义索引目录时追加 `--index '/实际路径/index.noindex'`。核对结果中的路径、摘录、页码或时间点后再回答；分数不是正确概率，也不是置信度百分比。图片相似不能证明人物身份。当前文件 `search` 命令和 `wechat search` 是不同入口，Agent 查微信应显式调用后者。

## 3. 微信：先确认会话，再读取

```sh
"$DIGUP_CLI" wechat sessions --limit 200
```

从返回 `sessions` 中按 `name` 确认目标，取 `username` 作为会话 ID。同名需区分，不能直接把群名当 ID。会话列表最多 200 条，不是全量通讯录；未出现不代表联系人不存在。群 ID 通常以 `@chatroom` 结尾，公众号不作为群聊。

将以下示例 ID 和日期替换为实际值：

```sh
CHAT_ID='已确认的会话ID'
"$DIGUP_CLI" wechat history "$CHAT_ID" --since 2026-11-01 --until 2026-11-08 --limit 200 --offset 0
"$DIGUP_CLI" wechat history "$CHAT_ID" --since 2026-11-01 --until 2026-11-08 --limit 200 --offset 200
"$DIGUP_CLI" wechat search '开发环境' --in "$CHAT_ID" --since 2026-11-01 --until 2026-11-08 --limit 50
```

按本地时间理解日期范围，结束边界不包含当天；示例覆盖 11 月 1 日至 7 日。保留读取器返回的覆盖信息。只有 `history` 支持 `--offset`；逐页检查，空页或重复页停止，不把一页当成全部历史。微信命令默认 20 条，`--limit` 为 1–200，直接返回 JSON，不需再加 `--json`。

| 命令 | 可用参数 |
| --- | --- |
| `wechat sessions` | `--limit` |
| `wechat history CHAT` | `--since --until --limit --offset` |
| `wechat search QUERY` | `--in --since --until --limit` |
| `wechat sns-feed` | `--user --since --until --limit` |
| `wechat sns-search QUERY` | `--user --since --until --limit` |

朋友圈只读本机缓存可用数据，不等于完整时间线：

```sh
"$DIGUP_CLI" wechat sns-feed --since 2026-11-01 --until 2026-11-08 --limit 20
"$DIGUP_CLI" wechat sns-search '旅行' --limit 10
```

保留 `source`、`freshness`、`truncation` 等实际返回的元数据。`windowed`、未缓存、读取失败均应明确说明。当前没有 `--sender`、自动任务跟踪或发送消息命令。

## 4. 导出报告在哪里

**当前 CLI/Skill 没有会话报告导出命令。** 使用应用「微信 → 选择会话 → 导出…」，选择全部消息或日期范围、保存目录；OCR 和增量选项在「更多选项」中。

导出是目录，包含 `index.html`、`stats.html`、`messages.txt`、`messages.json`、`corpus.jsonl` 和可用媒体。完成后可以「打开报告」「查看概览」「打开导出目录」；报告页提供 JSON/JSONL 下载链接。缺少原始缓存的媒体不能凭空补全。把查询 stdout 重定向为 JSON 仅是保存查询结果，不是这个完整报告导出。

## 5. 后台与排障

关闭窗口后应用可继续驻留菜单栏；退出应用会停止它管理的后台工作。登录启动在应用设置中控制；睡眠期间不承诺持续更新。CLI 能返回结果不代表索引正在更新。

| 现象 | 检查 |
| --- | --- |
| 文件不存在/不可执行 | 应用实际名称及 `Contents/Helpers/digup` 路径 |
| `wechat` 未知命令 | 使用了上游或旧版 helper；核对增强版安装版本 |
| `reader missing` | 在应用中完成本机微信读取器配置 |
| 查询无结果 | 查索引范围、模型状态、会话范围和数据覆盖，不直接调低门槛凑结果 |
| 日期报错 | `YYYY-MM-DD`，结束日期必须晚于开始日期 |
| 数据似乎过旧 | 查看返回的缓存/覆盖信息及应用刷新状态 |

聊天内容与索引默认在本机读取，但 CLI 可能写查询日志；将内容交给外部 Agent/模型属于另一个数据流，应遵循用户授权。不要上传数据库、密钥或完整聊天作为排障材料。

Agent 自然语言使用方法见 [Skill 指南](SKILL.zh-CN.md)。
