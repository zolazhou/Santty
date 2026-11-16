# Native Terminal Lab 历史里程碑

> **仅供历史参考。** 实验 app／scheme／生成开关已经移除；以下保留早期验证、失败诊断和人工确认记录，旧 GUI 启动命令不再适用。当前目录、正式测试和探针命令见 [终端开发与验证](README.md)。

隔离的 AppKit 验收宿主：官方预编译 Ghostty VT → SwiftTerm 外部网格渲染 → NSScrollView 虚拟化历史视口。**共用实现位于 `Santty/Sources/Terminal/Native/`；原实验 fixtures 已迁为 `Santty/TerminalTests/Support/`，不连接用户已有终端、不保存工作区。** 当前主程序 387 通过／1 系统能力跳过，lab 458 通过／0 跳过；GUI／IME／AX／设备验收未因此完成。见 [切换记录](../../docs/plans/terminal-native-cutover.md)。

后续专项章节保留各阶段历史计数和当时的隔离接线状态；当前生产范围以顶部切换记录为准，不把旧人工确认外推到新主程序。

## 构建、测试、运行

需要项目支持的 Xcode / Swift 6.2+、mise 和 FlowDeck。沿用 FlowDeck 已保存的 My Mac target，不改写其配置：

```sh
mise run terminal-lab:generate
flowdeck build -s SanttyTerminalLab
flowdeck test -s SanttyTerminalLab
flowdeck run -s SanttyTerminalLab
```

窗口默认显示 2000 行固定 ANSI / Unicode fixture，可以追加、重置，以及切换 Core Graphics / Metal。两种 renderer 使用同一个 Ghostty VT 实例，不会产生第二个模拟器。

### 测试真实输入与输出

1. 点击 **Start private Herdr shell**，等待状态为 live，再点击终端输入。
2. 可测试 `pwd`、`printf 'hello\\n'`、方向键、Ctrl+C、中文输入和 Cmd+V。
3. 输出较多行后测试原生历史滚动；在历史中输入会回到实时屏幕。
4. 点击 **Reconnect viewer**，确认原 shell 保留，画面重建后可继续输入。断开期间输入不排队重放。
5. 点击 **End private test session** 返回 fixture；关闭实验 app 也会清理自己创建的测试环境。

启动需要 PATH 中可用的 `hc`。每次创建独立的临时 socket、session、HOME 和 XDG 目录，子进程环境使用白名单，不继承任意 HC 路由、shell 启动钩子、凭据或本地控制 socket。所有命令只作用于这个测试环境，不列举或操作用户已有终端。不会 restart 共享 core；退出时只结束自身测试 terminal 和经私有 socket 验证的测试 core。

### 鼠标、滚轮与复制

- 程序开启鼠标报告时，点击／拖动／滚轮经 Ghostty 编码送往程序，不再同时滚动本地历史。按住 Shift 可在手势开始时选择本地操作；中途改变修饰键不会转移已按下按钮的归属。
- 没有鼠标报告时，滚轮交给原生 NSScrollView；alternate screen 开启 1007 时，可按 VT 模式编码为程序方向键。动量期间切换模式／路由丢弃余下 travel，不把分数余量转交另一接收者；resize／失焦取消原手势，无 phase 的精细滚轮也可继续使用。
- 拖动选择、双击词、三击行、Cmd+A 全选、Cmd+C 复制，以及拖出视口后的自动滚动已接通。选择由 Ghostty tracked gesture 管理，复制直接来自其 formatter，保留 Unicode、宽字符与软换行语义；只显式复制，不自动写剪贴板，默认限制 32 MiB。
- 历史阅读时，首次面向程序的点击只回到实时画面，不点击尚未看到的程序内容。鼠标释放可穿过同步输出 hold，避免程序按钮卡住；重连／屏幕切换／resize 清理过期选择和手势。

原始 Kitty RGB／RGBA 与直接 `f=100` 静态 PNG 图片已接 CG／Metal 并有实际像素回归；VT-owned Kitty 动画截止时间调度也已接入；GIF／APNG 和完整设备／协议对等仍未完成，细节与零尺寸虚拟切片限制见 [IMAGE-COMPATIBILITY.md](IMAGE-COMPATIBILITY.md)。矩形选择和完整交互对等仍未完成。鼠标／滚动／锚点两轮已获用户当前环境的人工确认；不等于完整输入法、跨设备或协议认证。

### 普通 URL／OSC 8 链接与受审阅复制

- OSC 8 的 URI 从 VT 获取并复制到有界拥有数据的帧；普通 `http://`／`https://`／`mailto:` 文本按 SwiftTerm 的 scheme URL tokens 与单元格范围思路识别，OSC 8 优先。Cmd-hover 实际绘制下划线并显示目标／手形光标；原地按放 Cmd、滚动或字号／宽度改变都会更新命中，不抢 first responder。
- Cmd-click 只在同一链接的 mouse-up 打开；允许 4 pt 内跨相邻字符的微小位移，拖动、输入、reset、目标变化或过期画面会取消。普通 URL 在 VT 锁内重新采样校验，不能打开尚未呈现的改写目标。该手势（含空白处）不同时发给程序；宽字符尾格归到头格。
- Native 只允许 `http`／`https`／`mailto`，拒绝凭据、控制／不可见字符（含百分号编码）、相对路径、file 和自定义 handler。路径在调用共享 parser 前就拒绝，不查询本地文件系统，也不将远端文件映射到本地。未实现裸域名、隐式路径或本地文件打开。
- 普通 URL 只检查已发布有界帧中的 VT 软换行组，最多 64 Ki UTF-16 units；支持宽字、组合字符和 wrap spacer 的格子映射，不跨硬换行猜测，也不打开断在帧边界的截断前缀。超出捕获范围的长链接仍是明确限制，不另存历史文本。Reset fixture 底部提供普通 URL 和 OSC 8 label 两个自然体验样例。
- URI 原始 UTF-8 字节参与行复用和 release 校验，不把 NFC／NFD 等价字符串当作相同目标；每条提取最多 8 KiB、单帧 URI 总量最多 128 KiB。固定 VT 自身可能更早拒绝长 OSC 8，8 KiB 不是实际可用长度承诺。
- 程序写剪贴板只产生一个待审阅 offer（最多 1 MiB、120 s 单调时钟有效期），**不会自动写系统剪贴板**。私有 shell 发出请求后点击 **Review Copy… → Copy Once** 才复制；新请求、断线、重连、rebind、reset／RIS 或过期会使旧确认失效。取消不会复制，也不会自动弹出下一个对话框。
- **VT 1.0 的 clipboard reply 必须在同步回调内完成**，不能保存借用指针做旧 surface 式异步确认。本轮原协议写始终同步拒绝，不提前回报 SUCCESS／DONE；后续是用户显式复制已提供的文本。OSC 52 无写入 ACK，Kitty 写入会收到 EPERM；这不是完整的 Kitty 写权限协议实现。
- 没有 clipboard-read callback：OSC 52 查询被忽略，Kitty 读取被拒绝，不读系统剪贴板、不记住程序 grant。保留现有用户主动 Cmd+V，与程序读取权限严格分开。空 OSC 52 写在此 VT 中表示 clear，同样须确认；Kitty 的空 text/plain 表示与 clear 分开处理。

例如仅在自己的私有测试 shell 中：

```sh
printf '\033]8;;https://example.com\033\\Example\033]8;;\033\\\n'
printf '\033]52;c;aGVsbG8=\007'
```

第一行需你 Cmd-click 才打开；第二行仅启用 Review Copy，确认后才复制 `hello`。本轮 GUI 体验仍待用户验证。

普通生成不包含实验 target；主程序本身已使用 SwiftTerm 与独立 VT：

```sh
mise run tuist:generate
flowdeck build
flowdeck test
```

再次使用实验 target 前，重新运行 `mise run terminal-lab:generate`。未修改 FlowDeck 的默认 Santty scheme。

## 依赖与隔离

`Scripts/prepare-native-terminal.sh` 下载并校验固定版本，放入忽略的 `Vendor/native-terminal/`：

| 依赖 | 固定版本 | SHA-256 |
| --- | --- | --- |
| SwiftTerm 源码包 | `28c6d1d95de156a36a2eaa278177ee7f8a15d322` | `d77fff6d836b6a142325d736e84b481f637d9b4733aad36431f1d2ff24338d2e` |
| 官方 Ghostty VT XCFramework | `1.0.0` | `2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2` |

