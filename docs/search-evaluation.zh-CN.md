# 检索质量评测

工具只计算已保存的搜索结果，不访问微信、不调用网络、不构造搜索结果。`scripts/tests/test_search_evaluation.py` 中的人工 ID 仅用于验证指标算术，不是产品效果数据。

## 输入约定

`cases.json` 是数组，每项包含：

- `id`：唯一查询编号；`query`：原始查询；`category`：案例类别。
- `filters`：查询范围，例如 source、session、起止时间；与实际运行必须相同。
- `relevant_ids`：人工确认的相关结果 ID 数组。
- `exhaustive`：只有人工检查完本次固定语料及过滤范围，才能填 `true`。仅标注搜索返回的前几条不能证明召回率。空数组且 exhaustive=true 表示确认无答案。

`runs.json` 是对象，包含 `metadata` 和 `runs`。metadata 必填非空字符串：`commit`、`model`、`corpus_revision`、`measured_at`、`timing`（说明硬件、冷/热启动、计时范围及是否含模型加载）。runs 数组每项包含 `id`、`query`、`filters`、按真实排名排列的 `result_ids` 和非负有限数值 `latency_ms`。

每个 case 必须且只能运行一次。结果不能为了提高指标在评分前随意删减；用生产查询的正常展示/截断策略，记录该策略。若要完整 Recall@50，真实运行应请求至少 50 条或确认结果已耗尽，不能拿 UI 默认 5 条当完整召回。重复试验分成独立 runs 文件，避免重复 case ID。

ID 在标注和结果中必须一致：文件以文件为单位，微信以消息为单位，朋友圈以动态为单位；多个命中片段先按生产去重规则归并。不得混用“文件数”和“片段数”。ID 可本地脱敏；私密数据文件不要放进仓库。

## 运行

```sh
python3 scripts/evaluate-search.py --cases /private/path/cases.json --runs /private/path/runs.json --output /private/path/report.json
python3 -m unittest discover -s scripts/tests -p 'test_search_evaluation.py'
```

工具拒绝缺失查询、重复结果、范围不一致和非法耗时。输出总体与 category 分组指标、每条查询指标和运行元数据。

## 指标口径

- Precision@10 = 前 10 条中相关条数 / 10。不足 10 条仍除以 10；它衡量固定槽位，不是“已返回结果的正确比例”。
- Recall@50 = 前 50 条中相关条数 / 全部相关条数。只统计 exhaustive=true 且相关集合非空的查询。
- 无答案误报率 = 确认无答案但返回任意结果的查询数 / 确认无答案查询数。无答案不计入普通 precision/recall 均值，单独评估。
- P95 = 按耗时排序后第 ceil(0.95 × N) 个值（nearest-rank）。包括全部查询；样本少时只作观察，不作为稳定性能结论。
- 未完整标注的查询不计算 precision/recall/无答案指标，报告 null 和未标注数量；不能把 null 写成 0 或 100%。总体是查询级宏平均，同时给出每项分母。

评分器只能检查输入一致性，不能证明标签正确、结果来自真实运行或来源授权。验收仍需保留本地原始输出、语料快照及标注记录。当前尚未交付生产查询的自动采集适配器，输入需从真实运行导出整理；未来应复用应用/CLI，而非实现另一套搜索。
