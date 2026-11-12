# 框架原生终端渲染探索

状态：首轮渲染／滚动 POC 已获人工确认；阶段 2 本地私有 Herdr 和双私有 core 的 native 远端代理回归已通过，阶段 3 已接鼠标／滚轮／选择复制及稳定历史内容锚点。真实网络／设备验收与完整交互仍待完成。主应用仍使用旧渲染后端，整体迁移与发布仍以功能和性能验收为门槛。

## 实施进度

首个实现位于 [`Experiments/NativeTerminalLab`](../../Experiments/NativeTerminalLab/README.md)，由 `mise run terminal-lab:generate` 显式加入工程，使用独立 `SanttyTerminalLab` scheme；普通生成不包含实验依赖。

- 已确认官方预编译 libghostty-vt 1.0.0 可用，固定下载地址与 SHA-256；保留生产 GhosttyKit，不编译 C core。
- 已确认现有 GhosttyKit 缺少独立 VT 导出。arm64 两个 archive 存在 859 个重合全局定义，因此当前独立进程验证；最终通过移除旧 C core 避免双库共存，不再把符号隔离作为迁移前置任务。
- 已打通固定字节 fixture → Ghostty VT → 拥有数据的网格 → SwiftTerm 外部帧 → Core Graphics / Metal，不创建第二个模拟器。
- 已实现 NSScrollView 虚拟文档与有界 renderer，支持行内像素偏移、上下预取、跨行更新，以及新输出的底部跟随／历史阅读位置保留。
- 为 SwiftTerm 增加同步外部帧呈现和 AppKit 光标绘制入口补丁；纯行内移动不生成新网格帧。用户后续报告的 private shell 光标不可见已由像素回归复现并修复；同时修复 native 分数行视口中的 overscan 光标定位，GUI 修复效果待用户复验。
- 已加入解析、适配、视口几何、AppKit 集成和两条绘制路径的像素回归测试；测试结果以实验 README 和实际 FlowDeck 输出为准。
- 用户已启动实验 app，并对滚动、输出跟随、renderer 切换、resize、文字与重置测试清单反馈“一切正常，符合预期”。记录为当前环境的人工体验验收，不替代性能测量或完整交互验收。

已完成阶段 0 的隔离路径、阶段 1 的基础体验，以及阶段 2 的本地私有 Herdr 实时链路。新增共用 `TerminalStreamEndpoint` / `TerminalStreamViewport`；原有 Herdr 状态机保留，旧 InMemory 适配移至独立文件，native lab 复用同一套 transport／身份／重连逻辑，不链接旧 C core。

- VT C 调用已串行化，后台解析与绘制分离，credit 仍跟随解析；已接自动协议应答、1 s 同步输出 hold／超时、尺寸查询与最小键盘／IME／粘贴／焦点链路。真实 shell 的 Ctrl+C 二次编码问题已复现并修复；补齐 legacy 控制别名，Kitty／modifyOtherKeys 仍以 VT 状态和编码器为准，新增实际 SIGINT 与后续输入回归。
- 实验入口显式创建私有 socket／session／HOME／XDG 环境；自动验证包含大输出、绑定重连、viewer-only detach、身份拒绝、元数据更新不触发焦点恢复，以及启动／退出竞争时的清理。
- nvim 冒号输入已由 Shift 消费标记回归复现并修复；覆盖可打印文本、Option、Kitty press／release，以及不应被消费的 Shift+Tab／方向键，并用私有 clean nvim 验证进入命令行和执行命令。输入专项随后加入独立的普通／插入／命令模式真实括号粘贴回归，目前均通过；旧观察不武断归因于单一生产根因。
- 当前实验测试与主应用回归结果、一次未稳定复现的旧远程元数据超时记录见实验 README。本轮 nvim 0.12.5 的 paste+CR burst 已由正确 wire 与独立私有 PTY 复现为消费者调度竞争；端到端等待实际 CmdlineChanged 后继续、单项连续 10 次通过，不改变生产输入节奏。保留诊断脚本和限制，不将它宣称为终端快速 burst 的已修复能力。

