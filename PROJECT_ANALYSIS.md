# 古文字 OCR 项目分析

分析日期：2026-07-13  
分析对象：`~/Desktop/ancient_ocr_project`

## 1. 结论摘要

当前项目是一个面向竞赛提交格式的批量 OCR 推理包，不是查询器。它由一个 YOLO 字符检测模型和一个 EfficientNet-B0 字符分类模型串联组成：先从整张图片中检测字符框，再裁剪并分类，最后生成 `prediction.json`。

现有代码不能原样在 Apple Silicon Mac 上运行，因为 `generate_submission.py` 把设备硬编码为 CUDA，`run.sh` 又把 Linux 容器路径硬编码为 `/app`、`/saisdata` 和 `/saisresult`。模型权重本身是 PyTorch checkpoint，并非只适用于 x86；改为原生 arm64 Python、选择 `mps` 或 `cpu` 后有条件复用。原 `linux/amd64` Docker 镜像即使通过模拟运行，也不能把 Apple Metal/MPS 当作 CUDA 使用，因此不应作为 Mac 本机推理的首选方案。

识别 checkpoint 内带有 4113 个按顺序排列的标签，且分类头也是 4113 类，所以“类别索引 → 原始模型标签”映射存在。但是其中 616 个标签为 `ZHFD-...` 资料标识，项目没有提供把这些标识可靠映射为现代汉字的字典。不能把这些编号猜成汉字，也不能把所有 OCR 输出都直接跳转到现代字条。

## 2. 当前项目结构

```text
ancient_ocr_project/
├── code/
│   ├── generate_submission.py
│   └── __pycache__/generate_submission.cpython-310.pyc
├── models/
│   ├── README.md
│   ├── detector_best.pt
│   └── recognizer_best.pt
└── run.sh
```

未发现 `Dockerfile`、依赖清单、训练配置、训练/验证数据、示例图片、测试、数据库、Web 服务或前端。

模型文件在分析过程中仅做只读检查，未删除、覆盖或重新保存：

| 文件 | 大小 | SHA-256 |
|---|---:|---|
| `models/detector_best.pt` | 19,207,443 B | `68e54f8aea3cd9c818fc299c5be59ba5494cd74745b512cf1d6b10aa6922a9ae` |
| `models/recognizer_best.pt` | 37,451,102 B | `5e87d525f8f1a8229dfc41f7fdfd5fce0fd367cfe671e4ca0d390f524a9f5d01` |

## 3. `generate_submission.py` 的主要功能

1. 读取命令行参数中的检测器、识别器、图片目录和输出 JSON 路径。
2. 使用 Ultralytics `YOLO` 加载检测模型。
3. 从识别 checkpoint 读取 `model` state dict 和 `labels` 列表，构建无预训练权重的 `torchvision.models.efficientnet_b0`，并把最后的线性层改为标签数量。
4. 遍历输入目录的 PNG、JPEG 和 TIFF 图片。
5. 用检测器得到每个字符的 `xyxy` 边界框。
6. 将每个框按宽高的 10% 向外扩展，裁剪字符图片。
7. 将裁剪图统一缩放到 `224×224`，按 ImageNet 均值和标准差归一化，然后批量分类。
8. 对每个裁剪只取 logits 的 `argmax`，输出单个标签。
9. 把结果写成以图片文件名 stem 为键的 JSON：

```json
{
  "image_id": [
    {
      "bbox": [10, 20, 30, 40],
      "text": "马"
    }
  ]
}
```

`bbox` 格式是 `[x, y, width, height]`，均为整数。旧代码没有输出检测置信度、分类置信度、Top-K 候选或类别编号。

## 4. 运行流程

`run.sh` 是竞赛容器入口，流程为：

```text
/saisdata/50/eval/images
        ↓
YOLO 检测（/app/models/detector_best.pt）
        ↓
边界框扩展 10% 并裁剪
        ↓
EfficientNet-B0 分类（/app/models/recognizer_best.pt）
        ↓
/saisresult/prediction.json
        ↓
脚本内 JSON 结构校验
```

