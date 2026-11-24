# 主应用终端迁移接线审计

当前状态：**主程序原子切换已实施，旧依赖移除检查通过**。实际代码、链接证据与剩余验收见 [5C 切换记录](terminal-native-cutover.md)。以下保留切换前审计，不再代表当前依赖或发布批准。

## 历史基线

- 源码基线：`2b18c24`；现有 `graphify-out/graph.json` 先查关系，再以当前源码核实。
- 审计时实验基线为 288 项通过，主应用为 361 项通过／2 项环境／系统能力跳过。
  后续隔离 5A 已补主题数据／typed settings／metadata：最新实验 **310 通过／0 跳过**，
  主应用 **362 通过／1 系统能力跳过**。仍未切换生产后端，不推断人工验收。
- 约束继续见 [总计划](terminal-framework-rendering.md) 与实验目录的
  [PTY](../../docs/terminal/LOCAL-PTY-COMPATIBILITY.md)、
  [输入](../../docs/terminal/INPUT-COMPATIBILITY.md)、
  [图片](../../docs/terminal/IMAGE-COMPATIBILITY.md)、
  [AX](../../docs/terminal/ACCESSIBILITY-COMPATIBILITY.md) 差异表。

## 1. 结论：不是把 TerminalView 换成 NSScrollView 就结束

当前直接旧模块依赖为 **8 个生产文件＋7 个测试文件，16 条 import**。
这不是全部间接受影响文件的数量。四个首要阻塞：

1. **主题仍会把旧核心带回来。** `GhosttyTheme → GhosttyTerminal → GhosttyKit → libghostty`。
   只删 `import GhosttyTerminal`、保留主题 product，仍然没有移除旧核心。
2. **读屏存在三个不同契约。** CLI 要当前 active screen 的 retained history；AX
   只读已发布的有界页面；Scroll Mode 要可跟踪的 grid/cell/selection。
   不能拿 AX 字符串或 renderer overscan 缓存冒充另两者。
3. **Local 关闭现在依赖旧 view 的释放副作用。** GUI 的 `closeHerdrPanes` 与 CLI
   `pane.close` 只显式 await Herdr；Local 由 surface teardown 终止。
   新 PTY 必须在移除 pane／窗口最终退出前显式等待清理，不能等 deinit 的异步兜底。
4. **实验启动器不是生产启动策略。** `NativeLocalPTYLab` 创建私有 HOME/XDG/tmp，
   固定 `/bin/sh -i` 并只继承少数环境；`NativeHerdrLab` 还管理私有 core。
   这些隔离包装不能成为用户普通终端的默认 HOME、shell 或 daemon 生命周期。

## 2. 当前依赖图与替换后的唯一链路

```text
现在
 AppDelegate / TerminalDefaults
   ├─ GhosttyTheme ───────────┐
   └─ GhosttyTerminal ────────┴─ GhosttyKit → 旧 libghostty C core
        ├─ TerminalPaneController → TerminalController + TerminalView
        ├─ HostView / ScrollModeView
        └─ HerdrTerminalSession+Ghostty → InMemoryTerminalSession

目标（全部 Terminal Pane 同一次切换）
 App bootstrap / typed settings / 纯主题数据
   └─ 原有 PaneControlling + 新具体终端宿主
        ├─ NativeTerminalScrollView → SwiftTerm renderer + bounded owned frames
        ├─ NativeTerminalOutput → GhosttyVTDriver → 预编译 GhosttyVt
        └─ 会话所有者
             ├─ Local：独立 SwiftTerm.LocalProcess + 明确生产 launch/close policy
             └─ Herdr：原 HerdrTerminalSession + outputFactory
```

Local／Herdr 是 **transport／会话种类**，不是模拟后端切换。CG／Metal 也是同一个
VT 后端的两种呈现。复用 `PaneControlling`、`TerminalStreamEndpoint`、现有 workspace
与 CLI 路由，不先造一个让旧／新 backend 永久并存的巨型协议。

**编译边界：** `Project.swift` 的主应用 sources 是 `Santty/Sources/**`。
准备期间不能把 import `GhosttyVt` 的全部实验文件直接搬入这个 glob，同时继续链接
旧包。生产可复用代码应先在独立源组／target（仅实验 scheme 使用）完成；切换提交
才一次调整主应用 sources/dependencies。无需重编译 C core、改名 C 符号或做符号隔离。