VT 二进制来自 `https://release.files.ghostty.org/libghostty-vt/1.0.0/ghostty-vt-1.0.0.xcframework.zip`；校验值对应官方 SHA256SUMS。没有执行 Zig 编译，没有改动生产 GhosttyKit。

现有完整 Ghostty C archive 不导出独立 `ghostty_terminal_*` / `ghostty_render_state_*` 接口。对 arm64 archive 进行 `nm -gU` 检查发现两库有 859 个重合的全局定义，包括 SIMD 和第三方 C++ 符号。因此本阶段单独链接成实验 app，尚未验证两库同进程共存。迁移策略现已调整为**分阶段开发、主应用整体替换**：最终移除旧 surface C core，只链接预编译 VT，不再为双后端共存预先实现符号隔离层。

SwiftTerm 的本地补丁：`Patches/SwiftTerm+ExternalFramePresentation.patch` 暴露同步 `presentExternalFrame()`，跨行时先准备快照再移动有界 surface，行内移动不生成新帧；`Patches/SwiftTerm+AppKitCaretDrawing.patch` 补齐 CaretView 的 AppKit `draw(_:)` 入口，保留原有 Core Animation 闪烁；`Patches/SwiftTerm+ExternalStylePresentation.patch` 在现有属性表与装饰线／caret 路径中补 overline 和显式 hollow 标记。前三项补丁保持 8-byte packed cell、8-bit legacy style 和原有字形绘制，不修改终端解析器、编码器或 Metal shader。另有 `Patches/SwiftTerm+ResolvedImagePresentation.patch` 增加可选精确像素尺寸、共享矩形换算、原图缓存和 crop-edge 采样限制；此图片补丁新增专用 Metal fragment，传统 glyph／未指定 resolvedSize 的客户端路径不变。补丁依赖固定 revision，prepare 可重复运行，并校验两份 shader 定义均已安装。

SwiftTerm、Ghostty 及适配参考 herdr-app 的许可证／NOTICE 位于 `Licenses/` 并随实验 app 打包；完整第三方依赖许可证清单仍是正式分发前的检查项。

## 实现边界

- `GhosttyVTDriver`：以锁串行化所有 C 访问和回调状态；在 Herdr stream 队列解析，主线程采样拥有数据的帧，不保留借用的 C 指针。处理自动应答、尺寸查询、键盘／粘贴／焦点编码，以及跨批次的同步输出 hold。hold 最长 1 s，期间继续解析、应答和返还 credit。
- `NativeTerminalOutput`：实现共用 `TerminalStreamEndpoint`，receive 返回前完成解析，绘制通知合并为最多一个待执行主线程任务；回复立即交给当前 channel，不等待 UI，也不保存离线输入。
- `NativeHerdrLab`：复用生产 `HerdrTerminalSession` / `HerdrCoreClient` / transport，仅注入 native endpoint。旧 InMemory 适配留在 `HerdrTerminalSession+Ghostty.swift`，不混链两套 C core。私有测试环境的启动／退出竞争和重复清理有测试覆盖。
- `NativeAppKitKeySnapshot` / `NativeKeyNormalizer`：平台数据采集与纯函数归一化分离，保留物理／逻辑身份、文本、未修饰码点、原始／已消费修饰符、Option 左右侧策略和 action；C0/C1/DEL／功能键不作为编码器文本。
- `NativeKeySequence`：只记录实际发送过的 press；repeat／release 复用身份，失焦／重连清理后丢弃孤立事件。
- `NativeTerminalInputView`：参考 SwiftTerm 的 AppKit／NSTextInputClient 分层，仅负责平台分发与 preedit 呈现；键、提交文本、粘贴和焦点经明确意图送到唯一 user writer，不启用第二套 SwiftTerm 编码器。
- `NativeClipboardInbox` / `NativeClipboardReview`：参考 Herdr 的有界 last-value 数据捕获和 Santty 的确认语义；C 同步拒绝原请求，UI 只在用户点击后审阅并复制当前 token，不持有 C 回调指针、不阻塞解析。
- `NativeTerminalLink` / 共用 `TerminalLinkValidation`：复用 Santty parser，参考 SwiftTerm 的不可信字符策略；native 使用更保守的 scheme 白名单。主应用旧 URL 打开／确认行为未改变。
- `NativePointerInput` / `NativeTerminalInteraction`：纯 wheel 路由与 AppKit 事件所有权分开；原生历史滚动和程序报告互斥，选择自动滚动只在拖选中运行，不获取新的 first responder。
- `GhosttyVTPointerCore`：在 driver 同一把锁下使用 C mouse encoder、tracked selection gesture 和 formatter；位置参考在调用内获取，跨输出／历史滚动的选择由 VT 跟踪，不另建 selection buffer。
- `GhosttyVTImages`：在同一 driver 锁下采样当前捕获图片的 generation／RGBA 与 VT 已解析的 placement，缓存只留捕获图片；保留网格、像素、crop、offset、layer 及 kind，不重解 Unicode placeholder。禁用并核对 file／temp／shared-memory transport；原始数据可用不等于已显示图片。
- `NativeTerminalFrame`：拥有数据的快照和逐行选择范围；行标识使用 Ghostty 的两个 opaque word。只缓存当前视口和 overscan，不复制全部 scrollback。
- `SwiftTermFrameSource`：增量构建 BufferLine，不创建 SwiftTerm.Terminal；复用未改变的行，保留调色板索引，接近 arena 容量时重建 store。
- `NativeViewport`：纯几何计算，把连续偏移拆为整数行和行内像素；输入坐标同时考虑弹性区域。
- `NativeTerminalScrollView`：高文档只表达历史范围，renderer 保持有界；保留 AppKit 原生滚动。live 窗口未显示时仅标记待更新，不转换／绘制输出，重新显示再恢复。同步输出 hold 期间保持已发布画面的屏幕位置，但保留 AppKit 累积的用户滚动；解除或超时后相对原内容锚点一次应用滚动。不再将 clip 强制拉回旧位置，也不将旧快照标成新行或展示半帧输出。
- `GhosttyVTHistoryAnchor`：每个 driver 持有一个 VT tracked grid reference，跟踪上次发布内容的单元格；淘汰／reflow 后先解析引用，再在同一把锁下采样帧，不靠行号、文本搜索或另一份历史缓冲。行内移动不重建帧。
- 输出追加在原本位于底部时跟随；阅读历史时保留内容单元格及行内比例。resize／字号变化后引用继续跟随原单元格，底部范围约束生效时恢复尾随；原内容被淘汰则回到最早可用行，reset／RIS／已呈现屏幕切换／重连回到实时画面。锚点不冻结程序正在改写的内容。

## 后续实施路线

完整路线见[实现计划](../../docs/plans/terminal-framework-rendering.md)。阶段 2 的本地私有 Herdr 链路与双私有 core 的 native 远端代理回归已通过；阶段 3 已补鼠标／滚轮／选择复制及稳定历史锚点。已接保守的普通 scheme URL／OSC 8 与剪贴板 offer 安全边界；已补只读有界 AppKit AX；接下来收敛完整呈现、AX 人工／IME／完整滚动树与平台输入缺口，已接独立本地 PTY 实验；完成其人工／shell／生命周期门槛后，最后整体迁移主应用。

主应用阶段 5 的[迁移接线审计](../../docs/plans/terminal-framework-migration-audit.md)已建立，包含旧模块／主题传递依赖、全历史 CLI、Scroll Mode、生产启动与 async close 缺口、切换顺序及只读清单检查。隔离 5A 已接 485 纯主题／typed settings／title/raw-cwd metadata，5B 已接全 retained-history read/search、可复用 Local owner／launch policy／close barrier，以及 Scroll Mode 的 VT core ports／keyboard UI／输入隔离／overlay／本地 pointer，并已补菜单／拖放／VT 安全粘贴／输入源 target／named-key ports，以及 session/frontend 工厂／混合关闭屏障／await 后 owner 校验，当前实验 **458 通过／0 跳过**，主应用最新 **383 通过／1 系统能力跳过**；主后端尚未切换。

本地 PTY 实验已复用 SwiftTerm 的独立 LocalProcess，未使用带第二模拟器的 LocalProcessTerminalView。选择参考其算法，不直接使用依赖 SwiftTerm.Terminal 的 SelectionService；MacAccessibilityService 为占位，本轮已单独新建只读 AppKit AX（参考 SwiftTerm iOS page/line 接口），尚未获得 VoiceOver 人工认证。当前最小键盘／IME 实现不代表 KeyboardRouter 的全部平台细节已覆盖。

