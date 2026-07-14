# 内置古文字字形来源

本 App 的离线字库来自 Wikimedia Commons 的 Ancient Chinese Characters 项目。2026-07-14 枚举甲骨、金文、战国简帛/秦简和《说文》小篆分类，并核验文件页中的明确释读与许可模板。只有同时满足“明确对应一个编码汉字”和“Public Domain/CC0”的文件才可进入字库；`ACC-j00001` 一类编号绝不会被猜成汉字。

## 收录规模

- 有真实字形图片的现代字：3,996
- Unicode 扩展区 B 及以后生僻字：77
- App 内离线代表字形：6,404
- 甲骨文：597
- 金文：1,228
- 战国文字：729（战国金文、楚系简帛、秦简等）
- 小篆：3,850
- Commons 候选源文件：14,625
- 通过释读与授权核验：14,059
- 因无明确单字映射或许可模板而隔离：566

同一字、同一时代在 Commons 中可能有数十甚至上百个描摹变体。App 为每个“汉字 × 时代”组合选择一张文件名最明确的代表图，避免界面被重复变体淹没；全部 14,059 条通过核验的来源保留在 `Audit/commons-full-verified.json` 中供审计。每条入库记录显示时代、现代释读、Commons 原文件名、来源链接、细分时代说明和许可。原始 SVG 由 Commons 官方缩略图服务渲染为透明 PNG，字形轮廓未经过生成式 AI 修改。

## 可复现脚本

```bash
python3 Scripts/fetch_commons_glyphs.py --workers 1
```

脚本枚举 24 个 ACC 分类，使用 `Special:Export` 批量读取文件页源代码，从 `ACClicense` 的汉字参数或明确的单字文件名提取释读，并仅接受 ACC 公有领域、CC0 或明确的公有领域模板。下载阶段遵守 Wikimedia 限流并支持断点续传，最终生成 `Resources/glyph_catalog.json`、`Audit/commons-full-skipped.json` 和完整核验清单。

图标由 `Resources/Glyphs/古-oracle.png` 确定性排版生成：

```bash
python3 Scripts/build_app_icon.py
```

## 上游链接

- Wikimedia Commons Ancient Chinese Characters 项目：<https://commons.wikimedia.org/wiki/Commons:Ancient_Chinese_characters>
- 示例“馬”甲骨文：<https://commons.wikimedia.org/wiki/File:%E9%A6%AC-oracle.svg>
- 示例“馬”金文：<https://commons.wikimedia.org/wiki/File:%E9%A6%AC-bronze.svg>
- 示例“馬”小篆：<https://commons.wikimedia.org/wiki/File:%E9%A6%AC-seal.svg>

各文件的许可与贡献者信息以其 Commons 文件说明页为准。