## 3. 直接生产依赖清单

以下路径均相对仓库根目录；方法名比容易漂移的行号更适合定位。

| 文件 | 当前旧依赖／责任 | 迁移处理与验收 |
|---|---|---|
| `Santty/Sources/App/AppDelegate.swift` | `TerminalController.shared` 启动／偏好观察；旧 debug log；退出仅 await workspace 保存 | 在任何 driver/transport 前 `GhosttyVTSystem.prepare()`；typed settings；退出保存与全部 Local stop 屏障；Herdr 仅 detach viewer。保留更新、菜单、agents 与窗口启动顺序 |
| `Santty/Sources/Terminal/TerminalDefaults.swift` | `TerminalConfiguration`、`TerminalTheme`、`GhosttyThemeCatalog`；字体、透明背景、inner padding、history bytes | 独立主题数据及 typed defaults；不再把配置字符串交给旧 full core。保留主题名称／fallback 与偏好键；新 8 MiB history 不降到 6 MB 以下 |
| `Santty/Sources/Terminal/TerminalLoggingConfiguration.swift` | `TerminalDebugLog`／`TerminalDebugCategory`，环境开关 | 应用自有安全诊断分类或明确淘汰旧分类；不为日志保留旧库。不要把原始终端字节、连接命令或环境值放进 copied diagnostics |
| `Santty/Sources/Herdr/HerdrTerminalSession+Ghostty.swift` | convenience init、`.memory`、`LegacyHerdrOutput` | 用原 state machine 的 `outputFactory` 创建／绑定 `NativeTerminalOutput`；删此旧 adapter 和强制 cast。控制 socket 与 display colors 显式注入 |
| `Santty/Sources/Workspace/Panes/TerminalPaneController.swift` | 构造 view/controller/backend；8 组 surface delegate；读屏、CLI 输入、Prompt Editor、Scroll Mode、pid/cwd、retirement | 保留 pane-facing API，内部改为一个具体 native frontend＋会话所有者；补 metadata、全历史 read、Scroll Mode；显式 async close 后才移除绑定；最后删 surface delegates／retirement |
| `Santty/Sources/Workspace/Views/TerminalPaneHostView.swift` | 持有 `TerminalView`；attachment visibility；copy/paste binding；drop／Cmd-V；overlay、padding、状态／retry | 嵌入 native scroll view，first responder 定位其 input renderer；保留 border/vibrancy/name/status/drag 与 outer padding；禁止 scroll container、renderer、旧 monitor 重复处理同一事件 |
| `Santty/Sources/Workspace/Views/TerminalScrollModeView.swift` | `scrollModeGrid/Viewport`、cell read、scrollToRow、synthetic selection bridge | 重接 VT grid refs 与选择／格式化；不再改 Ghostty config 或伪造鼠标事件。保留键位、模式 badge、光标、linewise/word motion、copy flash；不要把应用 row 数字当稳定历史身份 |
| `Santty/Sources/Workspace/WorkspaceViewController.swift` | 显式旧 import；实际构造／调用大多经 `TerminalPaneController` | 同批移除旧 import；重点是工厂、close/save/restore/sidebar/CLI/focus 的会话接线，而非再包一层旧 surface。保留非终端 pane 与布局行为 |

`TerminalPaneController` 的旧 delegate 责任：open URL、title、resize、scrollbar、pwd、close、
focus、surface attach/detach。当前实验 API 并未提供完整等价的生产事件桥。

## 4. 能力矩阵：已验证基础不等于主应用接线完成