旧版通过 Git／旧构建回退，不计划运行时双后端切换；Core Graphics / Metal 切换仍是同一个新后端内的呈现选择。

## 验证范围与缺口

阶段 2、输入兼容、鼠标／选择及历史锚点专项 FlowDeck 验证：实验 scheme 构建成功，139 项测试通过、无跳过（含 Metal 像素回读与私有真实 hc 会话）；普通生成后主应用构建成功，本轮全量 362 项通过、1 项跳过（当前 macOS 无私有 effective corner radius getter）。本轮安全／真实消费者专项复跑曾有一项 nvim 快速粘贴＋Enter 超时，后经独立 PTY 对照定位为消费者输入调度竞争；保留诊断脚本，端到端测试等实际粘贴应用后再送 Enter，未加长超时或改变生产字节。该单项随后连续 10 次通过，安全／真实消费者联合专项最终复跑 31 项通过。此前首次全量有一项旧远程测试在机器重命名后的 agent 元数据阶段超时，单独复跑及全量复跑均通过，未改测试或加长等待；时序问题未稳定复现，未宣称已修复。后续额外复跑遇到旧 DerivedData 目录缺失、SPM 提取／JSON 失败，未清公共缓存；改用独立临时 DerivedData 重新构建和全量验证，实验仍 139 项通过。该目录的默认 scheme 合计 501 项通过、1 项跳过（含主应用 362 与实验 139），不将两套测试混报为主应用 501。FlowDeck 保存的 My Mac／Santty 默认配置不变。测试没有打开前台实验窗口或操作用户终端。

自动测试覆盖 Unicode / 字节分片、宽字符尾格、样式、调色板与擦除背景、行复用、6000 行输出保留、overscan、alternate screen、reset / resize、分数像素几何、输出跟随和有界 surface。Core Graphics 截图和 Metal 离屏纹理回读验证实际字形／背景绘制与调色板变化；只“有像素”不算通过。

新增回归覆盖跨批次 hold、超时无新输出仍刷新、reset 后首批同步输出、自动应答、键盘／粘贴／焦点模式、尺寸查询、后台解析不依赖主线程绘制、离线输入不重放、最小 IME 提交／取消及候选框坐标。真实私有 core 测试验证超过初始 credit 的 8000 行输出、6000 行以上历史保留、尺寸更新、身份不匹配拒绝、viewer-only 关闭仅 detach、同绑定重连，以及启动与退出竞争时清理私有环境。

光标回归通过 AppKit 的实际 view 绘制入口检查空白提示符上的像素，覆盖聚焦／失焦、block／bar／underline、程序隐藏／恢复及历史滚动位置；Metal 单独回读隐藏前后像素差异。真实私有 shell 测试检查首次输入与重连后的光标状态。VT 快照以 active-screen 光标位置计算绝对行，允许显示 native 视口中落在 Ghostty overscan 的最后一行，不读取 `viewport_has_value == false` 时未定义的位置字段。

