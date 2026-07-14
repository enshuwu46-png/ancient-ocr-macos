# 字符关系与释义数据

字符关系来自 Unicode 17.0.0 的官方 Unihan 数据库快照：

- 来源：<https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip>
- 规范说明：<https://www.unicode.org/reports/tr38/>
- 直接异体：`kSimplifiedVariant`、`kTraditionalVariant`、`kZVariant`
- 相关异体：`kSemanticVariant`、`kSpecializedSemanticVariant`
- 后备释义：`kDefinition`（Unihan 原始英文释义）

`Resources/character_metadata.json` 完整覆盖字形清单中的 3,996 个编码字符。其中 1,268 字有直接异体关系，903 字有语义相关关系，3,626 字有 `kDefinition`。直接异体可作为查询别名；语义和专门语义异体可能依语境而变，只显示为“相关”，不会被系统强行当成同一个字。

中文释义优先来自中华民国教育部《重編國語辭典修訂本》2026-06-25 开放数据：

- 下载页：<https://language.moe.gov.tw/001/Upload/Files/site_content/M0001/respub/dict_reviseddict_download.html>
- 授权：CC BY-ND 3.0 台湾
- 处理：只选择“字数 = 1”且字头与本项目字符一致的原始释义；仅规范电子表格换行，不翻译或改写。
- 覆盖：教育部 3,473 字；另有 13 字使用中文维基词典“汉语／释义”段作为后备，共 3,486 字有中文解释。

古文字字形来源只给出编码汉字释读与时代信息，并不为每个时代提供可核实的历史词义。App 在每个已收录时代卡片中显示该字的可靠字义、该时代的现代释读和字形来源；这不表示同一释义已被考证为该时代的唯一古义，也不会自动编造逐时代词义变化。