| ID | 能力／现有基础 | 尚缺的生产工作／必须保持的契约 |
|---|---|---|
| M01 | `GhosttyVTSystem.prepare()`、driver 初始 8×16 metrics、PNG once callback | AppDelegate 启动接线；全进程 once，不在解析期间换 callback；去掉旧 shared controller 的隐式 bootstrap |
| M02 | 已有 485 纯主题、typed snapshot、font/padding host、主题 selection/cursor-text/opacity 的 CG/Metal 像素与 hold/hidden/reflow 回归 | 主应用 `TerminalSettings` 通知／Settings UI／生产 host 实际接线仍未切换；并非整个 Ghostty config parser |
| M03 | `GhosttyVTDriver.presentation`、tracked history anchor、fractional NSScrollView；metrics-only 同步在初次 exec/attach 前确定隐藏 pane 真实 grid | Host 的 outer padding（默认 8）与旧 core inner padding（2）统一几何；不能双计；选区、IME、链接、AX、resize 都用同一 cell origin／scale |
| M04 | driver key/paste/focus/mouse encoder；IME／checked writer；已隔离接 named CLIKey、responder menu/zoom、shared URL/drop、VT safe-paste review、现有输入源 coordinator target | 主应用 responder/settings/foreground/palette 接线、真实 TIS/IME／drop/sheet／Prompt Editor 验收；不得把 paste→Enter consumer race 当 transport bug 加延时 |
| M05 | 已接 VT core ports＋keyboard UI／输入隔离／overlay／actual pixels，以及复用 VT gesture 的本地拖选／row-wheel／有限 autoscroll；raw PTY/DSR/no-replay | scroller direct seek、主应用 responder/input-source/drop/menu 接线、AX mode announcements 与实际设备/GUI 验收仍缺，不算完整生产 Scroll Mode |
| M06 | 锁内 full active-screen VT formatter、pane-bound async read/search、生产 CLITextSnapshot；session/frontend adapter 在 await 前后验证精确 owner，32 MiB snapshot refusal 与 256 KiB response 分离 | 主 pane/CLI router 尚未切换；保留 await 后 pane/endpoint 身份与无重试约束；CLI logical lines／AX published physical page／Scroll Mode grid 是三个独立契约，不靠 viewport、selection、tick 或 reveal 来读屏 |
| M07 | VT callback-dirty → 锁内 owned title/raw-pwd → MainActor 通知；16 KiB cap／exact UTF-8／reset；新增 Herdr record-title 优先与 typed Local/Herdr directory adapter | 主 pane 的 title/cwd 来源优先级及 local cwd policy 仍需接线；Herdr record 保持身份权威，raw URI 不做本地 FS 解释 |
| M08 | 已拆出 NativeLocalPTYSession；immutable pane-bound launch、账户 login/interactive shell／真实 HOME／child-only locale 与用户环境、本地 socket／ID；private lab 只管隔离文件；15 项新回归 | 生产 factory/host 接线、真实 shell／terminfo／startup 验收与 shell-integration parity 未完成；不把 private allowlist 带到生产，不把本地 socket 带到 remote |
| M09 | `NativeLocalPTYInfo` 同时有 group ID 与验证过的 leader PID | `inputSourceForeground`／CLI 的 `foregroundProcessGroupID` 用 group ID；cwd 查询用验证过的 process 信息；不把 shell PID、group ID、leader PID 互换，缺 leader 时不伪造 fallback |
| M10 | 原 Herdr state machine／parse-completion credit；新 session factory restore 前 checked writer、required beforeRun、永久 endpoint readiness；原双 private-core remote consumer 已经新工厂验证 | 工厂替换 `.memory`；绑定 writer 在 restore 前；`surfaceReady` 改为 frontend readiness，不能把临时 NSView detach 等同 viewer disconnect；display facts 更新与 focus reports 不重复 |
| M11 | viewport hide/occlusion/minimize/app-hide/sleep gates，隐藏解析仍进行 | 主区域、后台 tabs、其他 workspace、sidebar、floating／临时容器迁移的 attachment/focus；布局动画只改呈现，不重复 resize／发 focus/input；可见性恢复不重放 |
| M12 | native AX 只读页、links 安全重验、clipboard offer 单次审批 | 接入主应用 responder/menu/notice；明确 HTTP/HTTPS/mailto whitelist 的行为差异；AX 不代替 CLI／Scroll Mode，不允许 AX setter 输入／滚动；clipboard 审批不伪造旧异步协议完成 |
| M13 | 共用 PaneCloseTransaction 已接主 GUI pane/replace/tab/workspace、CLI close、window/app final detach＋前后 save／reply fence，native mixed barrier 用同一事务；exact controller/container、await 全部、失败／取消保留，machine observer 成功关闭后才移除 | 主 Local 仍显式 legacyLocalRetirement，不具备 native stop/drain/admission；5C 必须用 Native owner 替换并删除旧 view retirement／core。真实 save-error sheet／app quit／多 pane 人工验收仍缺，不能只以 shared engine 通过认证旧 Local |

