# 框架原生终端渲染探索

状态：已开始实施隔离 POC；生产后端未变。本文不代表已决定替换生产渲染器。

## 实施进度

首个实现位于 [`Experiments/NativeTerminalLab`](../../Experiments/NativeTerminalLab/README.md)，由 `mise run terminal-lab:generate` 显式加入工程，使用独立 `SanttyTerminalLab` scheme；普通生成不包含实验依赖。

- 已确认官方预编译 libghostty-vt 1.0.0 可用，固定下载地址与 SHA-256；保留生产 GhosttyKit，不编译 C core。
- 已确认现有 GhosttyKit 缺少独立 VT 导出。arm64 两个 archive 存在 859 个重合全局定义，因此先独立进程验证；主进程安全共存仍待解决。
- 已打通固定字节 fixture → Ghostty VT → 拥有数据的网格 → SwiftTerm 外部帧 → Core Graphics / Metal，不创建第二个模拟器。
- 已实现 NSScrollView 虚拟文档与有界 renderer，支持行内像素偏移、上下预取、跨行更新，以及新输出的底部跟随／历史阅读位置保留。
- 为 SwiftTerm 增加一处同步外部帧呈现补丁；纯行内移动不生成新网格帧。
- 已加入解析、适配、视口几何、AppKit 集成和两条绘制路径的像素回归测试；测试结果以实验 README 和实际 FlowDeck 输出为准。

这只是阶段 0 的隔离路径、阶段 1 的文字网格原型，以及阶段 3 的历史滚动基础设施。**不是阶段 2 的 Herdr Pane，也未完成阶段 1 的全部视觉／图片验证或阶段 3 的完整交互验收。**

接入真实会话前必须补齐：符号隔离、synchronized-output hold 与超时、完整状态映射、历史稳定锚点，以及输入／IME／鼠标／选择等交互。触控板实际体验、跨屏和睡眠唤醒、多 Pane 与能耗尚未实测。

## 目标与术语

让终端内容进入 Santty 可控制的呈现体系，而不只是嵌入一个独立绘制的 Ghostty surface，从而探索更自然的光标、滚动和布局过渡。

这里的“原生”指**宿主 UI 框架原生**，不是必须使用系统文本控件，也不排斥 Metal。关键是终端网格、光标、图片和动画的呈现状态由应用掌握。

优先验证：

1. 保留 Ghostty 的终端语义，复用 SwiftTerm 的独立渲染视图。
2. 优先使用 AppKit `NSScrollView` 驱动虚拟化历史视口，获得原生触控板、惯性、弹性、滚动条和分数像素滚动体验；同时验证可独立控制的光标呈现。
3. 与现有 AppKit 布局、裁剪、叠层、焦点和生命周期正确集成。
4. 在观感改善的同时，不显著牺牲输入延迟、文字质量、多 Pane 性能和能耗。

非目标：

- 第一阶段替换全部 Terminal Pane，或替换 Ghostty 的模拟器。
- 改动 herdr-core 协议、终端身份、工作区持久化格式。
- 第一阶段为任意 TUI 重绘自动生成内容动画。
- 用大量 SwiftUI `Text` 或每个 cell 一个视图搭建终端。
- 仅为面板移动、淡入淡出而更换 renderer；当前架构已支持这些操作。

## 调研结论与版本边界

### Herdr：职责划分的参考

调研快照：`herdrdev/herdr-app@a547b16ccb5e8811b2dd8b3b901d31df8f05e55a`。

Herdr 使用 libghostty-vt 维护终端状态、读取网格及编码输入，通过自己的 Frame / Cell 模型让 GPUI 绘制文字、背景、光标和图片。终端内容进入 GPUI 的布局、裁剪与呈现体系，而不是嵌入 Ghostty 自带 renderer。

它还自行合并输出刷新、缓存未变化的行，并避免未显示 Pane 的输出触发绘制。这证明了应用接管呈现和调度的可行性，但不能证明自绘天然更快或更美观。未找到作者专门解释最初技术选型的架构决策文档，不能把这些收益当成作者明确陈述的动机。