- 鼠标／滚轮已有单一路由、分数余量和动量归属；选择／复制接 Ghostty tracked gesture／formatter，不引入另一套 buffer。CG／Metal 的选择像素、私有 nvim 点击／滚轮、私有 tmux pane／copy mode，以及双私有 core 的 native 远端鼠标字节、身份／PID 重连与 viewer-only detach 回归已通过。

- 用户已自行验证鼠标／选择与稳定历史锚点两轮，并反馈正常，记录为当前环境人工验收。之后补入保守 OSC 8 URL 打开及手动审阅 clipboard offer：复用 Santty parser、参考 Herdr／SwiftTerm 策略，不扩大程序剪贴板权限。本轮按用户 Cmd URL 故障补入普通 scheme URL、真实 hover 下划线、原地修饰键刷新及微小跨格点击修正；四项先失败后通过，仍待 GUI 复验。

- 阶段 3 新增 overline 与 focused hollow cursor：复用 SwiftTerm 属性表、CG／Metal 装饰线和原有 outline 几何；保持 packed cell 8 bytes／legacy style 8 bits，不伪造焦点、不改解析器／编码器／shader。12 项专项及全量 165 项实验测试通过；主应用 362 通过、1 项系统能力跳过。宿主默认形状／blink 仍经 VT options，程序 DECSCUSR 保持优先。像素前提中的 calibrated RGB 与空白 selectAll 差异已单独记录，未宣称跨后端精确校色或 GUI 验收。

- 图片已补 VT 1.0 运行时 ABI 审核和拥有数据的快照：读取 C 已解析的像素、crop、目标尺寸、图层与 virtual／relative placement；15 项专项覆盖 generation、限额、历史／screen／hold 与外部传输拒绝。独立 C 客户端复现首个放大 1×1 虚拟切片的零尺寸 source crop，保留为限制，不新增解析器或重编 core。详见 [图片差异表](../../Experiments/NativeTerminalLab/IMAGE-COMPATIBILITY.md)。后续已向 CG／Metal 提交受支持的原始图片，新增 19 项实际像素／cache／viewport 回归，修复 source crop 插值串色并在 hold 重连前清旧图；图片补丁保留 legacy sizing 默认值并同步两份 Metal shader；本轮全量实验 199 通过／0 跳过，主应用 362 通过／1 项系统能力跳过。随后接入 startup-only ImageIO／vImage 静态 `f=100` PNG，11 项解码边界用例、两条 CG／Metal PNG 像素用例和私有 Herdr 流验证；全量实验 213 通过／0 跳过。修复 ImageIO 容错状态误判与 driver 首次默认像素 metrics，独立 C 对照记录同 ID 非原子替换；不改变协议字节、核心或等待时长。**动画／APNG仍未支持，零 crop、GUI／跨设备／完整协议门槛未关闭。**

**真实 SSH／跨机器网络、本地 PTY、完整交互、图片映射及主应用迁移尚未完成；新链接／clipboard offer GUI 和更广泛输入法／设备验收仍待完成。**

下面的输入兼容专项已建立参考差异表、独立事件归一化与固定字节矩阵；继续按差异清单收敛，而不是依赖用户逐个发现基础按键问题。继续真实网络／设备验收、完整呈现、辅助功能与平台输入缺口；再完成本地 PTY，最后整体切换主应用。当前环境的滚动体验已获用户人工确认；跨输入设备／显示配置、跨屏和睡眠唤醒、多 Pane 与能耗仍待验证。

## 目标与术语

让终端内容进入 Santty 可控制的呈现体系，而不只是嵌入一个独立绘制的 Ghostty surface，从而探索更自然的光标、滚动和布局过渡。

这里的“原生”指**宿主 UI 框架原生**，不是必须使用系统文本控件，也不排斥 Metal。关键是终端网格、光标、图片和动画的呈现状态由应用掌握。

优先验证：

1. 保留 Ghostty 作为唯一终端模拟核心，复用 SwiftTerm 的独立渲染视图、可独立使用的 PTY runner，以及适合提取的 AppKit 交互代码。
2. 优先使用 AppKit `NSScrollView` 驱动虚拟化历史视口，获得原生触控板、惯性、弹性、滚动条和分数像素滚动体验；同时验证可独立控制的光标呈现。
3. 与现有 AppKit 布局、裁剪、叠层、焦点和生命周期正确集成。
4. 在观感改善的同时，不显著牺牲输入延迟、文字质量、多 Pane 性能和能耗。