### 4.1 主题与设置不能只“替换 import”

证据：`Vendor/libghostty-spm/Package.swift` 把 `GhosttyTheme` target 直接依赖
`GhosttyTerminal`，后者依赖 `GhosttyKit`。`GhosttyThemeDefinition` 与生成的 catalog/color
数据本身是纯值；`GhosttyThemeDefinition+TerminalConfiguration.swift` 才做旧配置转换。

下一实现片段应冻结／提取纯数据或独立资源，保留 `GhosttyTheme/LICENSE` 的
Mark Badolato / iTerm2-Color-Schemes MIT 归属及上游包代码许可，去掉旧配置转换依赖。
不能为默认一个主题删掉整个 picker，也不能为了保留 picker 留下旧 C core。

主应用偏好键继续为 `terminal.themeName/fontFamily/fontSize/padding`，默认
Catppuccin Mocha／Menlo／13／8，字号 8…32、padding 0…24。旧 config default 是 block＋blink，
旧 `TerminalDefaults` history 为 6,000,000 bytes；native 现为 8 MiB。
新的 typed snapshot 要同时喂 VT 默认／palette、renderer font/selection/caret/opacity、
geometry 与 Herdr display facts。主题／字体变更不能 RIS、换进程、丢 reading anchor 或打断输入。

旧运行时还封装了环境 locale、TERM/terminfo、shell integration 和默认 keybindings。
`GhosttyRuntimeResources.swift` 的包内资源不能随旧 product 消失而被无声遗忘；先确定需要
保留／有意改变的用户契约，不通过复制旧整套配置解析器继续加载旧 core。
源码中存在旧 pin 的历史注释（如 process-info stub）；审计没有操作用户 pane 去验证它们，
不能凭这些注释断言当前运行值。迁移依据新独立 PTY 已区分的字段及实际测试。

### 4.2 CLI／Scroll Mode 的读取边界

旧 `Patches/TerminalSurface+ReadText.swift` 在 active screen 的 screen selection 范围调用
`ghostty_surface_read_text`；`CLITextSnapshot` 再裁行／search／限回包。native 需要用 VT
formatter/read APIs 提供同一功能，不复制第二套 scrollback；soft-wrap/trim/conceal 等具体
文本语义必须有独立向量，不把“看起来相似的 AX 文本”当旧接口的等价实现。

AX 当前上限是 1 MiB UTF-8／256K cells，且只对应已发布 presentation window；这不是
CLI 的 256 KiB response limit，也不是全历史查询范围。输出被 hold 或隐藏时，CLI 如何
取一致读屏应保持现有只读契约并单独测试，不能借 read 强行提交半帧到 renderer。

Scroll Mode 不应继续通过 `mouse-reporting=false/link-url=false` 之类配置重建来隔离输入。
用宿主明确 mode gate 与 VT-owned selection；现有 mouse selection/reading anchor 是基础，
不是完整 keyboard Scroll Mode。保留 `TerminalScrollModeKeyAction` 的 h/j/k/l、gg/G、word、
page/half-page、v/V、y、Esc 行为，Unicode/pruning/reflow/wide-cell 的定位要稳定或显式失效。

### 4.3 Local 与 Herdr 的 close／ready 必须分清

- `closeHerdrPanes` 和 `performCLIPaneRequest` 目前显式 await 的只有 Herdr，Local
  随旧 controller/view 释放。新 Local 必须复用正常的 async stop/reap，而不是依赖 lab
  deinit 兜底；`applicationShouldTerminate` 目前只 await 保存，也必须加会话结束屏障。
- Window/app close：Local 结束，Herdr detach，保留绑定。显式 pane/tab/workspace close：
  普通 Herdr 先 kill 原绑定再移除；external viewer 只 detach。保存失败和关闭失败分别报告。
- CLI close 仍受 router grant/journal 管理；await 后检查 `tab.paneControllers[id] === pane`，
  不误移除替换对象；最终窗口回复顺序与非焦点 responder 保护照旧。
- `HerdrTerminalSession.surfaceAttached()` 实际是 connect 的 readiness gate；native driver
  ready 与 NSView attached/visible 不是一个条件。后台留存 pane 继续解析／credit，不能每次
  换 workspace 都 detach/reconnect 或重置身份。只在真正释放 viewer 时断开它。