脚本默认推理参数与 `run.sh` 最终传参略有差异：Python 默认检测阈值为 `0.15`，`run.sh` 传入 `0.30`；两者的 IoU 都是 `0.60`，检测尺寸是 `1280`，裁剪 padding 是 `0.10`。

## 5. 检测模型

- 框架：Ultralytics YOLO。
- checkpoint 保存版本：Ultralytics `8.4.70`。
- 训练模型配置：`yolo11s.yaml`。
- 任务：单类目标检测。
- 类别数：1。
- 类别名：`character`。
- 训练图像尺寸：`1280`。
- checkpoint 中可见训练参数：80 epochs、batch 12。
- 代码输入：Pillow RGB 图片；Ultralytics 内部完成 letterbox、张量化和缩放。
- 原生模型输出：检测框坐标、检测置信度、类别编号等。
- 旧代码实际使用：只读取 `result.boxes.xyxy`，丢弃检测置信度和类别编号。

检测器负责定位“哪里有字符”，不负责判断字符是什么。

## 6. 识别模型

- 架构：EfficientNet-B0。
- 输入：RGB 裁剪图，强制缩放为 `224×224`。
- 张量：`float32`，形状 `[N, 3, 224, 224]`。
- 归一化：ImageNet mean `(0.485, 0.456, 0.406)`、std `(0.229, 0.224, 0.225)`。
- 分类头输入特征：1280。
- 分类头输出：4113 类，即 logits 形状 `[N, 4113]`。
- checkpoint `labels` 数量：4113，全部唯一。
- 标签构成：616 个 `ZHFD-...` 标识；3497 个单 Unicode 码位标签，包含常用字、繁简字、异体字、符号和扩展区字符。
- 旧代码输出：每个裁剪仅取 Top-1 标签字符串，没有 softmax 和置信度。

checkpoint 中保存的验证指标约为 Top-1 `0.4497`、Top-5 `0.6252`。这些是训练时验证集指标，不是每次预测的置信度，也不能证明模型对新来源图片具有同等准确率。

识别器负责判断“检测到的字符更像哪个训练类别”。它不能自行完成简繁统一、异体字归并、释读或来源检索。

## 7. 类别表、标签与字典检查

项目没有独立的字符类别表、CSV/JSON 标签文件、字典、简繁映射、异体字映射或 `class_id → normalized_char` 文件。

唯一可用的类别顺序位于 `recognizer_best.pt` 的 `labels` 字段中：列表下标就是模型的 `class_id`，对应值是原始标签字符串。这份嵌入式列表足以正确解释分类头的 4113 个输出位置，但存在两个限制：

1. `ZHFD-...` 只应原样显示为原始标签，除非以后获得权威映射。
2. 单字符标签可以作为 OCR 原始候选，但简体、繁体、异体字归并仍需要人工校订的查询数据库。

建议用脚本从 checkpoint 导入 `recognition_labels`，不要手工重排标签。对 `ZHFD-...` 的 `normalized_char` 保持为空。

## 8. 依赖项

旧代码直接依赖：

- Python（现有 `.pyc` 表明曾在 Python 3.10 运行，但源码不限定 3.10）
- PyTorch
- torchvision
- Ultralytics
- Pillow
- tqdm

旧项目没有 `requirements.txt` 或版本锁。检测 checkpoint 明确由 Ultralytics 8.4.70 保存，因此首次复现优先使用该版本。新的 Web MVP 还需要 FastAPI、Uvicorn 和 `python-multipart`。

`.pt` 是 pickle 体系的 checkpoint。只应加载可信来源的权重；识别 checkpoint 可优先使用 `torch.load(..., weights_only=True)`。检测 checkpoint 含完整 Ultralytics 模型对象，需要相应 Ultralytics 类定义。

## 9. Apple Silicon 与 `linux/amd64` 兼容性

本机检查结果为 `arm64`。当前项目目录没有 Dockerfile，只有为 Linux 竞赛目录布局编写的 `run.sh`。