- [VT 到 Frame](https://github.com/herdrdev/herdr-app/blob/a547b16ccb5e8811b2dd8b3b901d31df8f05e55a/src/vt.rs)
- [GPUI 终端绘制与刷新调度](https://github.com/herdrdev/herdr-app/blob/a547b16ccb5e8811b2dd8b3b901d31df8f05e55a/src/terminal.rs)
- [平滑滚动 PR #450](https://github.com/herdrdev/herdr-app/pull/450)：调研时未合并，涉及分数像素历史滚动、旧行保留及应用区域位移识别，不能视为当前已发布能力。
- [可选 Ghostty renderer PR #714](https://github.com/herdrdev/herdr-app/pull/714)：调研时已关闭、未合并；说明复用 Ghostty VT 不等于获得 Ghostty 的字形呈现效果。

### SwiftTerm：可复用实现的参考

调研快照：`migueldeicaza/SwiftTerm@28c6d1d95de156a36a2eaa278177ee7f8a15d322`。

当前主分支提供独立的 `TerminalRenderView`：只绘制外部状态，不运行终端模拟器，不负责输入、选择交互或滚动。它通过 `TerminalRowStore`、`TerminalExternalFrame` 和 `TerminalExternalFrameSource` 接收网格，复用完整 TerminalView 的 Core Graphics / Metal 绘制代码。

这使“Ghostty VT + SwiftTerm renderer”成为优先于从零编写 renderer 的验证路线。

版本与能力限制：

- 调研时最新 release 为 `v1.99.3`；核对该 tag 后，上述独立渲染接口文件尚不存在。POC 必须固定包含接口的 revision，不能直接假定 release 可用。
- 外部帧路径在主线程准备并绘制；不能套用完整 TerminalView 的后台 render-loop 性能结论。
- Core Graphics 路径有独立 CaretView，使用 Core Animation 闪烁；Metal 路径由 renderer 绘制光标，两者需要分别评估。
- 当前外部帧 `topLine` 是整数行，没有现成的分数像素滚动接口。完整 TerminalView 对触控板小位移的累积最终仍转为整数行，不等于已经支持像素级文字滚动。
- 行、样式和 grapheme 使用 SwiftTerm 自己的数据结构，需要适配，不能假定与 Ghostty 零拷贝兼容。
- TerminalRowStore 不是线程安全的，样式与 grapheme 表只增长；接近容量时需要换 store 并重建保留行。
- SwiftTerm 为 MIT 许可；引入或修改代码需保留相关版权和许可声明。

参考：

- [External Rendering 文档](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/Documentation.docc/ExternalRendering.md)
- [macOS TerminalRenderView](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/Mac/MacTerminalRenderView.swift)
- [外部帧模型](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/Apple/TerminalExternalFrame.swift)
- [脏行与快照管理](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/Apple/ExternalRenderOwner.swift)
- [光标视图](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/Mac/MacCaretView.swift)
- [渲染回归测试](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Tests/SwiftTermTests/TerminalRenderViewTests.swift)

这些结论来自源码与讨论检查，尚未做 Santty 集成、运行验证或性能实测。

## Santty 现状

当前路径：

```text
本地 exec / Herdr 字节流
        ↓
GhosttyTerminal.TerminalView + Ghostty surface
        ↓
Ghostty 自己绘制终端内容
        ↓
AppKit / Core Animation 合成 Pane
```

主要连接点：

- `Santty/Sources/Workspace/Panes/TerminalPaneController.swift`：创建 TerminalView，选择 exec 或 in-memory 后端，承载 CLI 输入和读取等功能。
- `Santty/Sources/Herdr/HerdrTerminalSession.swift`：Herdr 生命周期、字节流、输入、resize、display facts 和解析后 credit。
- `Santty/Sources/Workspace/Views/TerminalPaneHostView.swift`：Pane 包装、可见性、状态与叠层。
- `Santty/Sources/Workspace/Views/WorkspaceTilingView.swift`：已有面板整体 FLIP 动画，不能据此控制终端内部元素。
- `Santty/Sources/Workspace/Views/TerminalScrollModeView.swift`：透明输入和光标层，文字及选择仍由 Ghostty 绘制。

## 候选架构

以下名称表示职责边界，不是已确定的新类型或目录。

```text
现有 Herdr transport
        ↓
Ghostty VT driver（唯一终端状态与协议应答来源）
        ↓
TerminalFrame（应用持有的稳定帧、行标识和损伤信息）
        ↓
SwiftTerm adapter（增量映射为 RowStore / ExternalFrame）
        ↓
TerminalRenderView（Core Graphics / Metal）
        +
PresentationController（滚动偏移、光标和动画生命周期）
```

原则：

- 终端真实状态与动画状态分离。动画可以保留上一帧，但不得阻塞解析、伪造终端状态或延后流控确认。
- 完整保留 cell 文本、宽字符尾格、样式、软换行、调色板、光标、选择和图片信息；不能从纯文本快照重建画面。
- 未变化的行应复用；避免每帧遍历和重建全部 cell，也不复制全部 scrollback。
- 适配层必须明确坐标、颜色、选择区端点和 bidi 约定，不能让 renderer 意外再次重排已经确定顺序的网格。
- SwiftTerm 只负责呈现，不再喂同一串 ANSI 给第二个模拟器；输入编码和协议应答保持单一所有者。
- 对比路径按实验 Pane 创建时选择。第一阶段不做活动会话的无缝热切换，不用双解析器、双输入或双协议应答实现对比。

### AppKit 原生滚动视口目标

优先验证由 `NSScrollView` 提供历史记录的滚动基础设施，而不是自行实现惯性和弹性。此项是 POC 的明确目标，不代表当前 SwiftTerm 接入后即可自动支持。

```text
NSScrollView / NSClipView（连续滚动位置、惯性、弹性、滚动条）
        ↓
虚拟文档／视口适配层（历史行 + 行内像素偏移）
        ↓
TerminalRenderView（仅绘制可见行及少量上下预取行）
```

- 历史仍由 Ghostty 管理；虚拟文档表达可滚动范围，不为每行建立视图、不复制全部历史，也不创建与完整文档等高的 Metal surface 或纹理。实际绘制资源应保持在视口尺度。
- 将连续滚动位置拆为整数历史行与分数像素偏移。例如行高 20 pt、位置 105 pt 时，从索引 5 的行取数据，并向上偏移 5 pt；边界由额外预取行填充。
- 为 SwiftTerm 整数 `topLine` 增加外围呈现偏移或必要的接口扩展，明确文档、视口、cell 和设备像素之间的坐标转换。
- 跟随输出仅在原本位于底部时保持；阅读历史时，新输出不应拉回底部。历史淘汰、resize reflow 和字体变化时，尽可能保持稳定的阅读锚点，锚点失效时按明确规则限制到有效范围。
- 滚轮事件只能有一个接收路径：程序请求鼠标报告时编码并发送给程序，不同时滚动本地历史；显式本地滚动修饰键及 alternate-scroll 行为遵循终端模式与现有交互约定。
- 本地历史滚动与 TUI 内容滚动分开处理。程序收到滚轮后自行重画屏幕，不会自动成为 NSScrollView 的内容动画，不在本目标内承诺平滑化。
- 优先保留 AppKit 的手势与动量行为，避免叠加第二套 easing 导致延迟或双重惯性；弹性区域不改变终端真实视口、输入坐标或 PTY 尺寸。

## 分阶段实施

### 阶段 0：依赖与 API 可行性门槛

1. 确认可用的预编译 libghostty-vt、头文件、Swift 导入方式、支持平台和许可证。
2. 核对现有 GhosttyKit 是否提供所需 VT API；不能假定 surface API 等同于独立 VT API。
3. 检查独立 VT 库与现有 GhosttyKit 的符号、ABI 和链接冲突。必要时先用不链接现有 C core 的独立实验 target 验证，不能通过混用不兼容头文件绕过。
4. 固定 SwiftTerm revision，检查 Swift 6.2 工具链、严格并发、构建配置及 Tuist 集成。
5. 列出 Ghostty 可导出状态与 SwiftTerm 外部帧的映射表，包括图片和选择能力的缺口。

保持现有预编译 GhosttyKit.xcframework；不为此实验从源码重编或替换生产 C core。若独立 VT 的二进制供应或接口不满足要求，先记录阻塞并讨论方案，不静默改变项目依赖约束。

产物：依赖可行性记录、映射表及继续／停止决定。

### 阶段 1：固定网格渲染原型

- 在隔离实验视图中实现外部 FrameSource 与增量 RowStore 适配。
- 使用确定性字节 fixture，经 Ghostty VT 生成网格；先不接真实 shell。
- 分别验证 Core Graphics 和 Metal。区分帧准备、绘制、GPU 提交和实际呈现，不能只比较刷新请求次数。
- 覆盖中文、emoji、组合字符、宽字符、样式、块字符、字体回退、软换行、调色板变化及 resize。
- 检查同源 fixture 下 adapter 是否丢失状态；必要时保存网格与截图定位差异。

产物：可复现的网格测试和两种绘制路径的基线，不新增正式设置项。

### 阶段 2：单个 Herdr Pane 集成

- 通过默认关闭的开发入口选择实验 renderer；生产默认保持当前 Ghostty surface。
- 先支持一个隔离 Herdr 实验 Pane，不扩展到本地 exec。
- 保留原有 terminal binding、remote core identity、viewer-only 语义、重连和关闭流程。
- 接入输入、IME、鼠标、选择复制、焦点、尺寸与 display facts。
- VT 解析完成后再返还 stream credit，而不是收到或排入输出队列即返还。
- 后台 Pane 继续解析必要输出，但停止不必要绘制；显示恢复时更新到最新状态，不抢焦点。
- 重连重置画面、Scroll Mode 和动画；输入不缓存重放。

原型未完成的 CLI、Scroll Mode、辅助功能或图片功能必须明确标为未支持，不能悄悄改变其现有语义。不得绕过 CLICommandRouter 的授权与重试机制。

### 阶段 3：验证动画收益

优先实现：

1. **NSScrollView 驱动的历史记录平滑滚动**：以 AppKit 原生滚动视图和虚拟化文档为首选原型；逻辑视口保持整数行，呈现层响应连续滚动位置，保留分数像素偏移、必要的上下预取行和旧行。验证触控板、动量、弹性、滚动条拖动，以及新输出和历史淘汰时的阅读位置。
2. **独立光标呈现**：先验证闪烁和移动过渡，再决定两种 renderer 是否采用相同实现。
3. **布局过渡**：比较现有整体 FLIP 与保留内容、裁剪／平移方案；避免只把文字整体缩放后称为改善。

必须同时处理：

- 点击、选择、链接、鼠标报告及 IME 候选框对应动画中实际显示的位置。
- 连续滚动时从当前呈现位置接续，不回到旧起点。
- resize、切换 alternate screen、搜索跳转、Scroll Mode、重连和销毁时明确取消或重定位动画。
- 系统 Reduce Motion；隐藏 Pane 时停止动画调度，静止状态不为动画持续重绘。
- 同步输出的一致呈现及有界超时恢复，不因补间显示半帧。

第一阶段不实现对任意 TUI 重绘的行位移推断。应用自行重画屏幕不一定意味着滚动；未来研究也必须能对模糊场景立即退回无动画呈现。

当前 SwiftTerm 公开接口不足以表达全部动画状态，可能需要上游扩展或小范围 fork。先列出必要改动，再决定维护方式，不提前承诺无 fork 集成。

### 阶段 4：评测与采纳决定

在同一机器、窗口尺寸、字体、缩放、刷新率和可见性下，对比：

- 当前 Ghostty surface。
- Ghostty VT + SwiftTerm Core Graphics。
- Ghostty VT + SwiftTerm Metal。

至少覆盖空闲、多 Pane、持续大输出、TUI 高频刷新、中文输入、图片、滚动和 resize。记录：

- 输入到字形呈现延迟与尾延迟。
- 主线程停顿、帧间隔、动画中断与恢复。
- CPU、GPU、内存、空闲唤醒及长时间输出后的资源增长。
- 字体观感、选择复制、图片位置和可访问性。
- 窗口跨不同 scale 显示器、隐藏恢复、睡眠唤醒及关闭。

性能阈值在基线测量后、优化前确定；不能用不同负载或只测帧构建耗时宣称性能提升。

根据证据选择：停止实验、只借鉴局部实现、保留可选 renderer，或另立生产迁移计划。验证本地 exec、全面功能对等和长期 fork 成本之前，不替换默认后端。

## 验收与回退

POC 成功需要同时证明：

- Ghostty 仍是唯一终端状态来源，关键语义经过适配后不丢失。
- 验证 NSScrollView 驱动的虚拟化历史视口：连续像素滚动、惯性、弹性和滚动条协调工作，绘制资源不随全部历史高度增长；若方案不可行，记录具体阻塞和替代方案，不静默移除此目标。
- 滚动中选择、链接和 IME 坐标正确；新输出不打断历史阅读；程序鼠标报告与本地滚动不重复消费同一事件。
- 至少一个终端内部动画带来可观察的改善，而非仅动画面板外壳。
- 两种绘制路径的主线程成本和多 Pane 成本有可复现测量。
- 原有 Herdr identity、credit、关闭和不重放输入的约束保持不变。
- 关闭实验入口即可继续创建原有 Ghostty surface Pane；现有生产依赖与持久化格式不受影响。

回退不得通过创建一个新远程 terminal 替代旧 binding，也不得重放用户输入。失败时保留会话身份与错误状态，显式重新附着或重建 viewer；第一阶段不承诺运行中无缝切换 renderer。

后续实现与验证使用 FlowDeck 的已保存 Mac target：

```sh
flowdeck config get --json
flowdeck build
flowdeck test
```

真实会话与 UI 冒烟测试使用隔离工作区／测试 terminal；不向用户已有终端注入测试输入，不停止或重启共享 core。