- `NativeHerdrLab.stop()` 会停其**自有私有 core**，绝不可迁入生产窗口 close 路径。
  新工厂继续使用现有 HerdrCoreClient、永久 core ID／binding、santty-pane label、pending-run
  保存、viewerOnly、remote routing 和 shared-document merge；renderer 不接管这些协议。

## 5. 间接接线与保留项

| 文件／区域 | 处理 |
|---|---|
| `TerminalSettings.swift`、`Settings/TerminalSettingsPane.swift`、`SettingsView.swift`、`FontPanelTarget.swift` | 保留偏好存储与 UI；改消费端而非迁移用户键；theme picker 的数据来源需脱钩 |
| `Workspace/Panes/TerminalPasteboardText.swift` | 已是应用自有纯 AppKit helper，不是 vendor 类型；保留 URL-first、shell escaping 与 private-pasteboard 回归，重接 native paste intent；不因此恢复程序 clipboard read |
| `Terminal/TerminalLinkValidation.swift` | 已共用。旧 pane 允许本地 file/custom handler（部分确认），native whitelist 更窄；必须明确产品差异，不绕过新 fresh-link 验证悄悄恢复旧 opener |
| `CLI/CLICommandRouter.swift`、`CLITextSnapshot.swift`、`CLIControlServer.swift`、`Shared/CLIPaneCommand.swift` | 保留 read-only 与两个 default-off mutation grants、10 分钟 launch-scoped IDs／pending coalescing、冲突／过期拒绝。只有终端读取／输入／关闭端口改接 |
| `PaneInputSourceCoordinator.swift`、`SystemInputSources.swift`、`TerminalProcessInspector.swift` | input target 必须是 native input renderer；composition/first-responder gating 不变；remote 不做本地进程／路径查询，不用 PID/屏幕猜 agent 状态 |
| `WorkspaceViewController` 的 make/start/close、save/restore、agent navigation、sidebar/shared-layout/CLI extensions | 保留 workspace/pane UUID、v10、Herdr binding/runPending/viewer、本地恢复 placeholder；后台创建不得抢焦点；所有布局位置走同一个 frontend，不按 pane 保留旧后端 |
| `AppAppearanceDefaults`、host decorations、tiling/floating/drag/FLIP | 保留全局 dark appearance、corner/vibrancy/padding/border；新 surface 的 clip/hit/focus 与动画一致。旧 display-link/wake patch 不是新 renderer 已验收的证明 |

## 6. 测试移植清单（不能以删除／放宽／批量 skip 代替）

直接 import 旧模块的七个文件：

| 文件 | 保留的断言，替换观察点 |
|---|---|
| `TerminalPaneInteractionTests.swift` | command-click/链接、attached/occluded/hidden output、Prompt Editor、keyboard Scroll Mode 跨历史 Unicode、tiled/floating/padding focus、事件顺序；不再窥探旧 surface coordinator |
| `CLITests.swift` | 全 retained history 的 read/search/range 编号、Unicode／空行／限额、viewport/selection/pasteboard/focus 不变；旧 Ghostty graphics skip 不得变成新读屏功能的永久 skip |
| `CLIPaneTests.swift` | grant、journal、跨 workspace/sidebar UUID、输入／IME／Scroll Mode refusal、无 responder/clipboard 改变、close-await 身份检查／最终窗口顺序 |
| `HerdrWorkspaceTests.swift` | core/remote identity、重连不重放、6000 宽行 history copy、float/restore/close、pending run 与 remote 路径规则 |
| `HerdrWorkspaceSyncTests.swift` | 原 merge/conflict/revision/删除不杀程序，以及 renderer 换代后的真实 pane/viewer 接入 |
| `AgentSessionTests.swift` | exact root/child identity、baseline/done/read ack、消息 popover anchor／不抢焦点、外部 viewer detach 不 kill |
| `SanttyTests.swift` | typed theme/font/padding/透明度／fallback、启动／窗口／debug log；不要再以 rendered Ghostty config 字符串作为唯一 oracle |

间接回归还包括 `WorkspaceViewControllerTests.swift`、`InputSourceTests.swift`、layout/drag、
workspace store/schema/lock 与 Settings 测试。实验的 288 项保留固定字节、独立 expected
vectors、真实 CG/Metal readback、private Herdr/PTY 对照；重归属测试 target 时不改坏向量。

