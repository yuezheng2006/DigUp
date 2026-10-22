---
name: digup-local
description: 配合 macOS DigUp 应用检查本地索引、按内容搜索文件并返回可追溯出处；用户希望 Agent 使用本机 DigUp 找资料时使用。
---

# DigUp 配套 Skill

应用管理目录授权、模型、后台文件监听和索引；Skill 调用应用自带 CLI 查询同一份索引。不要另建索引服务或下载另一套模型。

在此 Skill 目录运行：

```sh
python3 scripts/digup.py doctor
python3 scripts/digup.py status
python3 scripts/digup.py search '记得的内容' --limit 5
python3 scripts/digup.py search '海边日落' --kind video --limit 5
```

- 默认查找 `/Applications/DigUp.app`，其次 `~/Applications/DigUp.app`。自定义位置用 `--app /path/DigUp.app`（放在子命令前）。
- 如应用设置了自定义索引目录，用 `--index /path/index.noindex`（放在子命令前）；不指定时沿用 CLI 默认目录。不要把另一个空索引误报为没有资料。
- 未安装、未授权目录或模型未就绪时说明实际缺项，引导在应用内完成设置。不自动改系统权限、登录项或扩大索引目录。
- 用户要求打开应用时运行 `python3 scripts/digup.py start`。关闭搜索窗口仍可留在菜单栏；退出应用会停止其后台工作。登录启动由应用设置控制，睡眠时不能承诺持续索引。CLI 查询自身可独立运行，不代表后台索引正在更新。
- `search` 返回 JSON，保留文件路径、页码/时间点和摘录作为出处，按需要阅读原始证据再回答。空结果直接说明未找到，不自动降低门槛凑结果。`score`、`z`、`cosine` 都不是正确概率，不能写成“置信度百分比”。对人名尤其不能仅凭画面相似度断言身份；姓名出现也只是文本提及。
- CLI 当前搜索本地文件索引，不包含应用独立微信页面的消息索引。微信会话查询/导出仍由应用完成，不虚构统一微信 CLI。不要读取其他账户的聊天或把命中内容自动上传外部服务；使用者要求总结时只取必要片段，并遵循所在环境的数据授权规则。
- 应用内置 helper 与安装版本一致。源码中的修复不等于已安装版本包含修复；doctor 只报告安装路径和版本，不证明检索质量。

脚本只暴露 doctor/status/search/start，不支持重建、删除或修改索引范围。CLI 会按自身实现写查询日志，不能承诺查询完全不落盘。