控制键回归从 AppKit `keyDown` 验证 Ctrl+C/D/Z/A/E/U/L、NUL、退格及传统控制别名，并检查 Kitty 与 modifyOtherKeys 模式下保留原始组合键。macOS 的 C0/DEL 转换结果不再作为 UTF-8 按键文本传入；非组合输入中的 Ctrl 直接走 VT 编码，active composition 仍由 IME 处理。固定版本的编码器将 Ctrl+I/M/[/- 的 legacy 别名留给调用者，adapter 参考 Herdr 的处理方式：Kitty 不替换原组合键，modifyOtherKeys 通过编码器探测，其他情况使用标准别名，不自建协议状态机。真实私有 shell 中曾复现 Ctrl+C 发出 `CSI 3;5u` 且前台程序未中断，修复后验证实际发送 ETX、收到 SIGINT、退出前台程序后仍可输入。

修饰键回归覆盖 Neovim 使用的 Kitty disambiguation 模式下 `:`、`?`、`!`、`+`、大写字母、Option 生成文本，以及 Kitty press／release。AppKit 已用于生成可打印文本的 Shift／Option 通过 consumed modifiers 传入编码器，不再将 `:` 重复报告成 Shift+分号；控制字符、Shift+Tab 和 Shift+方向键保留原修饰符。真实私有 `nvim --clean -n -i NONE` 通过 CmdlineEnter 记录确认原生 Shift+分号进入命令行，再通过提交文本和原生 Enter 执行命令写入私有结果文件；不只检查屏幕是否出现冒号。输入专项另有独立的括号粘贴测试：确认 VT 2004 已开启后，在私有 clean nvim 的普通、插入及命令模式验证实际缓冲区／命令执行结果。就绪确认来自程序事件循环，不加固定延迟。原观察仍保留为回归，不武断宣称单一生产根因。

### 鼠标／选择与 native 远端回归

固定字节向量覆盖 X10／普通／button／any tracking、legacy／UTF-8／SGR／urxvt／SGR-pixel、修饰键、扩展按钮、运动去重、同格像素移动、分数行高／Retina、1007 与过期模式／几何拒绝。前端测试验证程序滚轮不移动本地历史、Shift 选择不发程序输入、键盘输入不丢失程序拥有的 mouse release。选择测试覆盖词／行、软换行／宽字符／组合字符、历史与 scroll/reset/resize，CG 与 Metal 均检查选中／清除前后的实际像素。

私有 `nvim --clean` 验证点击改变实际光标行列、滚轮改变窗口 topline；独立 `tmux -S <私有 socket> -f /dev/null` 验证点击切换 pane、滚轮进入 copy mode。就绪由模式、输出与消费者事件确认，不以固定 sleep 猜测。测试仅结束自己的 tmux server 与 Herdr core。

两个临时私有 Herdr core 通过真实 `hc machine --via` 代理连接，native endpoint 验证远端解析、远端 PTY 收到固定鼠标字节、同永久 core／terminal 身份和 PID 重连、选择清除、离线输入不重放，以及 viewer-only detach 不结束原程序。此项不是实际 SSH／跨机器网络验收；只在私有 socket 存在并验证后执行可变操作／清理，不改用户机器 profile 或共享 core。

本轮专项复跑复现了 nvim 0.12.5 的命令行括号粘贴＋CR burst 竞争：wire 是完整正确的 `CSI 200~…CSI 201~ CR`，但消费者先留下空 CmdlineLeave，随后把文本放进普通缓冲区。独立私有 PTY、不经过 Santty／Herdr／VT adapter 的对照中，burst 3/3 失败、等 CmdlineChanged 确认粘贴已应用再发 Enter 的 control 3/3 成功，与该版本 `vim.paste` 用 `nvim_feedkeys` 入队的实现相符。端到端用消费者事件确认后继续，不插入生产延时或 nvim 专用输入改写；这不是完整快速 burst 兼容性的修复，也不武断回溯为原观察的唯一根因。

可独立复查（只创建／结束自己的 PTY 与进程）：

```sh
python3 Scripts/Terminal/check-nvim-paste-order.py
```

脚本将 burst 结果作为观察报告，不把失败算通过，gated control 失败会报错。此消费者限制仍保留，不由协议测试数掩盖。

隐藏测试窗口中的无 window CG wheel 不能证明 AppKit 的真实滚动手感；自动测试检查独占分发边界，实体设备的惯性／弹性与跨屏手感仍是独立验收项。

本轮 Cmd URL 诊断先复现普通 URL 点击、hover 不绘制、原地按 Cmd 不刷新、轻微跨字符位移取消四项失败，再修复并补充回归。FlowDeck 实验全量 **153 通过／0 跳过**；主应用 **361 通过／2 环境跳过**（旧 Ghostty Metal 图形显示条件与私有圆角 getter），无失败。未修改保存的 My Mac／Santty 默认配置，未自动操作用户会话；本轮 GUI 仍待用户重启实验版复验。

### Overline／hollow cursor 呈现回归

`NativeTerminalStyleTests.swift` 的 12 项专项先复现四项实际像素缺口，再覆盖 CG／Metal 的 overline 空白格、SGR 53／55、行顶位置、前景色而非 SGR 58 颜色、ASCII／粗斜体／宽字／组合字符、palette 更新、选择与链接 hover 叠加、conceal，以及 focused hollow 的空心形状、宽字尾格定位与恢复实心。属性身份回归覆盖全部旧样式位并存、彩色 nil cell 不被 background shortcut 丢失装饰，确认 packed cell 仍为 8 bytes。

Hollow 复用 SwiftTerm 原有失焦 outline 几何，但不伪造 `hasFocus`，blink／隐藏仍独立。`GhosttyVTDriver.setDefaultCursorStyle` 通过 VT 1.0 的 default cursor options 提供宿主默认值；程序 DECSCUSR 覆盖仍优先，CSI 0 q 按 VT 规则恢复默认，CG 的 Core Animation 闪烁有检查。此 API 尚未接主应用偏好 UI。fixture 文字已加 overline 样例。

当时以 calibrated RGB 红 `(255, 38, 0)` 作为 CG 参考；后续 host 里程碑的独立 AppKit 探针发现缓存位图的 ICC 取色前提错误，且固定 SwiftTerm `TTColor.make` 实际构造 sRGB CGColor。原 calibrated swatch 与失败值保留在独立探针／[HOST-COMPATIBILITY.md](HOST-COMPATIBILITY.md)，现在只修测试的 profile-aware readback／独立 sRGB swatch 参考，不改渲染器／容差或宣称跨设备校色。VT 对全空白终端 selectAll 不产生范围的控制仍保留。

本轮 FlowDeck 实验全量 **165 通过／0 跳过**；主应用 **362 通过／1 系统能力跳过**（私有 effective corner radius getter 不可用）。准备脚本幂等、固定基线补丁应用和打包 NOTICE 已检查。仍未操作用户终端或取得本轮 GUI 人工验收；仅验证 macOS，补丁中的 iOS caret 字段连接不等于 iOS 认证。

### 稳定历史锚点回归

`NativeHistoryAnchorTests.swift` 覆盖真实页面淘汰、丢失引用降级、重复缩窄／扩宽后的原单元格及非零 column、字号／行内比例、仅改变窗口高度、底部跟随、程序 RIS／soft reset／alternate screen、重连 reset、reset 不携带旧弹性位移、同步输出 hold，以及并发解析和原子锚点帧采样。诊断用 `snapshot` 不替换 UI 的内容引用；分数行移动也不把 reflow 后的原单元格偷偷改成新行首。

选择命中按已发布帧的引用重定位，覆盖“解析先淘汰旧页，主线程还未呈现”的窗口；引用已失效或 reset 后直接丢弃该次选择，不命中无关的新行。AppKit 回归验证淘汰前后的选中文本、显式复制、新选区与画面一致，以及淘汰后拖选自动滚动复制预期原始行，不抢 first responder。resize 后选择仍按既定策略失效，阅读锚点与选择生命周期分开。

组合回归另复现并修正了 AppKit 普通 mouse release 清掉多击序列的问题：正常 release 保留 VT 的双／三击判断，只有未应用的 release（如 hold 期间）才取消手势。现在从 AppKit 事件入口验证词／行选择，而不只测 C 手势函数。

淘汰夹具显式设置较小的 line cap，并确认实际发生 page pruning；未调低默认 8 MiB byte budget，原 6000 宽行／真实 credit 回归仍运行。测试通过不等于实体设备／跨屏体验或性能验收。

### 链接／剪贴板回归与参考边界

`NativeTerminalLinkTests.swift` 覆盖固定危险 URL、Unicode 路径、NFC／NFD 目标变化、碎片／软换行／宽字 URI、只改 URI 的行缓存更新、总量上限，以及 Cmd-click 与程序鼠标报告互斥、普通点击／孤立 release／拖动／reset／目标改写不打开。新增普通 scheme URL、标点／IPv6、UTF-16 与格子映射、软换行／wrap spacer、截断前缀与 OSC 8 预算耗尽后的 fallback 拒绝；AppKit 回归包含原地 Cmd、退出／释放修饰键、分数滚动／字体／宽度改变、微小跨格点击和未呈现的普通 URL 改写。CG／Metal 像素回读确认下划线真正出现并恢复，保留程序自带下划线与颜色。所有 URL opener 都注入假实现，不会在测试中启动浏览器。

`NativeClipboardTests.swift` 移植 Herdr 的 OSC 52 固定字节与大小／UTF-8／selection-location 用例，并单测本次 ABI 的同步拒绝、clear 与空 MIME 表示、原子多 MIME 拒绝、隐形字符预览、过期与一次性 token、替换／离线／重绑／reset 后的确认拒绝。测试只操作唯一命名的私有 pasteboard，不读取或写入用户的 general pasteboard。主线程等待期间后台解析和自动回复仍完成。

真实私有 Herdr 回归验证 offer 与 OSC 8 经同一 transport 到达、确认待定时超过初始 credit 的输出仍排空、重连保留 binding 但旧 offer 不能复制，新请求需新确认。未重启共享 core。

参考固定 herdr-app `vt.rs` 的 last-value、1 MiB／严格 UTF-8／无 read callback，以及 SwiftTerm `UntrustedTerminalLink.swift` 的字符策略、平台 delegate／无 `main.sync` 经验。不照搬 Herdr 的旧 `request.size` ABI 或提前 SUCCESS，也不照搬 SwiftTerm 自己的异步 OSC 回复编码器。所有 protocol 回复仍由 VT 负责。许可／差异见 `Santty/Resources/TerminalLicenses/Keyboard-Adaptation-NOTICE.txt` 与 `Licenses/Link-Adaptation-NOTICE.txt`。

### 图片 API／快照阶段

新增 `NativeImageSnapshotTests.swift` 的 15 项固定数据回归，确认预编译 VT 的图片迭代器／像素／generation 在运行时可用；覆盖 RGB／RGBA／straight alpha、source crop／offset、仅几何 resize 的像素复用、等尺寸替换、分块、VT 解压缩、历史／delete／reset／screen 隔离、图层、virtual／relative placement、限额、hold 期间继续解析／应答及外部传输拒绝。默认 scrollback 仍为 8 MiB。

保留 `Tools/probe-vt-image-api.{c,sh}` 独立 C 对照：1×1 图片放大为虚拟 4×4 格后的首个切片由固定 VT 返回 0×0 source crop，4×4 源图对照正常。适配器对该条目显式报 `limited`，不偷用另一套 placeholder／crop 解析，也不以测试总数掩盖此缺口。该快照里程碑当时未装 PNG decoder；后续静态 PNG 传输已接通，见下节。

本轮 FlowDeck 实验全量 **180 通过／0 跳过**；主应用 **362 通过／1 系统能力跳过**（私有 effective corner radius getter）。未修改保存的 My Mac／Santty 默认配置。

### 图片呈现阶段

已完成可选精确目标像素尺寸输入、点／像素换算、图层、裁剪与 cache 生命周期。`NativeImageRenderingTests.swift` 的 21 项回归覆盖实际 CG／Metal 像素、非网格整数尺寸和偏移、方向／横纵裁剪、crop 串色修复、透明度、三层顺序、等尺寸替换、delete／reset／screen／history 淘汰、负坐标裁剪、有效 virtual slice 与退化拒绝、共用原图缓存、1×／2× 几何、分数滚动／不抢焦点及 hold 中重连清旧图。

两条路径的裁剪放大初测均出现相邻像素串色：CG 改为插值前裁剪 CGImage；Metal 用专用 fragment 将采样钳在源矩形像素中心，同时保持一个整图 texture，不改 nearest 采样掩盖问题。重连／reset 先清宿主 source，hold 中排队 tick 不可再展示旧图片。调色板测试显式声明颜色，有效 virtual 控制使用匹配物理网格的源图；原始退化向量仍保留为受限案例。

本轮 FlowDeck 实验全量 **199 通过／0 跳过**；主应用 **362 通过／1 系统能力跳过**（私有 effective corner radius getter）。四项 SwiftTerm 补丁已从还原基线按 prepare 顺序重新应用并逐文件比对，脚本幂等、shader 双形式一致；保存的 My Mac／Santty 默认配置未变。

重启实验版后，应用菜单 **Image fixture** 可显示 RGBA 四色图、源裁剪和直接 PNG 四色图；真实 private shell 活动时该操作不可用，不向 Herdr 注入夹具。**PNG 已获用户当前环境人工确认（不外推双路径／跨设备）；动画仍需单独复验**。完整边界和后续门槛见 [IMAGE-COMPATIBILITY.md](IMAGE-COMPATIBILITY.md)。

### 静态 PNG 传输阶段

这里补的是 Kitty **`f=100` 直接传 PNG**，不是“PNG 文件此前无法预览”：Yazi 26.9.1 的 KGP 路径会自行解码／缩放文件，再发送 RGB／RGBA；用户截图已证明那条路径在当前 CG 环境可用，不代表新 PNG callback 已获 GUI 验收。

`GhosttyVTSystem.prepare()` 在 NSApplication／测试／transport 线程前一次安装回调，driver 工厂共享同一 once guard。ImageIO 解 PNG，vImage 直接转换为 sRGB、top-first、straight-alpha RGBA8，避免先预乘再反预乘损失低 alpha；所有输出由 VT 提供的 allocator 分配／释放，只有完全成功后转交所有权。输入／输出各限 16 MiB、单边 8192；VT 可更早拒绝，ImageIO 内部缓冲不计入该 allocator，不能据此承诺整个进程只用 16 MiB。

11 项 decoder 回归使用 Python stdlib 独立生成的 10 种 RGB／RGBA、灰度、palette/tRNS、16-bit、Adam7 向量，另覆盖额度、allocator 拒绝／失败释放、损坏／截尾、已识别多帧 APNG 拒绝、分块／generation 和多线程解析。CG／Metal 新增两项 `f=100` 四色方向／低零 alpha 实际像素验证；私有 Herdr shell 检查 PNG、超初始信用额度输出、binding 和删除。本轮实验全量 **213 通过／0 跳过**；主应用 **362 通过／1 系统能力跳过**。

实际复现并修正：ImageIO complete 状态甚至 vImage success 都可能伴随 nil pixel provider／黑图，且 ImageIO 容忍缺少 IEND。现在额外校验真实 provider、stride 和最终 IEND；坏图仍拒绝，失败精确归还 VT 分配。VT 初建物理 cell size 为零也会使“OK”没有 placement，driver 现以自己已报告的 8×16 默认 metrics 初始化，布局后再按真实字体／scale 更新。`Tools/probe-png-host.swift` 和 C probe 独立保留证据；没有延长等待或修改原始字节冒充修复。

同 ID 重传时，固定 VT 在传输开始即撤下旧图片，未完成／失败都不保留旧 storage，独立 raw-image C 对照同样复现。因此测试明确记录非原子替换，而非让适配器显示陈旧图片伪造原子性；旧 owned snapshot 的字节仍有效。该 PNG 阶段后已接 Kitty 动画调度，见下节；多帧 PNG 播放、零 crop 和完整设备／协议门槛继续开放。

```sh
python3 Scripts/Terminal/generate-png-vectors.py
xcrun swift Scripts/Terminal/probe-png-host.swift
sh Scripts/Terminal/probe-vt-image-api.sh
```

### VT-owned Kitty 动画阶段

`a=f`／`a=a` 的帧、合成、循环和下次截止时间全部由 VT 管理。`Driver.presentation` 在锁内、capture 前只调用一次 animation tick；snapshot／hover／传输解析不推进。单个终端保持同一 UInt64 单调毫秒时钟，跨 reset 不换 epoch，迟到只推进 VT 的一帧，不循环追帧。

宿主只排一个 weak MainActor deadline task；sleep 后才 unwrap view，cancel＋token 拒绝旧回调。窗口／应用隐藏、遮挡、最小化、detach、close、display sleep 和同步输出 hold 停调度；恢复时按 VT 的新截止时间继续，不重放输入、不抢焦点。无图片真实相交于 NSScrollView clip 就不排任务，overscan 不能单独续命；分数行滚动也可停／续计时而不重建行。第 5 项小补丁 `SwiftTerm+ImageGeometryVisibility.patch` 导出现有矩形换算，旧 vendor 缓存会自动升级；不另写 placement resolver。调用方必须传 cell 底边，1-physical-pixel 用例复现并修正了早期错误的顶边原点。

新增 8 项 driver、10 项 view 和两条 CG／Metal 动画像素回归（保留旧 owned pixels、text row conversion 不变、cache 仍有界）；覆盖有限／无限、迟到、时钟回退、PNG animation frame、zero gap、stop/delete/screens/reset/hold、真实 deadline 无新 output 刷新、hidden pending refresh、lifetime 与解析／credit 独立。独立 C probe 锁定红绿蓝的 101／251／451 ms 截止时间和帧像素。私有 Herdr shell 真正收到动画绿帧，再隐藏并跑超初始信用额度输出，保持 binding 且不留 timer。

XCTest 应用确实处于 hidden；视图用例仅注入应用 visibility、使用自有 synthetic window，不激活实际窗口，也不更改生产隐藏条件。它们不是 GUI／设备验收。VT 的 deadline 是 active storage 全局的，若静态图可见、只有另一幅离屏图在动画，公开 API 未给逐图 deadline 身份；不冒称逐图能耗优化完成。

本轮实验 **234 通过／0 跳过**；主应用 **362 通过／1 系统能力跳过**。重启实验版后在 fixture 模式打开 **Animation fixture**，应看到 500-ms 红→绿→蓝循环；分别切换 CG／Metal 并手动隐藏／恢复可复验。本轮没有新的动画人工确认。GIF／APNG 解码／播放、零 source crop 和完整能耗／设备／协议覆盖仍开放。

### 只读 AppKit AX 阶段

已接独立的只读 AXTextArea，见 [ACCESSIBILITY-COMPATIBILITY.md](ACCESSIBILITY-COMPATIBILITY.md)。VT formatter 在原 driver 锁内生成当前捕获窗口的文本；AX 查询仅访问发布后的有界文本／UTF-16／VT 单元几何，不取新输出、不 tick 动画、不改 terminal selection、不发输入、不抢焦点、不接触粘贴板。CG／Metal 共用同一个元素，AppKit 默认 hit testing 和原生 NSScrollView 保留；未加入 legacy 非隔离 AX 入口的同步 main dispatch。

SwiftTerm 的 MacAccessibilityService 在 pin 中确为占位。参考的是其 iOS page／line／frame 接口形态，本轮新实现 AppKit协议和独立回归，没有实例化 SwiftTerm.Terminal。AX 用 physical visual rows（VT unwrap=false／trim=true），完整历史索引／可写选择不在此阶段；normal copy 继续 unwrap=true。页内选择可能不同于完整 history copy。隐藏 SGR8 和 image placeholder 内容不会被当作可读字；未提交 IME preedit 不重复成为 committed AX 内容。

VT 默认非 2027 模式把 ZWJ 分散到多个 cell。原始测试保留，AX 以 Foundation 组合字符范围导航，矩形仍合并原始 VT 单元；不修改核心字符宽度或打开模式冒充修复。UTF-16 surrogate／overflow／NSNotFound、宽字符、CJK、NFD、空白光标、history cursor、fractional／overscan 裁剪和字体变化有固定断言。1 MiB formatter UTF-8／256K indexed cells 是当前窗口上限，不是总 heap 上限；超额／不匹配只限制 AX，不停渲染或缩小 scrollback。

19 项 AX 回归＋私有 Herdr 的隐藏 credit／binding／reconnect 用例已通过；新实验全量 **254 通过／0 跳过**，主应用 **361 通过／2 环境跳过**：旧 Ghostty Metal 需要已登录图形显示、私有 effective corner radius getter 不存在。保存的 My Mac／Santty 配置未变。

重启实验版，在 fixture 模式选择应用菜单 **Accessibility fixture**，可人工用 VoiceOver／Accessibility Inspector 检查文本、行／字符、范围高亮、选择和原生历史滚动。真实私有 session 活跃时该菜单被禁用，不注入测试字节。当前仅直接 AppKit 协议调用及自有隐藏窗口回归；**未获得实际 VoiceOver／AX Inspector 人工验收，也未认证完整滚动树、IME 或跨屏设备行为**。不自动开启 VoiceOver、不请求新的 TCC 权限，不驱动用户已有窗口。

### 独立本地 PTY 阶段

菜单 **Start private local PTY** 启动自有 HOME／XDG／tmp 下的 `/bin/sh -i`，**End local PTY session** 关闭并验证清理；与私有 Herdr 互斥，fixture 注入／Herdr reconnect 不可混入。输出在 runner 独立 serial parse worker 直接同步解析 VT 后才释放 ring slot，生命周期另用 private queue，不经 UI 队列；仍使用当前 renderer、输入、clipboard offer、图片／动画、AX 与虚拟 NSScrollView，无第二模拟器。

`NativeLocalPTYLab` 通过可复用的 `NativeLocalPTYSession` 持有 one-launch session；checked FIFO 至多 1 MiB（含 in-flight）／1024 pending chunks，DispatchIO 单写按序完成。过量拒绝，partial error 不重试，退出清未发送字节，不把旧输入路由到新程序。accepted 只是当前 launch 的排队，不代表执行；关闭期间只放行自动协议回复。UI 状态用 revision 和当前 phase 校验，退出后的旧回调不重新启用输入。

第 6 项 `SwiftTerm+LocalPTYHost.patch` 保留原 `terminate()` 语义，另加锁内 TTY slave name／foreground group 查询和通过 owned master 的 TIOCSIG（当前前台组）＋已有 reuse-safe root reaper 关闭。真实无效 cwd 用例先复现上游忽略 chdir、错误地在父目录执行，现 async-signal-safe `_exit(127)`；没有延长 drain 或启动延迟。物理 cwd `/private/var` 与逻辑 `/var` 的测试比较已按文件路径别名处理，生产 metadata 不改写、不 fallback 到 launch cwd。

最初 16 项专项覆盖真实 Ctrl-C/SIGINT、raw UTF-8／Enter／ETX 和窗口回复字节、6000 行宽输出／末尾 marker、tty/pid/group/cwd、cwd 继承、错误启动、输入背压、early／coalesced／force／owner cleanup 与 local PNG／AX 端点。独立 tiny C probe 只创建自有 PTY 验证 Darwin ioctl（不链接或构建终端 core）。foreground force 用 owned lease 是否释放验证，并有专用 FIFO 救援，不向缓存 PID／不明进程发信号。

第 7 项 `SwiftTerm+PTYOutputDrain.patch` 为本实验启用自然退出的**有限输出 fence**：一次性读尽当前已收集／可读的边界，等待解析完成再结束；不等 descendant EOF，不靠延长 0.5s。已复现并修复 held-parser 的 **6／16,409 bytes** 丢失；独立 C 及 owned PTY 回归还纠正 Darwin master 必须用 **TIOCOUTQ**、不能把 slave-input 的 FIONREAD 当可读输出量（3,073／4,097 的错误前提原样保留为回归）。用户显式关闭可无 join 取消，`outputDrainComplete=false` 明示不完整；legacy 的 0.5s 保留，guarded 强制关闭也必须等正在执行的解析回调归还（主线程不 join，清理 deadline 仍为 5s）。

新增 7 项 drain 专项＋主 actor 阻塞时仍解析／回复并完成退出的 native consumer，最初本地专项 **24 项**。第 8 项 `SwiftTerm+PTYLaunchCapture.patch` 再加入 **CLOEXEC 预 exec gate＋parent slave keeper**：准备 I/O／退出监测、持有 slave 后才放行程序；准备失败／取消不 exec，gate EOF 为 127，fd-local SIGPIPE 防护，不改全局信号；per-launch 冻结策略，回调／drain 后 off-main 释放 keeper，旧 public fork 默认不变。真实 delayed-reader `/usr/bin/printf FINAL-TAIL` 原 **0／10** 现 **10／10**；再补已实际写出后延迟 capture、24 次 direct/queued 快速退出、失败／取消／force／gate flags／dead-child EPIPE 和无 DSR 的 native printf，当前本地专项 **34 项**。独立 C **原未保留 slave 的坏向量仍打印 RAW CONTROL**，guarded 对照用相同十字节并故意延迟读取验证，不以原始路径的偶然调度成功冒充修复。没有生产延迟／改字节／重建 core；不承诺 explicit discard／tcflush、escaped／disowned daemon 全树清理、完整 terminfo/login-shell 或 GUI／能耗认证。完整边界见 [LOCAL-PTY-COMPATIBILITY.md](LOCAL-PTY-COMPATIBILITY.md)。本轮实验全量 **288 通过／0 跳过**、主应用 **361 通过／2 环境／系统能力跳过**；AX、动画和新本地 PTY 均不因这些自动测试获得新的人工验收，主应用后端保持旧路径。

### 5A：独立主题数据、typed settings 与 metadata

`Resources/TerminalThemes.json` 离线提取固定旧包的 **485** 个同名主题，保留前景／背景、cursor／cursor-text、selection 与 palette 原色值；runtime 不链接 GhosttyTheme／GhosttyTerminal。它是内部数据工件，**不是新的用户格式，也未实现 Ghostty 主题／配置文件导入**。完整 @Lakr233 与 Mark Badolato／iTerm2-Color-Schemes MIT 许可已打包。

`NativeTerminalSettings` 读取既有键的显式 snapshot，不写偏好；VT 管默认色／palette／cursor 程序优先级，renderer 管 font／selection／caret text／opacity，`NativeTerminalAppearanceHost` 在 NSScrollView 外合并 outer＋2pt inner padding。颜色-only 设置遵守 hold；隐藏可更新 display facts 而不 paint／focus／input。菜单 **Preview next theme (Mocha / 3024 Day)** 仅预览、不注入 fixture／不写生产 defaults。

C title/pwd callbacks 只标 dirty，driver 复制 bounded exact-UTF8 metadata；output 独立 MainActor 通知，不阻塞 parsing/credit。raw cwd URI 不解码成本地路径；RIS／宿主 reset epoch 与重连旧排队通知已测。live status tooltip 显示 metadata；不代替 Herdr record 身份或 Agents 状态。

本轮新增 **22 项**：typed data／偏好 fallback、OSC 与 defaults、font/padding/reflow、hold/hidden、CG/Metal 实际主题／选区／cursor-text／alpha 像素、metadata／锁／reset，以及 private Herdr 超 credit 输出／重连。独立 C 保留 defaults/reset/oversized OSC 实际策略；generator 可 `--check` 做全 catalog 字节复现。详见 [SETTINGS-COMPATIBILITY.md](SETTINGS-COMPATIBILITY.md)。后续全历史 CLI 读屏及 Local owner／launch policy／close barrier 已按下节隔离实现；生产 host 接线仍未完成，不是主后端已自动获准切换。

### 5B：全 retained-history 只读快照

`GhosttyVTDriver.readScreenText()` 在同一把 VT 锁下用独立 formatter 读取整个当前 screen／retained history，plain／unwrap／trim，不借用用户 selection，不取 AX／renderer 缓存；`NativeTerminalReadService` 绑定 pane UUID＋driver，在后台共用生产 `CLITextSnapshot` 的行号／range／tail／search／Unicode／256 KiB response 语义。32 MiB snapshot 超限明确拒绝，不能返回部分历史冒充完整成功，也不减 8 MiB VT history。当前 range/tail 仍先取完整 snapshot。读取不 reveal／paint／focus／输入／复制／tick；hold/hidden 可读最新解析文本，AX 仍是旧 published page。conceal plaintext 与旧 CLI 一致，不冒充 AX 脱敏。

新增 **17 项**，并扩展真实 Local 6000 行与 private Herdr 超 credit consumer；C 独立确认全历史／wrap／conceal／screen／page pruning，保留 configured 10／100 行仍保留旧首行的原失败前提。旧后端独立进程验证 wrap/conceal 对照，未同时链接两套 C core。实验全量 **327 通过／0 跳过**、主应用 **362 通过／1 系统能力跳过**。实现与限额见 [READ-COMPATIBILITY.md](READ-COMPATIBILITY.md)。未新增 socket server、mutation route 或 grant，生产 CLI／backend 尚未切换；后续 Local owner／launch policy／async close 基础已按下节隔离完成，再接 Scroll Mode／host。

### 5B：可复用 Local owner、生产 launch 与关闭屏障

`NativeLocalPTYSession` 持有单次 guarded launch／FIFO／parse worker／finite drain／metadata，不依赖 view、不创建或删除用户目录；`NativeLocalPTYLab` 只保留原 private HOME/XDG/tmp／`/bin/sh -i` 策略与 verified cleanup。生产 local launch 使用账户 shell 的 login argv0＋interactive 参数、账户 HOME／指定 cwd 与用户环境，显式 pane ID／本地 control socket、child-only locale、xterm-256color；不套测试 allowlist、不写全局环境、不自动注入 shell integration。

`NativeLocalPTYCloseBarrier` 不是新 pane registry：先拒绝取消／重复／已过期目标，同步关闭所有目标 input admission，再并发 await 全部 stop，身份仍匹配才同步移除；同 UUID 替换不误删，取消后仍完成已开始的 cleanup。保留 0.5 s／5 s 既有策略、kernel-current PTY signaling／reaper，不操作 Herdr core。新增 **15 项**，包括真实 owned exec 的 argv0／环境、目录非所有权、同 UUID replacement、多 owner、coalesced stop 与取消；实验全量 **342 通过／0 跳过**。完整边界／许可见 [OWNERSHIP-COMPATIBILITY.md](OWNERSHIP-COMPATIBILITY.md)。

**主应用 factories／全层级 close/save/CLI 回复路径未切换，真实 shell/startup/terminfo 认证未完成。** 后续已接下节的 Scroll Mode core ports；后续已接 lab 键盘 ownership/controller／可见 overlay 与初步输入隔离；本地 mode pointer／wheel／autoscroll 已接下节；下一步收敛 host/input-source/drop/menu 与生产 adapter。

### 5B：Scroll Mode 的 VT 物理单元格端口

`GhosttyVTScrollMode` 仅保存 cursor／selection anchor／viewport 的三个 VT tracked refs；`NativeScrollNavigation` 复用现有物理行／word 策略，读取 core 宽度与 grapheme，不借 AX／CLI 文本或另存历史。pruning 丢失 cursor 回最老内容并取消选择，reflow 保留 cursor 内容但取消选择；观察到的 screen 变化与 reset 退出，同一次 vt_write 内的往返遵循 C 实测的“保留有效 primary ref／取消 core 已清掉的 selection”限制。直接安装 VT inclusive selection，不伪造鼠标；复制由既有 VT formatter 负责。

导航／读取不 reveal／paint／focus／input／tick；`scrollModePresentation` 才在一个锁内解析 refs＋capture bounded viewport，避免 host 使用过期行号。单 motion classification 限 16 Ki cells／128 KiB，超限明确拒绝而非部分移动。新增 **18 项**（17 core ports＋1 实际 private Herdr credit consumer），真实 Local 6000 行也经此复制；独立 C 验证 wide／combining／reflow／selection 与 transient-screen 限制。最新全量 **360 通过／0 跳过**，主应用 **362 通过／1 系统能力跳过**。首次全量旧 nvim 鼠标用例 startup-ready 曾超时，3 次原样诊断及后续原样全量通过，未定位根因、未宣称修复。

后续 keyboard UI／input ownership／overlay 已按下节隔离接入；本地 mode pointer／wheel 和完整 host 接线仍未完成。Core 边界见 [SCROLL-MODE-COMPATIBILITY.md](SCROLL-MODE-COMPATIBILITY.md)。主应用后端保持旧路径。

### 5B：Scroll Mode 键盘 UI、输入隔离与 overlay

重启 lab 后，用 app 菜单 **Enter Scroll Mode** 或 **Cmd-Shift-S** 进入；h/j/k/l／箭头、gg/G、0/^/$、w/b/e 与 Shift 大词、Ctrl-U/D/B/F／PageUp/Down、v/V、y／Cmd-C；Escape 先取消选择再退出，q/i/Enter 退出不发给程序。renderer 保持 responder，黄色 hollow cursor／badge／300 ms copy flash 为独立无 hit-test／AX 的 AppKit layer；CG/Metal 共用该层，正常程序 caret 只在呈现中隐藏、不伪造焦点。

owner-scoped input suppression 拦截 text/paste/key/mouse/wheel，自动协议回复与真实 focus 路径保持原职责；preedit 丢弃不提交，Kitty orphan repeat/release 不跨退出重放，旧 reset 的当前键不投给新 epoch。此 keyboard-only 里程碑原先阻止模式内鼠标／滚轮；后续已接下节的本地拖选／wheel/autoscroll。Cmd 链接／程序报告仍被隔离，scroller 直接 seek 尚未接入。 Cmd-V/A 也不绕过模式。主 host/drop/services/输入源与完整 AX announcements 仍待接线。

新增 **23 项**（19 UI／生命周期／raw PTY＋3 actual pixels＋1 equal-total/pruned-anchor 回归）。首次入口几何回归修复“初始 24 rows 与实际 15-row clip 不同导致光标不可见”，保留原无首次 layout 向量；真实 private raw PTY 收到精确 DSR reply、未收到 mode输入或退出后的旧输入。像素为真实 CG／Metal body＋实际 AppKit overlay bitmap，隐藏窗口未提交 CA tree 不冒充 WindowServer 验收。另修复 page pruning 后总行数恰好相同却错误跳到未见 live cursor 的边界，核对 tracked viewport 而非只看 total。实验全量 **383 通过／0 跳过**，主应用 **362 通过／1 系统能力跳过**；未增加等待或改 wire bytes。完整边界见 [SCROLL-MODE-UI-COMPATIBILITY.md](SCROLL-MODE-UI-COMPATIBILITY.md)。尚无新的人工／IME／设备／睡眠／功耗验收，主应用后端未切换。

### 5B：Scroll Mode 本地鼠标、滚轮与拖选自动滚动

复用既有 **VT tracked gesture** 处理单击定位／正反拖选／双击词选／三击行选，Mode 只接纳新鲜的 core endpoints／gesture UUID，不在 Swift 另写选词或复制文本。每次命中由 published reading ref 在同一把 VT 锁内重定位；被裁剪的 origin、旧 epoch、reflow／focus／hold 不续接到替换行。模式中的 Cmd-click 是本地选择而非开链接，程序 mouse／1007／SGR modes 不变、不发 reports。

滚轮为 physical-row 导航：precise fractional row bank、fresh-began／momentum discard、40 rows/event 上限；不冒充平滑 subpixel mode scrolling，不改变普通 NSScrollView 的 fractional path。有效出界拖选才可排一个 weak／token-checked 50 ms wake，最多 10 rows/step；idle／边界／release／hide／sleep／reset／键盘接管取消，无静止轮询。scroller-thumb 直接 seek 仍未接。

新增 **21 项**，扩展 CG/Metal actual pixels 与 private raw PTY selection／DSR/no-replay。独立 C 保留原假设失效向量：pruning 后 oldest 2368→2960，history-2954 实际丢失应拒绝；history-3985 确认仍可重定位为 row 1025。实验 **404 通过／0 跳过**；主应用最新 **361 通过／2 已有环境／系统能力跳过**。首轮主应用旧 remote rename agent metadata 再次超时，原样单项／全量随后通过；未改等待／断言、未宣称修复。完整范围见 [SCROLL-MODE-POINTER-COMPATIBILITY.md](SCROLL-MODE-POINTER-COMPATIBILITY.md)。后续隔离 host/input-source/drop/menu ports 见下节；生产 adapters／主后端仍未切换，也未取得新的设备／GUI／AX／能耗验收。

### 5B：Host 菜单、拖放、安全粘贴与输入源 target

`NativeTerminalHostActions` 接 renderer responder-chain Copy/Paste/Select All／font zoom，复用生产 `TerminalPasteboardText`，不安装全局 monitor、不读／上传文件、不写偏好。输入关闭后仍可选择复制；Mode Cmd-V/A 不绕过 ownership。显式 drop 只可聚焦自身 renderer。新菜单已接 lab，生产 host 接线未切换。

安全粘贴调用原 VT `terminal_paste`，临时 sink 与自动回复分离；Core 决定拒绝、bracket framing 和清理。单次 1 MiB／120 s／escaped preview 的 Cancel/Paste Once sheet，批准前核对 view/output/driver、输入 generation、reset 与 bracketed mode；旧 consent 不跨 rebind/reconnect/新输入/Mode roundtrip，writer 拒绝不重放。保持 legacy CRLF→单 CR 与 bracketed 原字节，真实 private raw PTY 验证确认前仅 DSR reply、确认后精确 legacy／bracket bytes 和有限 drain。

`NativeTerminalInputSourcePort` 复用生产 coordinator/settings，异步 foreground 前后校验 owner／焦点／IME／input lease；lab 不启动系统输入源切换，真实 Local/Herdr foreground providers／palette 仍待生产 adapters 接线。`NativeTerminalNamedKey` 只把现有 CLIKey 转成语义 VT key；不增加 socket、grant 或 mutation route。新增 **34 项**（23 host／10 input-source／1 ICC readback 回归），全量 **438 通过／0 跳过**、main **361 通过／2 已有环境／系统能力跳过**。

首轮 7 项旧 CG 像素失败由独立 AppKit-only 探针定位：缓存的 ICC profile 被 `colorAt` 错读；只改测试取色与错误的 calibrated 参考，原图像向量／断言／容差不变，原 calibrated 与未管理失败值保留。未更改 renderer／shader／core／系统色彩设置，未进行 GUI/TCC 自动操作。范围和未认证项见 [HOST-COMPATIBILITY.md](HOST-COMPATIBILITY.md)。后续 session/frontend／混合关闭端口见下节；主应用 settings／foreground／close-save-CLI 实际调用仍待接线，然后才进入 5C 原子切换。

### 5B：会话所有权、checked frontend 与混合关闭端口

`NativeTerminalPaneSession` 封装现有 Local PTY owner／Herdr state machine，不启动或拥有 shared core；工厂绑定精确 driver/output/UUID，Herdr 要求显式 beforeRun persistence barrier、restore 前 checked writer、remote 排除 local control socket。`NativeTerminalFrontend` 用 token＋controller/session predicate 安装 viewport/focus/settings callbacks；临时 detach／deinit 只解绑自身 view，不关闭进程／断开 Herdr，metadata/output 不抢 first responder。

新增 metrics-only `synchronizeViewport()`，修复 headless 初次绑定被隐藏 paint gate 跳过尺寸：原 child `stty size` 为 `4 40`，正确启动前尺寸应为 `15 80`；真实子进程已验证，无额外 paint／AX／tick／focus／启动延时。保留首次 fixture 中不存在的 `/usr/bin/stty` 与 reset 空页前提，以及后续 shell escaped-quote 存在性检查的错误向量／独立正向控制，不修改原有 remote mouse/reconnect bytes 或 deadlines。

`NativeTerminalCloseBarrier` 对 Local／Herdr finite owners 同步关 admission、并发 await 全部 cleanup、完成后重验精确身份才同步移除；失败／取消保留 layout，同 UUID replacement 不动。Local 两种 intent 都 stop；Herdr 显式 close 才 kill，window/app 与 viewer-only 仅 detach；新 shared `detachViewer()` 等待 pending save/run，使 binding/ambiguity 可供最终保存，不停 daemon、不重连该 viewer。owner read 前后验证 identity，final history 可在保留的布局中读取，Herdr title／typed directory 不以 raw OSC URI 充当本地路径或身份。

新增 **20 项**，扩展原真实双私有 core proxy consumer，完整实验 **458 通过／0 跳过**；主应用 **362 通过／1 已有圆角 getter 能力跳过**，旧 Metal snapshot 此次环境可运行，未删除 skip／改断言。详见 [SESSION-COMPATIBILITY.md](SESSION-COMPATIBILITY.md)。后续主应用 close/save/CLI-final-window 调用已按下节分阶段接线，但旧 Local 仍不具备 native stop/drain；主 controller/host/settings 与依赖原子切换未完成。

### 主应用分阶段关闭、保存与 CLI 回复接线

新增共用 `PaneCloseTransaction`／coalesced close handle，主 GUI pane/replace/tab/workspace 与 CLI close 在 cleanup 后重验具体 controller＋容器成员再同步移除；同 UUID replacement、新 sibling/tab 不被旧操作丢弃。native mixed barrier 也委托同一事务，避免测试一套、生产另一套。Window/app quit 即使无 persistence 也先保存、await 所有 workspace／sidebar 最终 detach、再保存 pending run 的最终 binding；最后窗口等待匹配 CLI reply 已写入才准备关闭，busy fence 不创建新 owner。

主 Herdr 显式 close 才 kill，window/quit/viewer-only 仅 detach；恢复测试证明隐藏 workspace 与 sidebar 原 PID／binding 存活并可复原。新门禁最初过早删除 machine observer，原私有 proxy 测试连续两次在 offline-close 后 reconnect 失败；改为成功关闭／最终 detach 才移除，原超时／输入不变。explicit retry 也重新 fence 已恢复的 backend。

新增 **21 项主测试**（11 transaction／handle＋10 caller/order／实际 private atomic-save），主全量 **383 通过／1 已有能力跳过**；实验仍 **458 通过／0 跳过**。首轮未改动的 raw transport 2M 行压力用例在原 10 秒边界超时（127,172,434 bytes），原样单项和全量复跑通过；未改 transport／producer／deadline、不宣称该观察已定位修复。后续一次全量还遇到原 6000 行 copy 首行断言失败，原样单项／全量随后通过；未改 history budget／burst／断言，不宣称已定位。详见 [CLOSE-COMPATIBILITY.md](CLOSE-COMPATIBILITY.md)。

**生产 backend 仍旧；Local 明确为 `legacyLocalRetirement`，不冒充 native stop/drain/admission 保证。** `TerminalViewRetirement` 和旧 vendor teardown/wake safeguards 保留。下一步是主 terminal/controller/host/settings/foreground/palette／Prompt Editor 与依赖的一批原子替换、随后实际链接与人工验收；此次接线不是 5C 或迁移完成。

### 系统输入对照

详见 [INPUT-COMPATIBILITY.md](INPUT-COMPATIBILITY.md)：固定上游来源、许可证、架构边界、行为差异、自动覆盖与未认证项。新增 herdr-app 26 类按键 × 3 模式的独立固定字节向量，以及全部 31 种 Kitty flags 的重复／释放、模式 push/pop、Num Lock／应用小键盘、Cocoa 修饰键、95 个可打印 ASCII、Unicode、非拉丁／ISO 控制键翻译和 IME 生命周期用例。数据矩阵不通过被测编码器自行生成 expected。测试另发现并修复未括号粘贴 CRLF 变成双 CR 的问题；AppKit Option/AltGr 文本在 report-all 下采用 SwiftTerm 的文本提交策略，避免丢失合成字符和产生孤立 release。

### 人工验收

用户启动实验 app 后，针对提供的测试清单反馈“一切正常，符合预期”：滚动与惯性／弹性、滚动条、新输出跟随及历史阅读位置、Core Graphics / Metal 切换、窗口 resize、Unicode／样式显示与 fixture 重置，当前环境下未报告异常。

后续真实 private shell 人工测试报告光标不可见、Ctrl+C 等控制键无效以及 nvim 无法输入 `:`；分别以像素、私有 shell SIGINT、按键编码和 clean nvim 命令行测试复现并修复，同时修复 overscan 光标定位和传统控制键别名。自动回归已通过，最新 GUI 修复效果仍待用户复验。

这是用户人工体验验收，不是自动化测量；未记录具体输入设备、显示器配置或帧时间。不能据此宣称跨设备一致、性能优于 Ghostty 或已具备真实终端的完整交互。

用户随后自行验证鼠标／滚轮／选择复制与稳定历史锚点两轮，并反馈“正常”；记录为当前环境人工验收，不推断已枚举所有协议／设备组合。本轮新链接／剪贴板功能未包含在该反馈中。用户随后报告 Cmd-click 不开 URL、hover 无下划线；已用上述四项失败回归定位并修复，不能将修复后的自动通过记作新的 GUI 人工验收。

### 尚未实现或验证

- native endpoint 的真实 SSH／跨机器网络与故障验收；本地 exec／PTY 的 shell／terminfo／GUI／完整 drain／子树策略验收；主应用整体迁移。
- 完整键盘布局、Option／修饰键事件、各类 IME 和实体指针设备的人工验收；矩形选择、裸域名／隐式路径、超出捕获帧的长链接、自定义 URL／本地文件、生产 CLI 接线、Scroll Mode 和 AX 人工／完整滚动树／IME 验收；新链接／复制 offer 的 GUI 验收。
- 旧的 nvim 命令行粘贴观察已纳入真实回归，目前三模式粘贴通过；nvim 0.12.5 的 paste+CR 同批输入另有已复现的消费者竞争，保留独立 PTY 诊断脚本，不承诺该快速 burst 组合已修复。
- 图片、其他尚未映射的终端能力、hollow 默认值的主应用设置接入，以及跨后端精确校色／跨设备视觉验收。
- 程序剪贴板读取授权、完整 Kitty clipboard 协议／多 MIME 和异步完成语义；不能用同步 VT 1.0 回调或本轮手动 copy offer 冒充已支持。
- 更广泛的输入／模式变化压力、睡眠唤醒、跨显示器 scale 切换及实际设备上的锚点／滚动手感验收。
- 更多输入设备／显示配置下的滚动体验，以及真实呈现帧率、延迟、多 Pane 和能耗基准。

这些缺口是生产／真实会话集成门槛，不是默认回退为“看起来支持”。当前测试和实现不能用于宣称已完成计划、终端功能对等或性能优于 Ghostty。