## 7. 实施顺序与删库门槛

### 5A — 隔离基础已完成：typed settings＋独立主题数据＋metadata

实现与差异见 [SETTINGS-COMPATIBILITY.md](../../docs/terminal/SETTINGS-COMPATIBILITY.md)。
485 主题用严格离线提取保存原名称／RGB，JSON 与完整许可已打包；不 import 旧 theme product，
不加载完整 Ghostty 配置文件。21 项 settings/metadata/rendering 专项＋1 个实际 private Herdr
consumer，实验全量 310 通过。Main App 偏好 UI、生产 pane 接线和人工验收未由此完成。

已在隔离 native 源组／scheme 完成以下基础：

- 纯主题 catalog/许可、typed settings snapshot（含 palette/selection/cursor 与透明度/geometry），
  测主题 fallback、字体 family/size、OSC palette/DECSCUSR 优先级、Herdr facts 与 hidden reflow。
- VT title/pwd owned metadata；测试分片 OSC、Unicode、reset、hidden 更新、无主线程同步／无输入，
  对 remote cwd 不作 local URL/filesystem 解释。
- 不先把旧配置对象转成大字符串交给新核心，不先在主应用加入两套 C 依赖。

后续 **5B 的全历史读屏及可复用 Local 会话所有权／launch policy／close barrier 已隔离实现**；
实际生产接线仍未完成，随后接 keyboard Scroll Mode／host 输入。保持主应用依赖切换为 5C 的同一批次，不把实验通过或审计 Python 通过算作主应用已迁移。

### 5B — 生产会话所有权与读取／交互端口

从 private lab 包装中提取 guarded LocalPTY 会话、保留隔离包装用于测试，补生产 launch
policy；完成全历史 read、keyboard Scroll Mode、CLI keys/paste、输入源 target、host drop/menu
与异步 close 契约。单一 native frontend 接 Local／Herdr，不做 old/new backend adapter 分流。

全历史 read/search 基础已完成：driver 独立 formatter 锁内读取整个当前 screen 的 retained
history；pane-bound service 在后台共用既有 CLITextSnapshot，不读取 AX／overscan，不改选区／
viewport／focus／clipboard／hold／动画。新增 17 项，实验全量 327 通过／0 跳过，主应用 362
通过／1 系统能力跳过。独立 C 保留 100 行未按 10 行精确裁剪的原向量并确认 page pruning；
旧后端独立进程对照确认 soft-wrap 与 conceal plaintext 语义，不改 core。32 MiB capture 超限
明确拒绝，不以 256 KiB response clipping 偷换全历史；详见
[READ-COMPATIBILITY.md](../../docs/terminal/READ-COMPATIBILITY.md)。

后续已拆出 `NativeLocalPTYSession`，private lab 仅负责私有 HOME/XDG/tmp；productionLocal
明确账户 shell 的 login argv0／interactive 参数、真实 HOME／cwd／用户环境、child-only locale、
xterm-256color 与本地 socket／pane ID，不修改全局 env、不自动注入 shell integration。
Local close barrier 在 first await 前关 admission，并发 await 所有 close 后再校验 controller／
session；同 UUID 替换、取消、重复／旧目标不误删。新增 15 项，实验全量 342 通过／0 跳过。
详见 [OWNERSHIP-COMPATIBILITY.md](../../docs/terminal/OWNERSHIP-COMPATIBILITY.md)。
**实际主应用全层级 close/save/CLI 回复接线与完整 shell/terminfo 验收仍未完成。**

后续 Scroll Mode 的 VT physical-cell/navigation/selection ports 已隔离实现：三个 tracked refs，
直接 VT selection／formatter、bounded motion classification、atomic presentation；不取 AX／CLI
文本、不合成鼠标或停解析。18 项新回归后实验全量 360 通过／0 跳过，主应用 362 通过／1
系统能力跳过；首次全量旧 nvim startup-ready 超时未复现，不宣称已修复。完整限制见
[SCROLL-MODE-COMPATIBILITY.md](../../docs/terminal/SCROLL-MODE-COMPATIBILITY.md)。