非目标：

- 第一阶段立即替换全部 Terminal Pane，或改用 SwiftTerm 的模拟器。
- 长期维护双模拟器、同进程新旧后端共存，或先为此构建符号隔离层。
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

上述调研结论来自固定 revision 的源码与讨论。当前已完成隔离原型的构建、测试和人工体验验证，但尚无主应用集成或生产性能对比结论。

## 迁移策略：分阶段开发，整体替换

本分支的目标改为整体迁移到 **Ghostty VT + SwiftTerm 呈现与可复用平台组件 + Santty 会话层**，不长期保留新旧终端后端。

- 实现阶段继续用独立实验 target 验证，主应用暂时保留旧实现；这不是要求两套 C 库在同一进程中共存。
- 最终主应用只链接预编译 libghostty-vt，不再链接旧 Ghostty surface C core；因此双库符号隔离不再是实施前置任务。
- 不先做动态 framework 封装、内部符号隐藏或运行时后端回退开关。若以后重新提出混合后端需求，另行决策。
- 可以分阶段编写与测试模块，但主应用切换时一次覆盖所有终端入口，不能把尚未具备的本地／远程能力静默降级。
- 回退依靠 Git 分支／提交或旧版本，不依赖同进程同时装载两套模拟器。旧版可作为独立性能与行为基线。

## SwiftTerm 能力复用矩阵

“补齐能力”不等于全部重写。优先复用公开独立组件，其次提取平台层与参考算法；凡依赖 SwiftTerm.Terminal／buffer／terminalLock 的代码，不能直接带入第二套终端状态。

| 能力 | 复用对象 | 实施方式与边界 |
| --- | --- | --- |
| 网格呈现 | TerminalRenderView、外部帧、RowStore | 已复用；继续增量适配 Ghostty 网格，保留行复用和有界资源。 |
| 本地 PTY／进程 | LocalProcess、LocalProcessDelegate | 优先直接复用独立 runner，输出接 Ghostty driver；适配退出、队列、前台进程及 TTY 语义。 |
| 本地完整终端视图 | LocalProcessTerminalView | 不直接使用：它继承带 SwiftTerm 模拟器的 TerminalView；只参考如何连接进程。 |
| 键盘 | TerminalKeyboardRouter、TerminalKeyboardHost | 先验证能否干净适配平台事件。Ghostty 模式是权威，最终编码单一所有；不能混用两套 kitty flags 位布局或重复发送 Router bytes 与 Ghostty 编码结果。 |
| IME | MacTerminalView 的 NSTextInputClient 实现 | 提取／参考 marked text、提交、取消、焦点和候选框处理；坐标接入我们的动画／滚动视口，不复制完整 TerminalView。 |
| 选择与复制 | SelectionService、视图拖动／自动滚动代码 | 参考范围、词／行和自动滚动算法；该服务直接依赖 SwiftTerm.Terminal 及其锁，选择来源与真实状态改由 Ghostty／Santty 提供。 |
| 鼠标／滚轮 | MacTerminalView 平台事件处理 | 参考手势、修饰键和报告路由，协议由 Ghostty 编码；滚动事件只能送程序或滚本地历史，不能双重消费。 |
| 图片 | 外部帧 images／Kitty snapshot、renderer | 复用绘制，单独适配 Ghostty 图片数据和 placement；检查坐标、缓存及生命周期。 |
| 辅助功能 | AppKit AX、SwiftTerm 可用实现与测试 | MacAccessibilityService 在当前 revision 只是占位，不能作为现成功能；需要实现并验收。 |
| Herdr、CLI、安全与工作区 | Santty 现有模块 | 继续复用，SwiftTerm 不替代 transport、credit、身份、授权、持久化或共享布局语义。 |

如果 Router 无法与 Ghostty 编码边界干净拆分，就参考其 AppKit 处理代码，而不是为了复用强接另一套协议状态。最终所有输入路径必须具有可测试的模式来源和唯一发送点，粘贴／编辑命令等非单键路径也不例外。