模型数据本身没有绑定 `amd64` 指令，原则上能由 macOS arm64 版 PyTorch 加载。PyTorch 官方提供 `mps` 设备，Ultralytics 官方也支持用 `device="mps"` 在 Apple Silicon 上运行。参考：[PyTorch MPS 后端](https://docs.pytorch.org/docs/stable/notes/mps)、[Ultralytics Apple Silicon MPS](https://docs.ultralytics.com/modes/train/#apple-silicon-mps-training)。

但原代码不能直接运行，具体原因是：

- `torch.device('cuda')` 硬编码；Mac 没有 CUDA。
- `torch.autocast(device_type='cuda')` 硬编码。
- YOLO `device=0` 通常表示第 0 个 CUDA GPU，不是 MPS。
- `run.sh` 使用容器绝对路径。
- 默认分类 batch size 256 对统一内存的 Mac 可能过大。
- 原 `linux/amd64` 镜像在 Apple Silicon 上通常要经虚拟化/指令模拟，且容器内 CUDA 路径不能变成 Metal/MPS。

建议在 Mac 上使用原生 arm64 Python 3.11/3.12 虚拟环境，设备按 `mps → cuda → cpu` 自动选择；MPS 不可用或遇到不支持的算子时允许显式切换 CPU。不要为了 Mac 推理继续依赖原 amd64 容器。

本次在受控环境中的实际验证使用原生 arm64 Python 3.12、PyTorch 2.13.0、torchvision 0.28.0 和 Ultralytics 8.4.70：两个 checkpoint 均成功加载，4113 个标签成功导入，合成图片完成了检测器到 Top-5 分类器的端到端推理。该运行环境报告 `MPS built=True`、`MPS available=False`，所以实测走 CPU 回退并成功。这个结果证明模型可在 Apple Silicon 上原生 CPU 运行；MPS 路径已实现自动选择，但仍应在用户的普通终端环境再次确认，因为 MPS 可用性会受 PyTorch 构建、macOS 和进程运行环境影响。

## 10. 缺失文件

- 权威的 `ZHFD-... → 现代汉字/释读` 映射。
- 简体、繁体、异体字归一化数据及来源说明。
- 古文字字形图片库及其版权/出处信息。
- 字形的时代、来源、编号、释读和备注元数据。
- 训练数据类别目录或原始 label 文件。
- 依赖锁定文件和可复现 Dockerfile。
- 模型校准数据；当前 softmax 分数不能视为经过校准的真实概率。
- 示例输入、期望输出、单元测试和端到端测试。
- 模型适用范围说明、数据授权与许可说明。

## 11. 潜在问题

- **平台问题**：CUDA 和 Linux 路径硬编码。
- **置信度缺失**：旧输出只给 Top-1，无法表达不确定性。
- **标签语义不完整**：616 个 ZHFD 标识没有现代字映射。
- **Top-1 准确率有限**：checkpoint 记录的验证 Top-1 约 45%，不适合作为确定释读。
- **分数未校准**：softmax 值只能作为模型相对置信度显示，应明确“机器候选”。
- **检测排序**：旧代码没有按阅读顺序重排检测框。
- **图像形变**：裁剪图被直接拉伸为正方形，可能改变字形比例。
- **资源风险**：`Image.MAX_IMAGE_PIXELS = None` 关闭了 Pillow 的超大图保护。
- **内存风险**：默认 batch 256 在 Mac 上可能占用过多统一内存。
- **健壮性**：单张损坏图片会中断整个批处理。
- **安全性**：`weights_only=False` 会使用通用 pickle 反序列化；仅可加载可信 checkpoint。
- **许可风险**：检测 checkpoint 元数据标注 Ultralytics AGPL-3.0。若产品闭源或商用，需要进一步核实 Ultralytics 代码/模型及字形图片数据的许可。
- **数据版权/学术出处**：古文字字形图片、摹本和释读需要保留来源及授权信息。

## 12. 可复用部分

- 两个现有模型文件，可原样只读加载。
- YOLO 检测流程及 `imgsz/conf/iou` 基线参数。
- 检测框 10% padding 的裁剪逻辑。
- EfficientNet-B0 架构、224 输入和 ImageNet 归一化。
- checkpoint 内 4113 项类别顺序。
- 现有 `prediction.json` 结构可保留为批处理导出格式。
- `run.sh` 的输入检查与输出结构校验思路。

## 13. 建议的查询器架构

```text
浏览器（HTML/CSS/JS）
  ├── 现代汉字查询 ────────┐
  ├── 字条/字形展示         │
  ├── 本地数据录入          ├── FastAPI
  └── 古文字图片上传 ───────┤   ├── 查询服务
                            │   ├── 录入服务
                            │   └── OCR 适配器（延迟加载）
                            │          ├── YOLO 检测器
                            │          └── EfficientNet Top-5
                            └── SQLite + 本地 glyph/upload 目录
```

核心数据表：

- `characters`：规范字、简体、繁体、异体、解释。
- `glyphs`：时代、图片路径、来源、编号、释读、置信度、备注。
- `recognition_labels`：模型 `class_id`、规范字映射、原始 `label_name`、备注。
- `character_aliases`：额外的轻量索引表，用于简繁异体的精确统一检索。

查询时先做 Unicode NFKC 规范化，再在 `character_aliases` 查找。异体归并由录入数据决定，不引入无来源的自动猜测。

OCR 时返回每个检测框的检测置信度及前五个分类候选。候选包括 `class_id`、checkpoint 原始标签、softmax 分数和可选的 `normalized_char`。只有数据库中存在明确映射且对应字条存在时才返回跳转链接。界面始终标注“机器候选/未经校准”，不把最高分直接表述为确定答案。

## 14. MVP 实施边界

第一版只实现：

- 单字精确查询与简繁异体别名查询。
- 按时代分组展示本地字形图片和元数据。
- 本地开发环境下的字符/字形录入 API 与 CSV 导入。
- 单图上传、检测、Top-5 候选及置信度。
- checkpoint 标签安全导入。

第一版暂不实现：账号权限、多人审核、全文检索、云存储、复杂后台、模型再训练、置信度校准、自动爬取字形和未经人工核实的 ZHFD 释读。

## 15. 2026-07-14 实施结果

原文件和模型保持不变；新增实现位于 `macOS/`，与竞赛脚本和早期 FastAPI MVP 分开。当前原生 SwiftUI App 的部署目标是 `arm64-apple-macosx15.0`：macOS 26–27 使用 Liquid Glass API，macOS 15–25 使用系统材质降级样式。

离线查询库通过 Wikimedia Commons ACC 分类和文件页源代码生成。只有能明确释读为单个编码汉字且许可为 Public Domain/CC0 的来源才入库；最终提供 3,996 个有图源字符，按可靠简繁关系统一后为 3,954 个可搜索字条，并收录 6,404 个“汉字 × 时代”代表字形，覆盖甲骨文、金文、战国文字和小篆，其中 77 个为 Unicode 扩展区 B 及以后字符。14,059 条通过核验的完整来源和 566 条拒绝记录保存在 `macOS/Audit/`，没有把 ACC 编号猜成汉字。

字符关系采用 Unicode Unihan 17.0.0：`kSimplifiedVariant`、`kTraditionalVariant` 和 `kZVariant` 作为可查询别名；`kSemanticVariant` 与 `kSpecializedSemanticVariant` 只作为“相关字”展示，避免错误强制合并。3,996 个源字符中 1,268 个带直接异体关系、903 个带语义相关关系、3,626 个带 Unihan 英文后备简释。中文释义覆盖 3,486 字，其中 3,473 字原文来自教育部《重編國語辭典修訂本》开放数据，13 字由中文维基词典补充。字头右侧按实际收录时代显示字义、现代释读和具体来源/时代说明；没有可靠逐时代历史词义资料的条目不会虚构词义变化。完整生成方式和边界见 `macOS/CHARACTER_METADATA.md`。

OCR 已封装为 App 内独立 arm64 运行组件，自动按 `MPS → CPU` 选择设备，输出前五候选和未经校准的 softmax 分数。4,113 项分类顺序从 checkpoint 原样导出；616 个 `ZHFD-...` 标签保持未映射。构建阶段会同时校验字形许可、图片完整性、来源唯一性、类别顺序和不透明标签未映射约束。

SQLite 数据存放在 `~/Library/Application Support/AncientOCR/`。内置字形升级只替换带 `bundled_key` 的系统记录，用户自行录入的字符和图片不会被删除。发布前仍需注意：当前 App 使用本地临时签名，并非 Developer ID 签名或 Apple 公证版本。