后续 lab keyboard owner／controller、可见 cursor/badge/copy flash、文本／IME／paste／Kitty
生命周期隔离、owner-scoped input gate 与 actual offscreen CG/Metal pixels 已接入。新增 23 项，
实验全量 383 通过／0 跳过，主应用 362 通过／1 系统能力跳过；实际 private raw PTY 验证精确
DSR reply 与无 mode input／退出重放。入口先同步真实 grid，再按分数 live-bottom 使用真实输入
cursor，修复初始 24 rows／15-row clip 不符；equal-total page-pruning 回归再核对 resolved
viewport 防止跳到未见 tail。无生产延时或 bytes 改动。
详见 [SCROLL-MODE-UI-COMPATIBILITY.md](../../docs/terminal/SCROLL-MODE-UI-COMPATIBILITY.md)。

后续本地 mode pointer／drag／wheel/autoscroll 已接：复用现有 VT tracked gesture、不写第二选词
引擎，命中在锁内按 published ref 重定位，origin 真丢失则拒绝。wheel fractional-row bank／
fresh-began gate／40-row cap，drag 唯一 weak 50 ms wake／10-row step，hide/sleep/reflow/epoch
取消。新增 21 项，实验全量 404 通过／0 跳过；main 最新 361 通过／2 已有环境／系统能力跳过。
首轮 main 旧 remote rename agent metadata 超时与历史记录相同，原样诊断／全量随后通过，
未改等待／断言、不宣称修复。独立 C 保留 lost-origin 坏前提和实际保留 ref 的正向量。
见 [SCROLL-MODE-POINTER-COMPATIBILITY.md](../../docs/terminal/SCROLL-MODE-POINTER-COMPATIBILITY.md)。

后续隔离 host ports 已接：renderer responder-chain menus/zoom、shared URL/drop、VT
state-aware paste＋single-use epoch-bound review、CLIKey semantic mapping，以及复用生产
input-source coordinator 的 owner/focus/IME/await target。真实 private raw PTY 验证准确
legacy／bracketed bytes 和 finite drain。新增 34 项，实验全量 **438 通过／0 跳过**，main
**361 通过／2 已有环境／系统能力跳过**；lab 不启动真实系统输入源切换。首轮 7 项旧 CG
像素失败以独立 AppKit-only probe 证明 ICC readback／calibrated 参考前提错误；修测试
profile-aware 取色和独立 sRGB swatch，保留原向量／断言／容差和 calibrated 控制，不改
renderer／core／shader／显示配置。另保留 foreign-driver output 的失败回归，两个端口在
writer/foreground 之前拒绝此错配。详见
[HOST-COMPATIBILITY.md](../../docs/terminal/HOST-COMPATIBILITY.md)。

后续 session/frontend owner ports 已隔离完成：精确 driver/output/UUID 工厂、Local once-only
launch、Herdr required beforeRun／restore 前 checked writer／remote socket 排除；view detach
不变成 viewer disconnect，callback/token 防止旧 frontend 清除新输出；read 在 await 前后
重验 caller 的 controller/session。mixed close barrier 保持 Local stop／Herdr kill-or-detach，
封闭 admission 后独立 await 全部、失败/取消/同 UUID replacement 不移除；新 shared
`detachViewer` 等 pending save/run，不停 daemon。metrics-only 首次同步修复 hidden headless
子进程 `4 40` 而非 `15 80` 的真实初始尺寸错误，不放开 painting gate。新增 20 项，原双
private-core remote consumer 已用新 factory，实验 **458 通过／0 跳过**；main **362 通过／
1 已有系统能力跳过**（旧 Metal 条件本次环境可运行，未改 skip）。详见
[SESSION-COMPATIBILITY.md](../../docs/terminal/SESSION-COMPATIBILITY.md)。

后续主 close/save/reply 调用已分阶段接线：共用 backend-independent transaction 与
coalesced handles，GUI pane/replace/tab/workspace／CLI close cleanup 后重验具体 controller
及容器成员再移除；window/app 即使无 persistence 也 pre-save、final detach、post-save，
匹配 CLI reply 写入之前不关最后窗口。native mixed barrier 同样委托该事务。新增 21 项主
测试，真实 private-core hidden workspace/sidebar 保持 PID/binding 并正常复原；main
**383 通过／1 已有能力跳过**，lab **458 通过／0 跳过**。复现两次并修复过早移除 machine
observer 导致 failed remote close 后无法 reconnect；另一次未改 raw transport 10 秒压力
超时原样单项/全量复跑通过，未改 deadline/producer，不宣称已定位。详见
[CLOSE-COMPATIBILITY.md](../../docs/terminal/CLOSE-COMPATIBILITY.md)。