参考同一固定 revision 的源文件：

- [LocalProcess](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/LocalProcess.swift)
- [MacKeyboardRouter](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/Mac/MacKeyboardRouter.swift)
- [MacTerminalView：输入、IME 与鼠标](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/Mac/MacTerminalView.swift)
- [SelectionService](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/SelectionService.swift)
- [MacAccessibilityService](https://github.com/migueldeicaza/SwiftTerm/blob/28c6d1d95de156a36a2eaa278177ee7f8a15d322/Sources/SwiftTerm/Mac/MacAccessibilityService.swift)

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

## 目标架构

以下名称表示职责边界，不是已确定的新类型或目录。

```text
现有 Herdr transport / SwiftTerm.LocalProcess
        ↓
共用字节 I/O 与会话边界
        ↓
Ghostty VT driver（唯一终端状态、协议模式与应答来源）
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
- SwiftTerm 提供呈现和独立可复用的平台组件，不再喂同一串 ANSI 给第二个模拟器；输入编码和协议应答保持单一所有者。
- 新旧版本对比使用独立构建／进程，主应用最终只保留新后端。不做活动会话的后端热切换，不用双解析器、双输入或双协议应答实现对比。

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

### 阶段 0：依赖与 API 可行性（隔离原型已完成）

- 已确认官方预编译 libghostty-vt 1.0.0 可用，固定下载地址、头文件与 SHA-256，不编译 C core。
- 已固定 SwiftTerm revision，验证工具链、严格并发和 Tuist / FlowDeck 实验构建。
- 已识别旧 GhosttyKit 与新 VT archive 的符号重合，当前通过独立实验 app 避免混链。**不再安排双库动态封装、符号隐藏或运行时共存作为下一阶段的前置任务。**
- 继续维护状态映射清单，逐项标记完整支持、未支持及所需上游扩展，不能因 renderer 支持某功能就假定适配完成。

旧主应用在整体切换前保持原有预编译 GhosttyKit，不重编或修改其 C core；新路径只使用预编译 VT。若二进制供应或接口不满足要求，记录阻塞并讨论，不静默改为源码构建。

### 阶段 1：固定网格与原生滚动原型（基础体验已通过）

- 已打通固定字节 fixture → Ghostty VT → SwiftTerm Core Graphics / Metal，并实现 NSScrollView 虚拟历史视口。
- 保留现有 Unicode、宽字符、grapheme、颜色、样式、软换行、行复用、overscan 和 resize 回归测试。
- 用户已对滚动、输出跟随、renderer 切换、resize、文字及重置反馈符合预期；这是当前环境的人工体验验收。
- 稳定内容锚点及鼠标／选择在后续阶段 3 已补基础实现与回归；图片、完整视觉对等、完整交互与性能测量仍待补齐。

产物：可重复构建的实验 app、fixture 和自动化测试；不将实验视图标记为正式终端。

### 阶段 2：真实 Herdr 会话与共用 I/O 边界（本地与私有远端代理已验证）

先在不链接旧 GhosttyKit 的实验 target 中接入一个隔离测试 terminal，不在主应用中引入混合新旧 Pane。优先复用 Santty 现有 Herdr 会话与 transport，提取其中与旧 `InMemoryTerminalSession` 耦合的字节接口，而不是复制一套连接／重连状态机。

当前实现：`TerminalStreamEndpoint.swift`、`NativeTerminalOutput.swift`、`NativeHerdrLab.swift` 与 `NativeTerminalInputView.swift`；生产旧适配为 `HerdrTerminalSession+Ghostty.swift`。本地私有 core 与两个私有 core 经 machine via 代理的 native endpoint 自动化集成已通过；后者覆盖真实远端 PTY 鼠标字节、身份／PID 重连、离线丢弃和 viewer-only detach，不再以旧后端的远程测试代替 native 覆盖。真实 SSH／网络故障和 GUI 输入验收仍待完成。

KeyboardRouter 的部分 legacy 路径直接输出按当时模式编码的 bytes，本阶段选择参考其 AppKit／NSTextInputClient 分层，不强接第二套编码器。同步输出 hold 暂时固定已发布视口，超时 1 s，解析／应答／credit 不等待解除；完整交互体验后续继续验证。

顺序：

1. 定义共用终端 I/O 边界：输出解析完成、用户输入、自动协议应答、resize、焦点／display facts、断开与结束；明确执行队列和生命周期。
2. 为 VT driver 增加串行解析、跨批次 synchronized-output hold、解除／超时、协议应答和有界输出调度。credit 在解析完成后返还，不等待绘制，也不在 enqueue 时提前返还。
3. 接入现有 Herdr transport，并在真实字节流上验证尺寸、主题／cell facts、标题和退出。首个连接只处理明确指定的隔离测试 terminal，不操作用户已有会话。
4. 接入最小键盘与 IME 提交链路，使测试会话能实际交互。按复用矩阵适配 KeyboardRouter 或参考其平台层，模式和最终编码由 VT driver 统一决定。
5. 验证断线、重连、终端已结束、身份变更和 viewer-only 行为；之后再覆盖远程测试会话。

必须保留：

- permanent core ID、terminal binding、pending run、标签 reconcile 与 viewer-only 约束。不能因挂接失败创建另一个 terminal 替代已有身份。
- 每条现有连接的多路复用及 credit 语义；不为每个 Pane 私自增加独立连接。
- 后台会话继续解析必要输出，但不持续绘制、不抢 responder。
- 重连清理旧画面、Scroll Mode、marked text 和动画；输入不排队重放。
- viewer close 只 detach；显式 terminal close 完成后才能删除 binding；窗口关闭不杀远程程序。
- agent 元数据与工作区／共享布局同步仍走现有通道，不从屏幕推断状态，不改变原有权限、身份或布局规则。

自动验证使用伪 transport／确定性事件重放；真实冒烟只连接隔离会话。阶段验收是可输入、可持续输出、可重连且 credit 正确，不要求此时主应用已经切换。

### 阶段 3：完整 AppKit 交互与呈现

#### 输入兼容专项（基础收敛与矩阵已落地，完整兼容门槛未关闭）

连续出现 Ctrl 和 Shift 标点问题，说明“最小可输入”不能当成输入兼容完成。测试总数只证明已覆盖案例，不能替代系统审计或完整键盘兼容性验收。用户人工体验用于发现观感、设备和输入法差异，不承担枚举基础按键／协议组合的责任。

当前实现与差异清单见 [INPUT-COMPATIBILITY.md](../../Experiments/NativeTerminalLab/INPUT-COMPATIBILITY.md)。已拆出 NativeAppKitKeySnapshot、NativeKeyNormalizer、NativeKeySequence 与输入意图，保留唯一发送点；移植 26×3 独立向量并覆盖全部 Kitty flags 的生命周期。本轮 Cmd URL 专项后共 153 项实验测试通过、无跳过，普通主应用 361 项通过、2 项环境跳过（旧 Metal 图形显示条件、私有圆角 getter）；仍须按清单验证完整平台行为，未进入主应用后端切换。

1. **先建立参考行为清单，再改适配层。** 固定 Herdr 调研 revision，对照 `src/terminal.rs` 的 `key_bytes`、`control_alias_bytes`、`map_key` 和 `keys_send_what_ghostty_sends` 等测试，以及 `src/vt.rs` 的 `encode_key`。这些位置已经覆盖 C0 文本过滤、consumed modifiers、legacy 别名和多种协议下的 Shift 标点／Option 文本，不能只在用户报告后逐项摘取。AppKit 事件分发、IME、菜单、重复与释放另对照固定 SwiftTerm revision 的 `MacKeyboardRouter.swift`、`MacTerminalView.swift` 和对应测试；Herdr 的 GPUI 平台层不能直接当作 NSEvent 适配。
2. **收敛到可测试的语义事件边界。** 从 NSView 拆出按键归一化，明确 physical／logical key、提交文本、未修饰码点、原始／已消费修饰符、composition 与 press／repeat／release。按键、IME 提交、粘贴和编辑动作分别定义责任及唯一发送点。Ghostty 继续拥有终端模式与最终协议编码，不直接启用 SwiftTerm 的另一套编码器；通用策略优先提取复用，不另造完整终端状态机。
3. **移植行为矩阵，不照搬不同版本的 ABI 或字节。** 覆盖可打印 ASCII／Unicode、Ctrl 及传统别名、Shift 标点、Option 作为文本／Meta、功能键与 keypad、菜单归属；组合 legacy／应用方向键／应用 keypad、modifyOtherKeys、Kitty flags 及模式 push／pop，再覆盖重复、修饰键先释放、失焦、重连和 IME 组合／取消／提交。预期值注明参考版本、模式和平台差异。分别断言 NSEvent → 语义字段、语义字段 → 固定字节；不能只调用被测编码路径生成 expected。移植代码与测试前核对许可证并保留来源。
4. **增加真实消费者验收门槛。** 用私有 shell 验证控制字节与进程行为，用私有 clean nvim 验证普通／插入／命令模式、标点、快捷键、粘贴及协议切换。已知命令行括号粘贴问题纳入本专项，不通过改变测试路径将其算作已修复。所有输入只进入隔离测试终端，不改变用户输入源设置，不向已有会话注入内容，不停止共享 core。

完成参考差异表、可追溯的测试矩阵并修复已知输入缺口之前，不以新增动画、PTY 或主应用整体迁移代替输入层收敛；任何未覆盖行为必须明确列为缺口，而不是由测试总数推断兼容。

其余交互以 SwiftTerm 的平台代码和回归测试为首选参考，但不引入其 Terminal 模拟器。

- **键盘／IME**：覆盖 Option、快捷键、重复与 release、Kitty keyboard、应用方向键、组合／取消／提交、粘贴和焦点切换。候选框跟随实际呈现位置，metadata 更新不抢 first responder；模式切换时不得发出双份输入。
- **鼠标与滚轮**：已接程序鼠标报告、Shift 本地覆盖、1007 alternate-scroll 和互斥 NSScrollView 路由；回归覆盖动量期间模式改变、resize 取消、无 phase 精细设备、分数／Retina 和同步输出期间 release。实体设备体验与其他协议组合继续验收。
- **选择与复制**：已复用 Ghostty tracked gesture／formatter 管理范围、词／行、Unicode／软换行文本，SwiftTerm 只绘制选择范围，AppKit 负责拖出视口自动滚动。reset／resize／屏幕切换／重连清理过期选择；历史锚点与选择分开管理，并在解析先于呈现发生淘汰时重定位选择命中；矩形选择仍待补齐。
- **粘贴、链接、剪贴板**：已提取共用 Santty URL parser（旧主应用行为不变），native 参考 SwiftTerm 不可信字符／URL 策略，只允许显式 Cmd-click 的 http／https／mailto，URI 按原始字节验证并有提取总量限制，不查远端路径的本地 FS。剪贴板参考 Herdr 的 bounded last-value／严格 UTF-8 策略，程序读取保持禁用；VT 1.0 的同步原写请求拒绝，用户只能显式审阅并手动复制当前 offer，不能提前 SUCCESS 或保留回调指针。替换／断线／重连／reset／过期拒绝旧确认，不阻塞解析／credit。普通 scheme URL 已按 SwiftTerm 的线性 tokens／单元格范围思路接入，OSC 8 优先；实际 CG／Metal 下划线、原地 Cmd、滚动／字体／宽度重命中、微小跨格点击及未呈现改写拒绝均有回归。不引入另一解析器或历史文本缓存，只匹配捕获帧内有界软换行组，拒绝截断前缀。裸域名／路径、捕获范围外长链接、本地文件／自定义链接、程序读取与完整 Kitty／多 MIME／异步完成能力仍待设计，不把手动 copy offer 当完整协议对等。
- **图片与样式**：overline／显式 hollow 光标已接入现有 SwiftTerm 绘制路径并有 CG／Metal 像素回归；固定 VT 的图片 API 及有界拥有快照已验证；SwiftTerm 已新增可选精确目标尺寸并接 CG／Metal crop、offset、图层和共享原图 cache，保留旧客户端默认值；实际像素回归覆盖裁剪串色、透明度、虚拟切片、history／reset／screen 和 hold 清旧图。startup-only 静态 PNG callback 已完成，保留 allocator／输出限额、低 alpha 精度、ImageIO 容错校验和独立夹具；零尺寸虚拟 source crop、动画／APNG和完整设备覆盖仍是显式门槛。其他样式、色彩空间与设备视觉对等仍需审计；不支持项必须明确，不能只画出文字就宣称协议对等。
- **辅助功能**：基于 AppKit AX 接口补齐可读文本、选择和位置；当前 SwiftTerm 的 MacAccessibilityService 是占位，不能计为已复用完成。
- **历史锚点**：已使用预编译 VT 的 owned tracked grid reference；解析引用、计算新视口与采样帧在同一把锁下完成。保留原内容单元格（含 reflow 后的非零 column）与行内比例；淘汰后引用失效回到最早可用行，尾部约束恢复 follow，reset／RIS／已呈现屏幕切换／重连清理旧引用。已有并发解析、淘汰／反复 reflow／字号／高度变化及选择复制／自动滚动组合回归，不复制历史或按文本搜索。实体设备、跨屏和性能继续验收。

动画验证继续以以下三项为重点：

1. NSScrollView 驱动的分数像素历史滚动，含预取、弹性、滚动条和命中坐标；优先保留 AppKit 动量，不叠加第二套 easing。
2. 独立光标闪烁和移动过渡，分别验证 Core Graphics 与 Metal。
3. 布局过渡中保留内容、裁剪／平移与整体 FLIP 的对比，不把文字拉伸作为唯一方案。

点击、选择、链接、鼠标报告及 IME 必须与动画中实际内容对齐。resize、alternate screen、搜索跳转、Scroll Mode、重连和销毁需取消或重定位动画；尊重 Reduce Motion，隐藏／静止时不持续为动画请求帧。同步输出不能呈现半帧。

任意 TUI 重绘的行位移推断不属于首轮迁移目标。应用重画不等于滚动，不能为了动画改写终端真实状态。必要的 SwiftTerm 补丁应保持可审计、可复现，并评估上游提交和长期维护成本。

### 阶段 4：本地 PTY 与进程生命周期

优先将独立 `SwiftTerm.LocalProcess` 接到共用 I/O 边界，不使用 `LocalProcessTerminalView` 或额外的 SwiftTerm 模拟器。

- 接通启动、cwd、环境、字节输入／输出、窗口尺寸、启动失败和退出回调。
- 明确回调队列、串行顺序、解析调度和退出前尾部输出排空；不让 PTY I/O 直接调用主线程视图。
- 验证 terminate、descriptor 关闭、child reap 与进程退出的竞争；只作用于当前 session 的有效 PID／进程，不向零 PID、复用 PID 或用户无关进程发送信号。
- 保留 foreground PID／process group、PTY 从属端名称与 cwd 继承能力；不能把 shellPid 误当作当前前台程序，也不能直接把主端 fd 当作原来的 ttyName。
- 本地与远程实现保持明确边界：远程路径／PID 不使用本地进程或文件系统查询，远程 shell 不注入本地控制 socket。
- 用独立短生命周期测试进程验证大输出、resize、输入、退出及清理，不启动／终止用户已有 shell。

若 LocalProcess 某一行为不满足 Santty 生命周期约束，先用测试证明，再做最小适配或提取；不因“能参考”假定其默认策略已符合项目要求。

### 阶段 5：主应用整体迁移与旧依赖移除

当阶段 2–4 的核心能力已具备后，将同一个新终端实现接入全部 Terminal Pane：主区域、后台 Tab、浮动／detached Pane、侧栏、本地和 Herdr workspace。**不提供旧 Ghostty surface 与新 VT 的运行时切换，也不通过同进程双后端逐 Pane 放量。**

迁移检查：

- TerminalPaneController / HostView 不再直接依赖旧 surface；绘制、输入、读取、标题、cwd、焦点和退出经新接口提供。
- CLI 读取与输入、Scroll Mode、输入源切换、Pane 操作、agent 导航及工作区恢复保持语义；保留 CLICommandRouter 的授权、去重和非焦点操作约束。
- 保存格式继续为 v10，复用现有 Pane／workspace UUID、Herdr binding 和 viewer 语义，不通过新增 renderer 持久化字段绕过身份约束。
- 审计并移除旧 GhosttyTerminal、InMemoryTerminalSession、surface 生命周期桥接及旧 C core 的全部直接／传递链接。主题／配置若仍依赖旧包，保留纯 Swift 资源或迁移解析，不能为它们间接把旧 C core 链接回来。
- 原有 patch 和 teardown / wake 防护仅在对应旧路径已确实删除后清理；新路径仍需独立通过睡眠唤醒、后台输出和关闭测试。
- 迁移现有行为回归测试的观察点，不以删除测试、放宽断言或大面积 skip 代替功能适配。
- 普通 Santty scheme 构建、测试和依赖图中只保留一套终端模拟核心。Core Graphics / Metal 仍是同一新后端的两种呈现路径，不属于双模拟器。

切换前生产路径保持不变；切换提交在功能完整后整体移除旧依赖，不能让已生成工程的偶然状态决定应用使用哪个后端。

### 阶段 6：性能、体验与发布验收

在同一机器、窗口尺寸、字体、缩放、刷新率和可见性下，对比旧版本／旧构建的 Ghostty surface 与新路径的 Core Graphics、Metal。旧版以独立构建／进程作为基线，不要求与新库同进程共存，也不以同一 live terminal 的双输入／双应答做对照。

至少覆盖空闲、多 Pane、持续大输出、TUI 高频刷新、中文输入、图片、滚动和 resize。记录：

- 输入到字形呈现延迟、尾延迟、主线程停顿和真实帧间隔。
- CPU、GPU、内存、空闲唤醒与长时间输出后的资源增长。
- 文字观感、图片位置、选择复制、可访问性和动画中断／恢复。
- 多种输入设备、跨 scale 显示器、隐藏恢复、睡眠唤醒及关闭。

性能阈值在基线测量后、优化前确定，不能把刷新请求次数或单独帧构建耗时当作实际呈现性能。人工验收和自动化测试分别记录。

满足功能与性能门槛后再发布整体迁移；未达标则继续在分支开发或回到旧版本，不把长期双后端维护作为默认出口。

## 验收与回退

最终迁移需要同时证明：

- Ghostty VT 是唯一终端状态与协议应答来源；SwiftTerm 复用没有引入第二个模拟器。
- 本地 PTY 和 Herdr 均可交互，输入／IME／鼠标／选择／剪贴板／链接／图片、CLI、Scroll Mode、辅助功能与生命周期达到迁移检查清单。
- NSScrollView 的连续滚动、惯性、弹性与滚动条协调工作，绘制资源不随全部历史高度增长；命中坐标正确，历史阅读不被新输出打断。
- 至少一个终端内部动画带来可观察的改善，而非只动画面板外壳；两种绘制路径的延迟、多 Pane 和能耗有可复现测量。
- 原有 Herdr identity、credit、关闭、不重放输入、agent 跟踪和工作区／共享布局约束保持不变。
- 新主应用不再链接旧 surface C core；工作区保存格式与私有、原子、单写入者和拒绝覆盖不支持文件的规则不变。

回退通过 Git 分支／提交或已发布旧版本进行，不承诺运行中无缝切换新旧 renderer。新旧版本不同时写同一工作区存储；不得为回退删除工作区、重建 remote terminal 替代旧 binding、终止共享 core 或重放输入。由于持久化格式不变，旧版应可重新附着原有 terminal，仍需验证而不能只凭格式推断兼容。

后续实现与验证使用 FlowDeck 的已保存 Mac target；隔离实验沿用独立 scheme：

```sh
mise run terminal-lab:generate
flowdeck build -s SanttyTerminalLab
flowdeck test -s SanttyTerminalLab

# 主应用整体迁移后的验收
flowdeck config get --json
flowdeck build
flowdeck test
```

真实会话与 UI 冒烟测试使用隔离工作区／测试 terminal；不向用户已有终端注入测试输入，不停止或重启共享 core。