**下一实现片段：主 terminal/controller/host/settings/foreground/palette／Prompt Editor
及依赖的一次性原子替换**；scroller 直接 seek 与设备／GUI／AX 认证继续保留。生产 backend
仍旧，Local 明确 legacyLocalRetirement，不能把这批主调用接线当成 native Local stop/drain
已经投入生产。保留旧 teardown/wake safeguards，直到 5C 删除旧 core 的同一批次。

### 5C — 一次性主应用切换与清理

同一切换批次覆盖所有主区域／后台 tabs／workspace／sidebar／floating pane：

1. App bootstrap、TerminalPaneController/Host/ScrollMode、factory、lifecycle/save/CLI 接新端口。
2. 主应用和主测试 target 换为 SwiftTerm＋预编译 GhosttyVt；去掉 `GhosttyTerminal`、
   `GhosttyTheme` product 与 `Vendor/libghostty-spm` package。纯主题资源不得有回边。
3. 删 `HerdrTerminalSession+Ghostty.swift`、旧 view retirement、旧 surface 类型／debug hooks；
   `TerminalDefaults`／logging 按新语义保留或替换，不因名字相同保留旧实现。
4. 删 `Scripts/prepare-ghostty.sh`、mise 的 ghostty prepare 依赖与仅旧包需要的七个 patch／bridge
   文件（与 prepare 脚本合计八个待删工件，见审计工具的 `RETIRE_FILES`）；保留全部八个 `SwiftTerm+…` patch、新 VT 准备和 attribution。
5. 只有确认无其他依赖者后才去掉旧 DisplayLink/资源／锁文件缓存记录；不删除公共 SPM cache。
   更新根 README 的旧核心／配置资源说明与架构文档；生成工程仍不提交。

切换后检查普通生成／Debug tests／Release 包的**实际解析依赖与链接产物**，不能只看
import 扫描。只链接一套终端 C core；rollback 用 Git／旧构建，不提供运行时旧 surface fallback。

### 5D — 验收（仍未获批准）

所有 CLI/Herdr/Local 生命周期回归、多窗格/跨窗口 responder、实际 IME、VoiceOver／AX server
滚动树、动画、跨屏 scale、真实滚轮与 sleep/wake、长时间资源／能耗都仍有独立门槛。
AX 只读／bounded page 的范围不扩大；不自动触发 TCC 或操作用户会话，不推断人工已验收。
既有 PNG／pointer 的用户反馈只保留其原有范围。冻结 SDK 的零 source-crop、同 ID 非原子
替换、clipboard 同步拒绝／手动审批、静态 PNG／非 APNG 等差异仍以兼容表为准，必须有明确
接受／限制策略；不能用旧 C core 兜底或把 renderer 切换当成协议功能补齐。

## 8. 可复现的只读清单检查

```sh
python3 -B Scripts/audit-terminal-dependencies.py --check
python3 -B Scripts/audit-terminal-dependencies.py --check --json
python3 -B -m unittest discover -s Scripts/Tests -p 'test_terminal_dependency_audit.py' -v

# 仅在整体切换／删旧依赖后应通过；当前必然失败，不是本轮验证失败。
python3 -B Scripts/audit-terminal-dependencies.py --require-removed
```

工具检查列出的 production/shared/tests/lab Swift import、Project/mise 的显式旧引用与待删
工件；不会生成工程、下载 vendor、读环境、启停进程／core 或访问 clipboard。新增旧 import
（包括泄入 lab）、遗漏清单变动会报错，不能用 `--check` 输出推导迁移已完成。

这是**词法漂移检查**，不是 Swift parser、transitive package resolver 或二进制审计：条件
import 也计入，注释／多行字符串中的 import-like 行需人工核实；有意改名／隐藏依赖也不能
靠此工具排除。主题传递边通过准备好的 vendor Package.swift 人工核对，工具不强制下载旧包。
`--require-removed` 是静态必要条件，不代替 5C 的普通 scheme 构建／解析图／产物检查。
