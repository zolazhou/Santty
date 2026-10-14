# ClientShell 实施记录

日期：2026-10-11。完整实现目标仍在进行，当前尚未切换用户窗口到 ClientShell。

## 当前代码

- `HerdrClientShellProtocol.swift`：generation-1 协商模型、长度前缀与 bincode decoder/encoder；包含文字、surface/patch、图片 assets/placements/retained、响应 chunks、语义输入和必要副作用消息。长度、UTF-8、集合、几何、图片数据和尾部 bytes 在解码边界校验。
- `HerdrClientShellState.swift`：typed snapshot、boot/revision 隔离、future surface 暂存、匹配 snapshot/surface 才呈现、patch 先校验后提交；图片只传一次时仍保留资产。
- `HerdrClientShellTransport.swift`：现有 Unix socket / peer 验证、独立读写 worker、部分读取、有限读写队列、顺序输入、bounded detach，不启动 Herdr 或 shell。
- `HerdrClientShellSession.swift`：inactive 建连、welcome 协商、resize/激活/focus 顺序、activation ACK 和 presentation fence、命令串行与分块响应、health check、未知结果不重放。导航 ACK 之后继续等待目标 snapshot/surface 才开放输入。
- `HerdrClientShellRenderer.swift`：从 tab 的 inner_rect 提取每个 pane 的内容，popup 使用独立 frame；保留颜色/样式/宽字符/链接/光标，按变更行输出 ANSI。Kitty RGB/RGBA/PNG 内联分块上传、局部 placement、替换/删除、retained 再显示和 reset 重放已实现；缺失新资产时保留旧 placement，编码失败不推进 renderer 状态。
- 图片缓存预算现在同时计入解压后的像素成本；PNG 在上传前核对 IHDR 与元数据尺寸，避免只按压缩 bytes 估算内存。
- `HerdrLayout.Node.projected(on:)`：只读拓扑与 surface pane ID 核对，以当前几何校准原生比例；支持缺失 split handles、嵌套分屏、gap 与 zoom，拒绝重叠/换序分支、未知或重复 split path。尚未接入窗口投影。
- ClientShell transport 获取 Unix peer 的 PID 和进程启动时间，session 暴露并在断连时清除 `serviceIdentity`；后续 API runtime 查询可据此核对同一服务实例。
- `TerminalPaneController` 增加显式 ClientShell transport：不创建 relay、不启动 direct bridge，由窗口 session 绑定 boot/服务身份并渲染匹配 revision；关闭显示端不 detach 窗口 endpoint。提示编辑器走语义 Paste + Enter。本地 exec 和默认 direct 分支继续保留；此构造入口尚未接入窗口默认路径。
- 修正语义键码编码：上游 `ClientKeyCode` 的 Char/F/Null 分别为 15/16/17，旧 Swift 与人工 tuple fixture 同时使用了错误的 17/18/19。fixture 生成器现在使用与 pinned 源码一致的 Rust enum 序列化，并覆盖全部 18 个 variants，避免两端共享错误数字仍然通过测试。
- 显示反馈已接入：`HerdrShellDisplayFeedback` 有界解析分片 Kitty replies，忽略成功 ACK 与普通 VT 回复；当前 renderer 所属 image 的错误写入 `clientShellDisplayError` 和 pane tooltip。断连清理回调、partial bytes 和错误，重建时 image ID 单调递增，隔离迟到的旧回复。没有向后端 PTY 回灌显示端数据；窗口 diagnostics 面板映射待接。
- ClientShell pane 按真实 Ghostty cell pixels / backing scale 固定终端 view 尺寸，由外层原生容器裁剪/留白；清除 C core padding，输出前核对 grid 与 backend inner_rect 一致。原生容器 resize 不 reflow 后端内容。窗口级尺寸上报与跨 pane 统一 metrics 尚未接入。
- `HerdrClientShellInput.swift` 与 `AppTerminalView+SemanticInput.patch`：在 Ghostty Swift 层编码 VT 前截取按键和 text commit，复用原有键盘布局翻译、preedit 与 NSTextInputClient；保留原生菜单，关闭旧 in-memory 硬件键 VT 旁路。映射特殊键、F1–F20、修饰键、repeat/release 和 Option 文本，IME commit 不同时发原始 key。pane 只释放自己已接受的 press，并在非 interactive 状态清理记录与 preedit。
- 原生 paste 菜单、URL 粘贴及拖放接入语义 Paste；普通本地/direct pane 的 hooks 为 nil，沿用原行为。真实输入法和窗口输入生命周期仍需随完整窗口接线验收。
- Swift-only mouse hook 与 pane 鼠标路由已加入：基于实际 inner grid 与 backing scale 编码 cell/pixel 坐标、geometry、按钮及修饰键；接受的拖动/释放越界时 clamp，新的越界按下拒绝。Shift 保留本地选区；mouse reporting 关闭时选区仍由 Ghostty 管理，wheel 走后端历史/程序语义路径，触控板保留有界 fractional lines。
- session 有界追踪已发送的 key/button press；endpoint 命令、resize 和失焦之前先把 release 发回原 pane/popup。导航测试核对原目标的 release frame 在 focus request 之前出现，避免 pane 本地状态清理后后端仍认为按键或按钮按住。窗口实际 focus/resize 回调尚未调用该能力。
- CLI 调用方审计确认只有 list/read/search，没有输入命令；实现计划已改为保留查询兼容，不增加新的 CLI 写入能力。
- 新增强制原生呈现确认：session 按 boot/projection/surface serial 提供画面，只有 host 调用 `acknowledgePresentation` 确认匹配的原生提交才开放新输入。旧 host ACK 不会打开新帧；相同 serial 不反复触发投影。布局/焦点变更时冻结并释放持有输入；普通内容等待呈现时保留 press 记录，仅允许其真实 release，避免 content refresh 造成 stuck key。基础测试用显式虚拟呈现器 ACK，没有运行时绕过门控的开关。WorkspaceViewController 仍待接入这个接口。
- `HerdrWorkspaceClient.routeCommands(to:)` 已加入公共调用入口：绑定之后，除 ping/snapshot/layout.export/history/process/agent.list 等明确只读查询，其余操作走 ClientShell negotiated methods。命令不再执行 binary preflight、开启 API socket 或启动 shell；断线、未知方法和替换 session 不回退全局 API。client 的命令绑定固定到该 session 的 boot 和 peer identity，后续更换会话/离开模式需要新的 WorkspaceClient，不能改写旧对象并转发其等待中的调用。
- API 与 endpoint 命令结果复用 `Result.assignServiceIdentity`，保留 pane/root_pane/layout/read/process/agent/snapshot 归属校验所需的服务身份。当前窗口仍使用旧入口；新路由通过隔离测试启用，窗口持有及投影主线尚未接完。
- `Scripts/herdr-clientshell-fixture.py`：只创建临时 client socket 的隔离 endpoint。测试不连接用户服务，不写真实 pane。
- `Scripts/herdr-clientshell-golden.rs` 与 `Tests/Fixtures/`：用独立 serde/bincode 2.0.1 standard 序列化器生成 golden payloads；Rust 仅用于测试数据生成，不是 Santty 运行时或构建依赖。snapshot fixture 源于 pinned Herdr generation-1 fixture。

## 已执行的验证

FlowDeck 保存目标 Santty / Debug / My Mac，测试 derived data `/tmp/santty-herdr-stage0-derived`。

1. 初始 protocol 5/5 通过，15.27 秒。
2. 初始 state 6/6 通过，11.92 秒。
3. 新 transport/session app build 通过。
4. 初始隔离 session 2/2 通过，13.56 秒。
5. 增加导航 ACK 先到、目标画面延迟到达的回归后，protocol/state/session 一起 **14/14 通过，9.99 秒**，无 skip、无失败。
6. 渲染首轮 6/6 通过，13.03 秒。
7. 加入 popup 与真实 Ghostty RGB/RGBA/PNG 存储测试后，renderer/state 共 13/13 通过，9.02 秒。原生测试显示 `A界B`，并通过对生成的 image ID 再 placement 获得 `OK`，证明三个格式已到达 Ghostty 图片存储；这不是最终图片截图验收。
8. 新增压缩图按解压成本超预算、提交前拒绝的专门测试，1/1 通过，6.64 秒。当前累计 22 个不同 ClientShell 测试已通过。
9. 新增 surface/layout 投影测试，1/1 通过，12.81 秒；覆盖无 handles、乱序 handles、gap、zoom、身份失配与错误拓扑。累计 23 个不同 ClientShell 测试通过。
10. 加入 peer PID 与断连清理断言后，隔离 session 回归 3/3 通过，11.87 秒；`git diff --check` 通过。
11. 修正 fixture 和键码后，protocol 6/6 通过，10.26 秒；新增原生 pane 接线测试 1/1 通过，13.23 秒，确认图文路径的文字可见、无 direct bridge、语义 prompt 可提交，以及 pane 关闭不 detach 窗口 session。当前 25 个不同 ClientShell 测试通过；这仍不是图片截图或完整窗口验收。
12. ClientShell session 全部 4 项与旧 direct 混合布局 1 项一起回归，5/5 通过，7.27 秒；`git diff --check` 通过。
13. 显示反馈解析、单调 image ID、renderer 与原生 pane 回归共 10/10 通过，13.21 秒；新增一个不同测试，累计 26 项 ClientShell 测试通过。
14. 原生 pane 固定 grid / 容器 resize 测试 1/1 通过，13.11 秒；真实 Ghostty 图片存储及 ENOENT reply 解析测试 1/1 通过，7.01 秒；`git diff --check` 通过。这证明实际 grid 与反馈通路，不替代图片截图及完整窗口验收。
15. 新 Swift-only patch 首次构建遇到旧 Ghostty 公共模块缓存；FlowDeck 仅 clean 本任务 `/tmp/santty-herdr-stage0-derived` 后重试，protocol（含新 AppKit key 测试）、真实 Ghostty IME hook 与原生 pane 共 9/9 通过，24.32 秒。native API 测试验证中文 marked text / commit 与 Enter 不重复，不等于真实输入法会话验收。累计 27 项不同 ClientShell 测试通过。
16. 输入 patch 之后旧 direct 混合布局回归 1/1 通过，7.13 秒；重复 `mise run ghostty:prepare` 成功，patch 幂等；`git diff --check` 通过。
17. 加入 mouse geometry 与 held key/button 导航释放后，protocol/session 共 12/12 通过，15.06 秒；累计 28 项不同 ClientShell 测试通过。
18. 原生 mouse hook、越界 drag/up 与 Shift 选区精确 wire 断言，加旧 direct 混合布局回归共 2/2 通过，11.79 秒；重复 prepare 与 `git diff --check` 通过。触控板实际滚动、真实 mouse reporting 程序仍待窗口集成验收。
19. 新增 native presentation ACK / pending content release 专门回归，session 5/5 通过，16.90 秒；移除运行时门控绕过开关、改用测试中的虚拟呈现器后 5/5 通过，13.21 秒。累计 29 个不同 ClientShell 测试通过。原生 pane 测试先完成真实渲染，再确认呈现并开放输入。
20. 最终虚拟呈现器回调改用弱引用，session 5/5 通过，8.84 秒；`git diff --check` 通过。
21. 公共命令入口路由、session 与旧 direct 混合布局回归共 7/7 通过，16.21 秒；新增一个测试，累计 30 项不同 ClientShell 测试通过。fixture 没有创建 API socket，pane.rename 仍成功并出现在 endpoint trace，断线后不会触碰其他 transport。
22. 增加重复绑定幂等、拒绝替换 session 的断言，并将 boot/进程身份冻结在首次绑定；专门回归 1/1 通过，12.23 秒；`git diff --check` 通过。

执行命令：

```sh
rtk proxy flowdeck test \
  --only SanttyTests/HerdrClientShellProtocolTests \
  --only SanttyTests/HerdrClientShellStateTests \
  --only SanttyTests/HerdrClientShellSessionTests \
  --derived-data-path /tmp/santty-herdr-stage0-derived --progress
```

这些测试证明基础协议、隔离会话、pane 渲染及图片解析行为，不证明完整窗口、实际图片截图、IME、多客户端尺寸或性能已经完成。

## 下一步与尚未完成

- CS1/CS2 仍需补充队列超限/大帧部分写、重连与 UI 生命周期接线的完整验收；目前是基础实现，不将整个阶段记为已交付。
- CS3：文字/图片提取、Ghostty 编码及 TerminalPaneController 会话入口已落地；仍需接入 WorkspaceViewController 和统一 tab 尺寸。
  源码新证据：`server/client_shell.rs` 会按 hit area 过滤 `splits`，其集合不是完整布局树，且 endpoint methods 没有 `layout.export`。窗口接线需保留 JSON API 的只读拓扑查询，用同实例身份及 surface 几何核对后投影；focus/mutation 继续迁移至 endpoint。
- CS4：提示编辑器、AppKit 按键/IME/mouse hooks、菜单/URL/拖放粘贴、held-input 释放及 Ghostty 显示端反馈已接线；窗口 focus/navigation/resize 生命周期调用、真实输入法和鼠标程序验收仍待完成。CLI 只有查询，其服务身份/历史兼容需在窗口接线后验收。pane 图片错误已可见，窗口 diagnostics 面板待接。
- CS5：基础上传、placement、替换/删除、缺失资产和 popup 已落地；仍需窗口级缓存/显示生命周期接线，以及实际裁剪/滚动/隐藏、图片截图和 surface 重建验收。
- CS6：固定逻辑 viewport 的基础容器已落地；本地辅助树、浮动/隐藏/自动放大的完整生命周期、v3 持久化、显式迁移与旧 direct/Observe 保留待接。
- CS7：surface reuse/delta/scroll、性能测量、多客户端和真实图片集成验收、README/diagnostics 更新。

现有 direct 控制路径与用户正在运行的 app 尚未被切换。未修改、重启或升级 Herdr 服务。

## 后续窗口接线：代码变更，尚未验证

用户要求暂不验证后，本轮只修改源码与回归断言，没有执行 build/test 或连接真实服务。

- ClientShell 的 Disconnect/ reconnect 菜单改为窗口级操作。断开清除全部相关 pane 的 session、显示反馈和输入状态，并丢弃尚未发送的导航/分隔调整；后端服务不关闭。
- Reconnect 不经过“必须已呈现”的普通 mutation gate，重新执行窗口激活与一致呈现流程；命令面板在焦点位于本地辅助 pane 时也保留窗口断开/重连入口。
- Leave/关闭取消重连任务；连接尝试以 generation 防止迟到失败覆盖已退出或更新的窗口状态。析构时释放窗口 session。
- 扩展原生窗口测试的断开状态、不可输入、重连菜单仍可用和外部服务保留断言；这些新增断言未运行。fixture 当前仅接受一次 ClientShell 连接，真正重连接线还需多连接 fixture 和隔离测试。

这不是完整 CS6 交付：Observe/Takeover 菜单的新 transport 路由、服务重启后的身份迁移、popup、v3 和默认入口等仍待完成；完整剩余顺序见 [迁移计划第 11 节](herdr-clientshell-migration.md#113-恢复实现后的优先顺序)。

### v3 保存与恢复接线（未运行验证）

- `SavedWorkspace.currentVersion` 升为 3，窗口显式保存 transport；v1/v2 缺省保持 direct。校验拒绝旧格式携带新 transport，以及 ClientShell/Observe 的矛盾组合。
- 恢复传输模式贯穿 pane controller 构造、窗口重新进入和 offline 状态。ClientShell pane 不先启动 direct bridge；服务身份确认前不开放订阅驱动的完整窗口刷新。
- 第二实例无保存锁时使用 direct Observe，不激活 ClientShell，不写回更改。Leave 仍恢复本地 tabs；CSPane、Notes/Browser、停放 tabs 与辅助布局沿用已有保存结构。
- 添加 v1/v2 到 v3 保存断言、ClientShell JSON 往返和非法组合断言，更新 README；这些断言和恢复接线没有编译或运行。默认入口尚未改为 ClientShell，真实恢复、离线恢复与窗口级重连仍待后续验收。

### 设置变化后的场景重绘（未运行验证）

- 复核 vendor：`TerminalController+Config` 常规设置更新是对原 C surface 调用 update config；AppKit 临时移出/移回窗口也保留已有 surface。不能把所有设置或浮动操作称为 C surface 重建。
- 新增 session 的 presentation invalidation：释放已接受输入、暂时关闭输入、保留一致 snapshot/surface 和 CPU 图片 cache，重新向窗口提供同一场景，等待新的 native ACK。
- 设置变更先作废 presentation，再重置各 ClientShell renderer 的文字/图片上传基线；窗口重新计算统一 viewport、排队 resize 并提交当前场景。不每帧重复上传图片。
- 投影 renderer 首次或 reset 后进入 alternate screen；稳态帧不重复切 buffer，Herdr 保留历史所有权。新增 alternate-buffer 输出与 cache/ACK 门控断言，未运行。
- 真正 C surface 被重建时的自动通知与补传、多 pane 字体/cell 校准、Ghostty alternate-buffer 下图片及 resize 的运行行为仍待完成/验收，不能把本次设置入口接线等同于全部 surface 生命周期支持。

### 实际 surface 生命周期接线（未运行验证）

- 使用 vendor 已有 `TerminalSurfaceLifecycleDelegate`，没有新增 patch 或修改 C 核心。真正 detach/attach 会重置 renderer、使 boot presentation 绑定失效，并请求 session 重新提交缓存场景。
- 输入额外检查 C surface 已挂载且 TerminalView 在窗口中；隐藏/已拆除的显示端不能因另一 pane 的 ACK 而重新接受输入。普通 view 移出/移回窗口仍保留 C surface，不重复触发重建。
- 原生窗口测试加入移除/恢复同一 controller 的实际 rebuild 路径，并断言待重绘期间不能输入、无新服务端图片时文字恢复；新增断言未运行，Kitty 新 surface 图片存储、多 pane 与隐藏/浮动恢复仍待验收。

### API 拓扑候选与 ClientShell 一致性门控（未运行验证）

- 新增拓扑候选核对：同 boot/revision 的 scene、当前 workspace 的有序 tabs、pane 集合与 tab 归属、每 tab 的树，以及 active-tab surface 几何均匹配后才提交。
- 查询完成后复核窗口 session 当前 snapshot/surface，迟到查询不能覆盖更新的 projection。切 workspace 不再提前改写窗口 workspace ID。
- API snapshot 与随后 layout 查询之间的 pane 集合变化在 ClientShell 下返回待同步，使用既有有界投影重试；无效结构或服务身份不匹配仍明确报错。候选不一致不会清除当前布局/浮动展示或覆盖拓扑 cache。
- 纯状态回归新增 API ahead 的 tab/pane、错误 tab 归属、错误树、旧 boot/不匹配 revision，并确认 API 全局选中状态不是 endpoint 的 authority；未运行。
- 这一步保护异步查询的提交边界，不等于所有原生 views/GPU surface 已原子呈现。拓扑已匹配后新 controller 的就绪过程、API 查询途中 tab 被删除的错误分类及多 pane 运行行为仍待完成/验收。

### 窗口 Observe 与重连模式（未运行验证）

- 整窗口 Observe 操作统一进入 direct Observe；不再调用 ClientShell pane 的旧接口而静默无效。原生面板在本地 Notes/Browser 有焦点时仍可操作窗口 Observe/重连。
- 整窗口重连保持当前 mode/transport；direct 模式只重连已有且已启动的 controllers，不重复启动本次新建 controllers，未启动的后台 pane 仍按原懒启动规则工作。
- Controller 复用同时检查 mode，避免由 Control 转为 Observe 时复用仍可写的旧 controller。该转换保留本地辅助内容，但后端 controller ID 及浮动/隐藏呈现状态跨 transport 转换的保留仍需补齐。
- presentation readiness 同时检查当前交互状态、导航/fence、requested geometry；旧尺寸的 ACK 不再允许窗口 mutation/输入。扩展 Observe 重连与 resize 门控断言，未运行。
- Take Over 的完整窗口语义、默认 Control 入口、popup 和自动重连仍待完成。Observe 的旧通道图片限制保持明确，不把 inactive ClientShell 当作只读图片模式。

### Controller 替换时保留本地呈现（未运行验证）

- 模式/transport 更换仍创建独立 controller 和原生 UUID，避免旧 controller 析构时误注销新 controller 的 Agent 注册。
- 仅完整 `HerdrPaneBinding` 相同（endpoint、服务进程、workspace/tab/pane、runtime terminal 均相同）才迁移呈现状态；不同运行时不继承旧状态。
- WorkspaceTabState 映射浮动/隐藏 pane、尺寸、自动缩放配置、焦点及焦点历史；本地辅助 UUID 保持不变。Controller 同时保留本地自定义名称。
- 添加纯状态映射断言，以及 direct Observe → Control → Observe 的浮动/隐藏保留回归；未运行。ClientShell ↔ direct 的真实生命周期与固定逻辑 viewport 仍待验证，不把同一映射机制视为已经通过集成验收。

### 可重连的隔离服务 fixture（未运行验证）

- window fixture 保留同一进程和 API listener，持续接受 ClientShell 连接；Detach/EOF 只结束该连接，不移除服务的 client socket。
- 每条连接独立重置激活与图片投递缓存；重新激活会补传资产，surface serial 保持服务级递增，ACK 使用当前 projection revision。其他场景继续只接收一次连接。
- Trace 原子替换，并加入连接序号；回归读取不再可能看到写到一半的 JSON。清理覆盖临时 trace。
- 原生窗口回归加入 Disconnect → Reconnect → Leave：要求两次连接/激活、同一服务身份和 native controller、文字恢复、输入开放以及独立服务保持存活。新增流程没有运行，不证明实际图片或重连已经通过。

### Popup 输入目标隔离（未运行验证）

- 按 surface 的 popup 身份统一核对输入目标：有 popup 时禁止普通 pane 输入；popup 输入只匹配当前 terminal ID。Session 与普通 TerminalPaneController 使用同一规则。
- 增加同字符串 ID 仍保持 pane/popup 命名空间隔离、错误 popup ID 拒绝及 popup wire tag 14 的断言；未运行。
- 现有 renderer 已能提取 popup 独立 frame/图片坐标，但原生 overlay、焦点恢复、popup mouse/IME/paste、尺寸和生命周期仍需接线。窗口 `popup presentation is not connected yet` 分支保留，因此没有宣称 popup UI 已支持。

### 原生 popup controller 与 overlay 接线（未运行验证）

- 新增 `HerdrClientShellPopupController`，以真实 boot/terminal ID 绑定窗口 session；仅使用 in-memory Ghostty backend，不构造普通 pane binding，不创建 PTY，也不注册 Agent 或持久化 pane。
- 使用现有 viewport renderer 与键/鼠标坐标编码器，接入 press/repeat/release、IME、语义 Paste、mouse reporting/Shift 本地选区、wheel/pixel mouse 和 Kitty 错误反馈。Popup 鼠标的事件路由暂沿用普通 pane 的同一实现，后续回归通过后再评估是否需要合并。
- WorkspaceRootView 新增独立透明 overlay，不替代本地 floating overlay；按 backend 区域和权威 popup grid 居中。窗口 ACK 包含 popup render 完成条件，移除原来的直接报错分支。
- 常规内容更新保留 popup first responder，避免每帧切回底层 terminal 破坏 IME；关闭 popup 时恢复 pane 焦点，本地辅助内容有焦点时不强制抢走焦点。设置、surface 重建与断开/Leave 接入生命周期。
- Fixture 增加 `window-popup`，包含 popup 文字和独立蓝色图片资产；新增原生显示、输入 tag 14、底层 pane 禁止输入、关闭后焦点恢复及不持久化 popup 的回归流程。
- 未编译、未运行上述流程，也未连接真实 Herdr。新 Swift 文件由 Project.swift 的源文件 glob 覆盖，但后续 build 前需要重新生成 workspace。实际 popup 图像存储/裁剪、鼠标/IME/menu paste、多 pane/tab 与本地焦点组合仍需验收。

### 用户入口与显式窗口控制（未运行验证）

- Enter Herdr Mode 的 Connect 按钮选择 ClientShell Control，Read Only 选择 direct Observe，新增明确的 Legacy Control。已有恢复和 reconnect 继续传入记录的 transport；内部旧测试/调用的默认 direct 参数保留。
- 重新进入的只读 workspace 查询不经过“必须已呈现”的 mutation gate，使 offline ClientShell 窗口仍可选择已有服务。窗口 mutation 默认仍严格要求一致呈现，不增加自动 fallback。
- 窗口 Take Control 重新进入 ClientShell，并发 endpoint `pane.focus` 请求取得当前 tab 几何控制权；源码依据为 `client_views.rs::shell_endpoint_claims_geometry` 与 `claim_shell_tab_geometry`。单 pane Take Over 仍沿用旧 direct 接口。
- Observe 下允许用户显式 Take Control；重连结束处理尚未发出的焦点/分隔调整。新增 fixture 的第三次连接与 endpoint focus 断言，未运行，多客户端 ownership 行为仍待验收。
- README 更新入口、v3 保留语义、fixed grid、旧通道图片限制及未验证状态。实现代码没有部署到用户运行的 app，也没有连接、启动或更改真实 Herdr。

### 有界自动重连与故障分类（未运行验证）

- 保存 POSIX connect 错误码，原 CLI 可见错误文本保持不变；ClientShell 的流关闭、读写失败、health timeout 使用明确的连接中断类型。Peer/协议/预算/身份错误不归入可重试网络错误。
- 只有已经完成原生呈现的 session 才触发自动恢复。恢复继续核对原服务身份，有限等待当前操作结束，再按 1/2/4 秒退避；pending 请求返回未知结果，输入和命令均不重放。
- 快速反复断连共用最多三次恢复预算，连接保持 30 秒后才重置，防止每次短暂成功都重新获得无限重试。手动进入/重连重置预算；未知或永久错误立即停止。
- Disconnect/Leave、恢复另一份工作区及关闭窗口取消恢复；自动重连期间保留 Disconnect/Leave 入口。恢复失败保留现有本地内容与错误状态。
- Fixture `window-drop` 仅切断第一次 ClientShell stream，服务和两个 socket 持续保留；加入同 PID/native controller 自动恢复回归，以及 malformed packet 不可重试断言。尚未编译或运行，反复断连预算、取消、服务重启拒绝及有副作用操作期间断线仍待完整验收。

### ClientShell 诊断与有界耗时统计（未运行验证）

- 诊断增加 window/pane transport、generation/codecs、服务支持能力与实际请求的优化开关、boot/projection/surface/pending revision、requested/actual grid、cell pixels、presentation/fence/navigation、pending requests、资产数量/编码字节、popup ID 和恢复次数。
- Socket worker 在锁内记录当前读/写积压及峰值，区分读 payload 与写完整 frame 字节；不导出消息、像素或原始输入。
- 按 monotonic uptime 记录请求发送到完整响应、scene offer 到 native host commit 的最近 128 个样本，导出样本数、last/p50/p95。Host commit 表示 C 输出解析完成，不代表 GPU 可见帧；指标范围为当前连接。
- Fail 前捕获诊断快照，释放连接/图片 cache 后仍能查询 revision、队列和耗时；标记 capturedAtFailure，presentationReady 始终为 false。手动 disconnect/start 清除旧快照。
- 图片/预算/同步错误只导出分类；codec/capability 使用已知名称白名单，不导出未知字符串。Pane/popup 显示错误纳入诊断。
- 添加有界分位数、非法 duration、ClientShell 原生窗口诊断/正文排除及失败快照断言，并修正 popup wire tag 断言应跳过四字节帧头。未编译或运行。
- 完整导航的 ACK → matching scene → host commit 分段、请求端到端总耗时、队列/资产真实峰值及持续输出性能仍待完成/测量；不能用新增字段宣称 Herdr 切换延迟已定位或修复。

### Host color scheme 同步（未运行验证）

- 窗口按 native view effective appearance 同步浅色/深色，与 AppKit Ghostty view 的宿主 appearance 来源一致；首次连接、设置更新与系统 effective appearance 回调均接入。
- Session 保存激活前的 host scheme，按 resize → activation → focus → scheme 的同连接顺序发送基线；相同值去重，断连保留宿主偏好但重置已发送标记，下一连接重新发送。
- Diagnostics 增加 hostDark；fixture 记录 tag 17 与 payload，新增基线顺序、dark/light 编码和去重断言。未编译或运行。
- 此项仅覆盖 ColorScheme 更新，宿主 RGB foreground/background 查询响应、clipboard/bell/notification 等 presentation effects 的窗口路由仍待完成，不把 ColorScheme 同步称为全部 host theme/effects 支持。

### 原生 presentation effects 与剪贴板写入策略（未运行验证）

- 窗口 session 对当前同 boot/projection、等待 native commit 的 effect 使用有界队列（128 条、4 MiB），ACK 后投递一次；切换、非交互状态和断开清理，不跨连接重放。Diagnostic 增加 deferredEffects 数量。
- 窗口 effect 路由核对有效 session/generation。Bell 只对当前远端键盘焦点提示并限频；通知核对目标和已有 Agent 偏好，避免重复完成通知。标题、sound reload 与宿主模式仍使用原生策略，不能称为全部上游行为已实现。
- Clipboard 经 bounded base64 OSC 52 进入 Ghostty，不将远端文本作为裸控制序列拼接；入口要求当前交互目标有键盘焦点。补充 effect 等待 native ACK、仅投递一次和 OSC 52 控制序列隔离的断言，未运行。
- 静态复核发现原 vendor 写入回调忽略 `confirm` 并直接操作 pasteboard。新增 `TerminalClipboardWrite+Policy.patch`，在回调内复制借用字符串、异步进入 MainActor，再按确认标记显示 macOS Allow/Cancel；确认在 C callback 返回后打开，取消不写入。
- 增加 host delegate gate 与带锁的 callback epoch。Delegate 更换、surface teardown、ClientShell 非交互状态及 pane 断开使已排队的 callback 失效；确认后再次核对 epoch/surface/focus。普通 pane 与 popup 仅允许对应 terminal first responder；本地/direct 的既有复制行为保留。UIKit 不提供该 macOS 确认界面，要求确认的写入拒绝，Santty 不使用 UIKit。
- Patch 接入 prepare 脚本，按已有 semantic input patch 之后应用；未运行 prepare，也未改 C binary。新增真实 Ghostty 的 host-policy 拒绝用例，用拒绝 delegate 避免打开系统确认或写剪贴板；该用例未编译/运行。
- 仅做静态 whitespace 检查。尚需证明 C mailbox 延迟回调、快速切换/断开、确认期间关闭窗口和原生 Copy 的交互行为；epoch 只保护已进入 Swift 回调并排队的操作，不将它宣称为所有 C mailbox 事件的连接 generation 证明。完整图片/输入/多客户端交付仍未完成。

### Host foreground/background 与显式 palette 同步（未运行验证）

- 常规客户端将宿主 OSC 10/11/4 查询回复转换为 `ClientShellHostTheme::{DefaultColor,PaletteColors}`；源码为 `client/shell/input.rs::host_theme_update` 和 `protocol/wire.rs`，不通过普通 pane input 发送。
- 新增 RGB 和 palette 的 generation-1 编码；RGB 分量及 palette index 使用原始 u8，只有 variant 与集合长度使用 bincode varint。Hex 输入限定六位 ASCII RGB，支持可选 #，拒绝短色、alpha、符号与非十六进制字符。
- Session 保存激活前的颜色，在 resize → activation → focus 之后发送；颜色与 palette 去重，仅变化项重发。Disconnect 清除已发送基线，保留宿主配置，使新连接重新发送。
- TerminalDefaults 复用同一个 catalog definition 为 Ghostty theme 与窗口 host colors 提供配置源；开始连接、设置和 effective appearance 更新均同步 foreground/background/显式 palette，并保留原有 dark/light 更新。
- 添加高 RGB/index 字节、256 项向量长度、非法 hex，以及基线顺序/去重/只改背景的断言；Rust golden generator 加入相应声明，未运行 generator，未改已有历史 golden bytes 的来源标记。
- 此项只发送明确的 catalog 配置，不声称涵盖 Ghostty 隐式 256 色 palette 或程序运行时色彩覆盖。常规客户端查询全部 256 色，下一步应通过显示端查询/回复路由读取真实 Ghostty 值；不得臆造未配置颜色，也不得把其 VT 回复送给后端程序。
- 未编译、未运行测试或真实连接；只做静态 whitespace 检查。完整 host-theme parity 和图片/多客户端交付仍未完成。

### 实际 Ghostty host color 查询与完整 palette（未运行验证）

- 复用显示端 feedback，新增 OSC 10/11/4 解析及 DSR 边界。查询用两条 CSI 5n 包围 default colors 与 0...255 的逐项 palette 查询；仅收齐两个默认色和全部 256 索引、并收到末尾回复后发布结果，不猜测未配置颜色。
- Parser 保留原 Kitty 错误处理，支持分片、BEL/ST、rgb 分量 1...4 位和 # RGB，按照上游比例/舍入转换到 u8。保留缓冲上限 8 KiB、有限 failure batch 和最多一个 color query；其回复不进入 pane input。
- 同一 feedback 上查询串行；取消保留旧回复边界直到排空，旧 query ID 不读新结果。等待有界，缺失/超时只报告 host query 错误，不发布混合或部分主题；取消/重建另行核对窗口 generation、session、boot、pane epoch 与挂载状态。
- 普通 ClientShell pane 提供异步查询入口。窗口在 scene native ACK 后从实际挂载的 backend surface 查询，同一 pane/设置 epoch 不逐帧重发；设置、appearance、断开、重新连接和 surface 重建使查询失效或重新读取。目标切换期间等待旧任务结束后再查询新目标。队列 drain 放后台，避免新增主线程同步等待。
- 明确 catalog 配置作为初始基线，真实 surface 的完整查询结果随后覆盖；移除“仅显式 catalog colors”的 shortcut 注释。不把这一行为称为服务端启动前已获得完整颜色，也不宣称 GPU/OSC 时序已验证。
- 新增分片/完整 256 色、缺失默认色、旧 ID、取消后排空、非法 RGB/index、oversized reply 与 Kitty 反馈共存断言；现有真实 Ghostty 渲染回归加入实际颜色查询与配置值核对。
- 未编译、未运行这些测试，没有连接真实 Herdr。DSR/OSC 回复顺序、快速设置更新/重建、真实默认 256 色与窗口发送仍需运行验收；runtime terminal identity 解耦、原生投影完整提交和整体迁移的其他未完成项继续保留。

### ClientShell 公开 pane 身份与可选 runtime 查询映射（未运行验证）

- API Pane 的 runtime terminal ID 改为可选解码。HerdrPaneBinding 为 ClientShell 只保存 endpoint、服务进程身份及 workspace/tab/pane；runtime ID 为 nil，不使用 pane ID 或空字符串替代。Direct 构造继续要求有效真实 runtime ID。
- 窗口布局验证不再把缺少 runtime ID 当成 ClientShell 的终止条件；服务身份、公开 IDs、pane 集合与 topology witness 的核对保留。Controller 复用核对公开归属与同服务身份；查询映射增减不重建 ClientShell renderer。
- 普通 controller 单独维护 `herdrQueryBinding`。匹配当前服务/公开 pane 的 API metadata 可生成 strict runtime binding；查询数据缺失或身份不匹配只清除映射和旧进程结果，不终止 ClientShell pane。管理快照更新映射，不覆盖 ClientShell 的选中状态/几何。
- 历史、CLI read/search、process 与 Agent 使用查询绑定；history/process 入口拒绝无 runtime 映射。异步结果复核 controller/generation/查询绑定，旧历史任务在映射改变时取消并提示重新打开。CLI list/diagnostics 的 runtime ID 为可选，不导出虚构值。
- v3 的 ClientShell 保存允许无 runtime ID，但仍要求服务身份；direct 和旧格式保持 runtime 要求。辅助归档的递归校验传递 ClientShell 身份上下文。恢复重新取得公开匹配 metadata；恢复为 Observe 时从当前 API 构造真实 direct binding，不用缺失 ID attach。
- 补充公开绑定/strict 查询区别、缺少/错误服务身份、失去查询映射仍 live 的断言；新增 `window-no-runtime` fixture 与原生窗口呈现、输入、v3 保存、direct 拒绝、CLI 查询失败隔离的流程。既有 direct Agent/Observe 测试调用方改为显式解包真实 runtime ID。
- README 说明查询不可用不应中断终端。未编译、未运行上述流程或真实连接，仅静态 whitespace 检查；Optional Codable 与旧保存/CLI/Agent 行为仍需完整验收。
- 此项解除 runtime ID 的硬依赖，但初始窗口仍依赖 API snapshot/layout.export 的拓扑与服务校准。API 查询整体不可用时还不能单凭 endpoint metadata 完成 bootstrap；下一步继续收口 snapshot 权威性及原生结构准备/提交，不把此改动宣称为全部 API 与呈现依赖已移除。

### 后端 tab 切换与本地焦点范围（未运行验证）

- 修正 ClientShell 画面提交的 keepLocalFocus：只在当前原生 tab 已等于权威 backend tab 时保留其 Notes/Browser/辅助终端焦点。切换到另一 backend tab 时按匹配 snapshot/surface 显示目标 tab，旧辅助内容仍归属原 tab，不把后台内容删除或移到新 tab。
- 拓扑候选提交使用 shell witness 的 focused_tab_id 选择 tab，不用 API 的 active tab 覆盖它；保留本地焦点也必须属于该目标。旧 direct Observe 的本地选择规则保留。
- Native ACK 不能因待挂载的可见 pane 被跳过而成功；仅主动隐藏且未正在展示的后端 pane 允许省略本地呈现。正在显示的 detached pane、普通目标 pane 未挂载时继续等待。
- Renderer 完成后还必须由 session 接受当前 surface 的 ACK；尺寸/revision 门控拒绝时继续等待匹配场景，不把“已经喂给 C parser”当成完成提交。投影重试耗尽后明确报告 synchronize 错误并关闭输入/连接，不静默丢掉待提交场景。被新候选 supersede 的帧继续顺序处理状态和资产，没有将其当成失败或输入 ACK。
- Window fixture 新增两个 tabs、各自 pane/runtime ID、按 tab 的 API layout、endpoint pane.focus 切换，以及第二个 tab 的 popup 和独立图片；切 tab 时重新发送相应资产，不引用从未投递的另一 pane 图片。
- 新增原生回归：Browser 保持同 tab 焦点，切到另一个 tab 时显示并聚焦 popup、底层输入关闭，关闭 popup 后恢复目标 pane，再切回原 tab 保留 Browser 名称/内容归属。未构建、未运行该流程或真实服务连接，仅静态 whitespace 检查。
- 此项修正选择与 ACK 的边界，不证明新 controller/view 的整批准备已完全原子化，也不证明跨 GPU surfaces 同帧提交；完整 staging、API bootstrap、surface 优化与整体验收仍待完成。

### 导航同步分段耗时（未运行验证）

- ClientShell navigation 按 monotonic 时间记录 request issue → 完整成功响应、响应 → 匹配选中目标的 coherent scene、匹配场景 → session 接受 native ACK，以及完整 issue → accepted commit。使用已有每连接最近 128 样本的 last/p50/p95 统计。
- 只有响应、projection revision 与目标选中证据均匹配才开始 host commit 阶段；只有被接受的 ACK 才计入 total，重复 ACK 不重复统计。新导航在旧目标呈现前发送时标为 superseded，没有虚构旧目标已经呈现的 total 样本。
- Diagnostics 增加四段 latency、awaiting host commit 和 superseded 数量。各阶段可能样本数量不同，失败或未呈现导航不会计为完成；断开清除当前连接样本，已有 failure snapshot 保留释放前数据。
- 指标起点是向 socket worker 排队，不是最后一个 socket byte 写完；因此第一段包含本地写队列、网络/服务端处理及响应组装，不把它全归因于 Herdr。Host commit 是 C parser 完成和逻辑 ACK，不是 GPU 可见帧，也不含用户点击到 root 请求入队前的等待。
- 新增隔离 navigation fixture 流程，分别断言 ACK 后/匹配 scene 后/手动 native commit 后的样本数量、总耗时等于分段和、重复 ACK 去重。未编译或运行该流程，仅静态 whitespace 检查；没有真实 p50/p95 测量，不能据此宣称切换延迟已定位或修复。

### Optional surface 编码的基线调查与 decoded queue 预算（未运行验证）

- pinned `protocol/surface_reuse.rs` 确认 reuse control 是 `endpoint.surface-reuse.v1`，JSON 携带 base_surface_revision 与完整 surface metadata，仅省略主 frame.cells；必须同 boot、同尺寸、连续 surface revision。Projection revision 可变化，popup 内容和图片 scene 不能一并假定为不变。
- 上游 Decoder 在连接读入阶段、activation/presentation 过滤之前更新 full/patch 的 cell baseline。无匹配基线的 reuse 是协议错误；delta/scroll 另需协商。Santty 的 UI pending frame 合并不能替代这一层。
- 现有读队列只计算 wire payload bytes。新增结构化消息的保守估算，计入 cell storage/symbol、hyperlinks、popup、patch rows、pane/split metadata、asset pixels/keys/placements/retained keys，以及 control/response 字符串和数据。
- 保留线上读写各 64 MiB 预算，另加解码后待消费消息 256 MiB 预算；Packet 同时携带两种 credit，consume 一次归还，超预算永久失败而非无限重连。Diagnostics 导出 queuedDecodedBytes/peakDecodedBytes。
- 估算对每张队列中的场景计算 cells/assets，即使其 COW storage 共享也保守计费。当前正在解析的一张消息、未来 decoder baseline、session cache、Ghostty/GPU 内存不属于待消费队列；不把此字段称为整个进程的硬 RSS 上限。
- 新增图片场景估算高于 wire size、最大合法 grid 仍可独立进入队列、字符串 UTF-8 成本及原生诊断预算的断言，未编译或运行，仅静态 whitespace 检查。
- reuse/delta/scroll 请求仍为 false。下一步实现 bounded serde JSON surface 类型、worker-owned full/patch/reuse baseline 恢复，并将上述计费放在恢复之后，再完成 delta/scroll 与 fixtures。尚未实现或启用 reuse，不把本次预算修正称为协议优化已经交付。

### Connection-local surface reuse 恢复（未运行验证）

- 新增 `HerdrClientShellSurfaceDecoder` 并接入 socket read worker，位于结构化消息预算和 AsyncStream 投递之前；不依赖 @MainActor 的当前 snapshot、activation 过滤或 UI 合帧。
- Baseline 仅保留 boot/projection/surface revision、主 frame 尺寸与 cells，不额外持有旧 graphics 资产。Full surface 更新基线；匹配的连续 patch 先验证所有 row 范围，再应用 cells；不匹配 patch 清除基线，后续 reuse 拒绝恢复。
- reuse 必须在 hello 请求和 welcome capability 双方同意后才接受；恢复要求相同 boot、base surface、连续新 serial、相同主 grid、主 cells 为空。新 surface 的 metadata、cursor、hyperlinks、popup 和 graphics 独立解码并验证，不拿旧 scene 覆盖它们。
- serde JSON 类型兼容上游 externally tagged Terminal/PaneLayer、Pane/Popup、Rgb/Rgba/Png、Cells/Percent；图片 bytes 为 JSON 数值数组，UInt64 fingerprint 保持整数精度。Frame 在分配 cells 前检查尺寸/集合基数，整个 reuse JSON 使用现有 2 MiB string 上限；随后核对 grid、geometry、asset 长度/裁剪/预算与集合限制。
- 原生二进制协议仍由原 reader 解码；新增类型的 Decodable 不改变 binary tag/order。已知但未协商的 reuse/delta/scroll 明确拒绝，未知其他 named controls 仍沿用既有策略。
- Hello、worker 与 diagnostics 共享同一个 `requestSurfaceReuse=false` 源。实现已有，但生产仍不请求 reuse；delta/scroll 尚未接通。后续启用前需要完整 fixtures/状态/原生验收，不能把源码分支存在称为已交付优化。
- 手工按照 pinned serde schema 添加 reuse fixture（并非运行 Rust serializer 生成）：覆盖 cells 复用同时变更 projection、cursor、popup、两种图片 target 及 UInt64.max fingerprint。新增 patch → reuse、无基线、未协商、错误 boot/serial/尺寸/非空 cells/无效 hyperlink 的断言。
- 未生成 workspace、未编译、未运行上述断言或真实连接；只做静态 whitespace 检查。新 Swift 文件由源码 glob 覆盖，后续 build 前仍需重新生成项目。整体原生提交、API bootstrap、delta/scroll 与真实图片/多客户端/性能交付仍未完成。

### Connection-local surface scroll 恢复（未运行验证）

- 复核 pinned `surface_delta/decode.rs` 与 `surface_scroll.rs`：delta 是无填充 base64 包裹独立 bincode metadata/spans/popup update；scroll 是 count + 10-byte LE region/shift + 一张带四字节长度前缀的普通 PaneSurfacePatch。两种消息不能共用 JSON reuse decoder。
- Worker decoder 增加 scroll capability 协商、canonical STANDARD_NO_PAD base64、最多 64 个 region、ordinary frame cap、唯一内嵌 patch 与尾随字节检查。已知 delta/scroll named control 的 data 字符串可读到 graphics frame 上限，各自 decoder 再收紧自己的限额；其他 control 保持原字符串限制。
- Scroll 校验同 boot/projection/base surface、连续 serial、grid bounds、非零且小于区域高度的 signed shift、region 不重叠及 residual row bounds。所有检查在修改候选 cells 前完成，失败不推进 baseline。
- 按上游正/负方向 row-swap 顺序旋转，包括 vacated rows；应用 residual spans 后，将每个 region 的最终 rows 与 region 外的 residual 部分合并为普通 patch，避免向 UI 发送相互覆盖的扩展行。随后推进 worker baseline，支持下一条 reuse。
- Hello、worker、diagnostics 共用 `requestSurfaceScroll=false`。生产仍不请求 reuse/scroll；delta 的 frozen binary 解码、popup Patch/Replace 与相关基线仍待实现，没有宣称三种优化全部可用。
- 新增手写 frozen-layout scroll payload 用例，覆盖正/负滚动、residual rows、scroll → reuse、未协商/无基线、非法 shift/重叠/越界/截断/尾随字节和 base64 非 canonical 数据；未运行独立 Rust serializer 或测试。
- 未生成 workspace、未编译、未运行这些断言或真实连接；仅静态 whitespace 检查。实际普通 patch 几何/滚动图片/持续输出峰值仍需验收，完整迁移继续未完成。

### Connection-local surface delta 恢复（未运行验证）

- 新增 delta capability 协商及 canonical 无填充 base64 + frozen bincode 读取。Reader 为 delta metadata 明确要求主/popup cells 长度为零，先检查网格维度 <=4096 和 cells <=1,000,000，不分配声明的非空 metadata grid。
- 按 pinned decoder 处理 base projection/surface revision、同 boot/尺寸、连续 surface serial、非倒退 projection。普通 delta 受 2 MiB encoded 上限约束，有 graphics scene 才允许 graphics frame cap。
- 稀疏 spans 最多 4096 且不超 grid cells；坐标、非空长度、总 cell budget、排序/不重叠与剩余 bytes 均在 cell 分配前核对。Header 的 hyperlink/split path/graphics metadata 采用 delta 的上游集合限额，其他 full wire 路径保持原有参数。
- Popup metadata 独立空 grid。Replace 必须精确覆盖其尺寸；Patch 需要相同 terminal ID 和 grid 的旧 popup cells；打开、关闭和更换身份不复用不匹配基线。尾随 bytes、缺失/多余 popup update 与无效 hyperlink 均拒绝。
- 所有更新先在候选 surface 上完成并校验，再替换 worker baseline；旧基线保留主/popup cells 和必要身份，去掉 popup 的旧标题、links、graphics 等无关数据。失败不推进 revision，不影响后续合法消息的恢复。
- Hello、worker 和 diagnostics 共享 requestSurfaceDelta=false；三种恢复分支都有源码，但生产优化请求继续全部关闭，没有未经验证启用。
- 新增手写 frozen-layout delta payload 与主 cells/popup Replace → Patch → Close → Reopen 流程，以及未协商、缺失基线、错 revision、重叠/乱序/越界/空 span、无效 hyperlink、尾随数据和 popup 无基线断言。未运行 Rust serializer，这些不是独立黄金生成证据。
- 未生成项目、未编译或运行这些断言/真实连接，只做静态 whitespace 检查。混合 reuse/delta/scroll、独立黄金数据、图片资产、巨大集合、实际延迟/峰值与整体迁移仍待完整验收；不能将此记录称为已经通过 CS7。


### 原生 tab 候选模型与提交边界（未运行验证）

- `refreshHerdrLayout` 在全部 tab 的 binding/nativeLayout 构造完成前，不再替换 shell topology cache、暂停现有浮动视图或更新已安装 pane 的 snapshot metadata。
- `WorkspaceTabState` 候选复制包含后端/本地布局、焦点历史、隐藏/浮动尺寸及自动放大状态；候选共享 controller，但准备阶段只修改候选值。所有候选成功后写回原 tab 对象，保留异步浮动动画回调持有的对象身份。
- 浮动尺寸读取与暂停呈现拆开：候选准备只读取当前宿主尺寸，成功提交才移除浮动呈现。保存/切 workspace 的旧辅助状态仍捕获最终尺寸。
- 焦点保留使用 remap 后的候选 ID，避免 transport 转换时以旧 controller UUID 判断本地/浮动焦点。Metadata 回调延后到新 tabs/选择安装之后。
- 新增候选隔离与提交回归断言，覆盖本地 controller 身份、布局、焦点历史、隐藏、浮动、自动放大和 tab 对象身份。未编译或运行；仅做静态 diff whitespace 检查。
- 该提交边界只覆盖逻辑模型准备及其可抛错误；新 controller 创建仍会分配宿主对象，Ghostty view/grid/popup 就绪与跨 surface 呈现事务尚未完整实现。没有将此次修改称为完整原生原子显示或迁移验收完成。


### Endpoint 元数据与管理查询隔离（未运行验证）

- 已连接 ClientShell 的拓扑刷新不再先调用 `session.snapshot`：workspace/tab 顺序、公开 pane 身份、label/cwd、焦点与 zoom 取当前 endpoint snapshot。只读 API 的 `layout.export` 仍提供完整 split 树，核对同服务实例、pane 集合及当前 surface geometry 后才能提交；迟到结果仍受 generation/revision 检查。
- 拓扑一致性 helper 不再要求 API snapshot 元数据一致，避免其他客户端的全局选择或 ahead metadata 额外阻塞本 endpoint。各 tab 的树仍拒绝重复 pane ID，当前树必须能投影到一致 surface。
- CS pane 的 `applyHerdrSnapshot` 仅更新可选历史/进程查询绑定，不更新呈现 title/cwd。新增 endpoint metadata 接口，核对公开归属和服务实例后更新呈现；相同数据不重复调用 title callback。查询映射丢失不清除 endpoint 呈现或终止 pane。
- 补充拓扑不同步/服务 boot/revision/重复 ID 与 metadata 权威、查询映射丢失、不同归属/服务实例的回归断言；没有编译或运行。
- 首次 `enterHerdrWorkspace` 仍先用 API snapshot/layout 构造 viewport，随后激活 ClientShell；初始 bootstrap 并未完全解除 API 依赖。新增 pane 的 runtime 查询映射等待独立管理订阅/查询补齐；endpoint 元数据未伪造 terminal ID。真正 endpoint-first bootstrap、Ghostty view/grid 准备、整体图片及多客户端验收仍待完成。


### Endpoint-first inactive bootstrap（未运行验证）

- 新进入窗口 ClientShell 不再先调用 API snapshot 构建 tabs。窗口先建立 inactive endpoint，等待受限超时的初始 metadata；只有 peer 身份与当前保存/连接身份相符时才准备 native tabs。
- Session 保留既有自动激活默认值用于旧调用方；窗口使用显式延迟激活。Inactive hello 为非空 80×24 占位 geometry、未知 cell pixels 0×0、pixel_mouse=false；pinned server/client_transport.rs 的 geometry 校验允许未知 pixels。占位不是已激活 PTY 尺寸，也不伪称实际字体度量。
- 根据 endpoint metadata 查询并核对只读 `layout.export`，准备全部 tab 候选后建立原生 viewport，再使用实际测量的 grid/cell pixels 激活。显式 activation 要求 metadata/welcome/有效尺寸且只能一次；输出顺序沿用 resize → surface.set → focus，等待匹配 scene 和 native ACK 后才开放输入。
- Window metadata 等待与激活前均检查 cancellation、窗口 generation 和 session 身份；初始空 workspace、不支持协商、身份变化或 viewport 未挂载走明确失败路径，不启动 Herdr。
- 新增 inactive metadata、未就绪/零 pixels/重复激活拒绝、激活前无 resize/focus 和有序 activation trace 的隔离回归用例。未编译或执行测试，未连接真实 Herdr，仅静态 whitespace 检查。
- 仍保留只读 API split 拓扑依赖，Connect picker/旧恢复预检及历史/Agent 查询仍用管理通道。没有声称彻底只需一个 socket；设置/字体、原生呈现、图片、多客户端和恢复的完整验收仍待执行。


### Bootstrap 元数据重试与旧 controller 退出屏障（未运行验证）

- Native metadata 准备会退役旧 direct controllers；因此启动前一次 drain 不足。新增激活前第二次 drain，明确检查仍存活的 bridge；未退出则报错，不让 ClientShell 与旧 controller 同时激活控制尺寸。
- 整批 bridge 共享 3 秒 DispatchTime deadline，避免按 pane 数累积每个 3 秒等待。过期等待不等同于退出：返回后仍核对 process.isRunning。仅等待 Santty 自己的客户端子进程，不操作独立 Herdr 服务。
- 连接启动在初次 drain 前捕获窗口 generation，返回后核对 client 对象和窗口状态；旧启动不能在另一轮 reentry/Leave 后安装新 session。
- Inactive metadata 在拓扑查询或 viewport 挂载期间变化时，重新使用最新 endpoint metadata 准备；等待有 10 秒期限，循环检查 cancellation/session/generation/failure，未准备成功不会发送 activation。已有 socket 单次查询超时与该整体期限分别生效，期限不宣称可中断正在进行的系统调用。
- 增加两个隔离 sleep bridge 的共享过期 deadline 与“超时后仍存活”断言，退出清理仍走现有 release 流程。未编译或运行测试；仅静态 diff whitespace 检查。
- 未验证实际 bridge 退出时序、频繁拓扑变化及 Ghostty viewport readiness；完整迁移和图片/多客户端验收仍未完成。


### 按需解析 runtime 查询身份（未运行验证）

- 新 CS pane 不再必须等待后续管理订阅才能打开历史或查进程。缺少 query binding 时，`resolveHerdrQueryBinding` 只读查询 snapshot，核对公开 pane/workspace/tab 与 peer PID/start identity，再构造含真实 terminal ID 的查询绑定；不修改 endpoint/render binding，不伪造 ID。
- 历史、进程和 CLI read/search 使用同一按需入口。解析前后检查 cancellation、pane generation 与 query invalidation epoch；CLI 额外检查 controller 仍安装于窗口。订阅失去/更新身份或断开后，迟到解析不得恢复旧 mapping。
- 第一份 query mapping 安装不取消发起它的 history task；之后订阅导致的 mapping 变化仍沿用既有历史/进程失效逻辑。查询失败仅该功能报错，不终止图文 pane。
- CS 的进程查询结果不再覆盖 endpoint cwd；旧 direct cwd 更新保持原行为。
- 新增无初始 runtime 的历史/进程查询、呈现不被 API 覆盖和迟到 snapshot 对断开/identity invalidation 的回归用例；fixture 增加受控 snapshot 延迟。未编译或运行测试，仅静态 whitespace 检查。
- Agent 自动映射与全窗口 CLI、重连/服务重启及当前真实图像仍需完整验收；按需路径不是所有查询兼容已通过的证明。


### Agent 查询基线与不可用状态（未运行验证）

- 现有 includeAgents 管理订阅已经在事件和读超时期间刷新身份/Agent 状态，未再建立第二套轮询。窗口缓存最近一次管理 snapshot；新的 CS projection 仅对缺 query mapping 的 pane 使用其中经 endpoint/service/public scope 核对的 runtime 元数据，缓存不能覆盖 endpoint 选中、title/cwd 或几何。
- 配置新 endpoint 或管理连接失败清除缓存；失败同时标记后台 Agent 状态不可用。断开 pane、失去 query mapping、缺匹配 Agent 或未知上游状态也标记不可用，不伪造 sessionEnded。
- AgentSessionSnapshot 增加独立 backendStatusAvailable；Manager 显示 Status Unavailable 并使用次要颜色，保留最后确认的 session state、timestamp、历史和未读标记。只有匹配的、未倒退的已知 Agent 状态恢复可用；查询 mapping 本身不证明 Agent 状态当前有效。
- 初始 backend pane 状态等待独立订阅确认。Store remove/end/reset 清理不可用标记；本地 Agent 不受默认字段影响。重复完成通知仍使用 runtime completion watermark，不在恢复时重播旧完成。
- 新增 CS runtime 映射丢失/恢复、未知状态、断开、历史/未读保留与完成通知去重的回归断言。未编译/执行或运行管理订阅，仅静态 whitespace 检查。
- 缓存 runtime 是只读查询候选，后续 read/processInfo 仍执行实时身份验证；当前服务/重连、多窗口及用户真实图片的完整迁移验收继续未完成。


### 混合 surface 序列与真实上游 golden 入口（未运行验证）

- 扩展现有 scroll payload helper 的 projection/base serial 参数，补充 full → ordinary patch → reuse → delta popup patch → scroll → reuse 的连续 decoder 用例。断言主 cells、popup、graphics metadata 不相互覆盖，后续 COW 修改不改变已交付的旧 surface。
- 新增 `Scripts/herdr-clientshell-upstream-golden.rs`：作为 pinned Herdr crate 的测试模块包含，直接使用上游 ServerMessage、surface_reuse/delta/scroll 编码器及 upstream decoder，不再复制 Swift 或手写 Rust wire 声明作为优化 codec 的唯一依据。
- 生成入口构造合适大小的单 pane 网格与 pane/popup 图片 scene，调用真实编码器选择 reuse/delta/scroll，记录 payload hex、upstream 解码结果和对应 full expected surface；full/reuse/delta 输出先与生产者状态相等核对，最终 reuse 验证滚动后的 baseline。
- 运行需在 pinned 调查副本的 crate root 中显式添加 cfg(test) path module，并设置 `SANTTY_UPSTREAM_GOLDEN_OUTPUT` 的绝对输出路径，再仅执行该 test。该入口不是运行时依赖，也不列入普通 Santty 测试自动运行。
- 本轮没有包含/编译/运行 Rust 生成器，未创建或假称已有新的独立黄金字节，也未运行混合 Swift 用例。未来需生成并归档结果，再接入 Swift 对这些真实 upstream payload 的回归检查；三种优化请求保持 false。


### ClientShell 查询路径取消 executable 版本子进程（未运行验证）

- `HerdrWorkspaceClient` 明确保存 transport。CS 的管理/历史/进程查询只通过 Unix socket 执行，不运行配置 binary 的 --version；旧 direct 分支继续 stat 缓存和精确 Herdr 0.9.3 executable 校验。
- 窗口配置/picker 与只读管理订阅使用 CS 查询合约，进入 Control/LegacyControl 时按选定 transport 重建 request client。旧单 pane reconnect 仍用 direct 的精确校验；CS history/process/CLI/恢复调用方传递相应 transport。
- API ping/snapshot 仍要求已实现的 management protocol 22。CS 查询不再要求 server build 字符串等于 0.9.3，但保留非空、有界、无 NUL 的 version 字段校验；不放宽未知 API protocol。常规 endpoint generation/codecs/capabilities 仍单独协商，不以管理版本代替。
- 增加不同 build/同 API protocol 对 CS 与 direct 的分支断言，以及会写 invocation marker 的隔离 executable 用例，证明 CS 查询应不执行而 direct 应保留 executable 检查。未运行这些断言或任何 binary/服务验证。
- 只读完整 split 拓扑和部分功能仍依赖 management protocol 22，因此不能宣称任意未来 Herdr 均兼容。已实现的 endpoint-first bootstrap 不消除这一剩余 API 合约边界；完整迁移尚未验收。


### 原生图文输出批次准备与提交（未运行验证）

- Pane 与 popup 先确认 viewport/grid 并在 renderer 副本上编码，返回准备输出；准备阶段不向 Ghostty memory 写入，也不更新正式 renderer 的 cells/image ID/placement 基线。
- 窗口收集全部可见 pane 和 popup 的准备结果；任一 viewport 未就绪、图片编码失败或批次超预算时，丢弃整个待写批次，不先更新其他 pane 的 terminal bytes。所有目标就绪后在同一同步主线程调用批次提交，再执行 session native ACK。
- 准备输出累计限制 256 MiB，保留原单目标输出限制。此预算限制临时编码 bytes，不等于 CPU assets/cache、RSS 或 GPU 的总内存上限；极端多 surface 重建可能明确超预算失败，不能宣称无限图像容量。
- 每次提交复核 pane generation、surface attach/window、display epoch、session/boot 与当前 serial；popup 增加 renderer 生命周期 epoch。断线、设置或重建后的准备结果拒绝写入。窗口同步批次仍没有跨 Ghostty GPU surface 的同帧保证。
- 扩展现有原生 pane 隔离回归：准备后画面未写、缺资产编码拒绝不推进正式基线、重复准备输出一致、断开后旧输出拒绝提交。未编译或运行，未验证实际 GPU 显示；仅静态 whitespace 检查。
- 该边界覆盖图文编码和 viewport readiness，当前布局/host view 容器仍在输出准备前安装；失败时完整旧原生视图保留及整个迁移/图片/多客户端验收仍待完成。


### 原生解析等待移出主线程与外观回调修正（未运行验证）

- 静态阅读发现 WorkspaceRootView 存在两份同签名 viewDidChangeEffectiveAppearance override；合并为一次 super/background 更新及 Herdr theme 回调。没有把源码修正称为编译已经通过。
- 批次提交原先在主线程逐个等待 Ghostty 的 per-session parsing queue；移为所有目标先 enqueue，再 Task.detached 等待队列屏障，主线程可处理新的 scene、窗口事件与查询结果。编码/几何准备仍在主线程，不声称全部性能问题已经解决。
- 增加共享 PreparedRender 结果，包含 byteCount、isCurrent 与 enqueue commit。异步等待前后复核 pane/popup attach/display epoch、session/boot/serial；迟到旧 scene 返回 superseded，失效目标不 ACK。输入开放仍以全部有效目标的 native ACK 为条件。
- 移除仅剩测试调用的同步 renderClientShell 包装，防止后续运行时再落入主线程阻塞路径。现有原生用例改为显式 enqueue、后台等待与 isCurrent 检查；断开后准备结果拒绝提交。
- 连接设置文案与 README 更新 socket-only CS 查询和实验性图片边界，不再笼统宣称 CS 图片始终不可用或每个后端操作都启动 --version。
- 未编译/执行或测量 UI heartbeat、解析/GPU latency；仅静态 whitespace 检查。旧完整画面保留不能假定 AppKit cacheDisplay 可捕获 Ghostty Metal 内容，本轮没有加入未经确认的截图覆盖层。原生 host/container 在准备前安装的剩余边界、实际图像及整体迁移继续未验收。


### ANSI/Kitty 编码移出主线程（未运行验证）

- Renderer 增加异步 prepare：将 Sendable renderer/viewport/assets 值交给独立 worker，在副本上生成 ANSI、样式 diff、Kitty base64/placement/deletion bytes，返回候选 renderer 和 bytes。正式基线只在有效主线程 commit 时替换。
- Pane/popup 保留 AppKit metrics、固定 grid 与挂载检查，编码完成后再检查 lifecycle epoch、session/boot/serial；窗口每次 await 返回都拒绝被 supersede 的旧 scene，不能继续提交旧输出或 ACK。
- Caller cancellation 取消 encoder worker；逐行和逐 placement 检查取消，输出返回后再次检查。单次 base64 等库操作仍不能在内部强行打断，不宣称硬实时中断。
- 调整全部 prepare 调用方与原生测试为 async，补充候选不消费正式基线及取消不返回 commit 候选的纯 renderer 断言。未编译/运行，仅静态 whitespace 检查。
- Cells viewport 提取与 AppKit 几何仍在主线程；没有用此次源码变化代替真实切换延迟、GPU 图片和 UI heartbeat 证据。旧完整 host 画面保留及完整迁移验收仍待完成。


### Viewport cells 提取与 readiness 热路径（未运行验证）

- 后台 renderer.prepare 现在接收 Sendable target/surface/assets，在 worker 中提取 pane cells、转换图片目标坐标并编码；主线程不再先复制完整 viewport cells。
- AppKit 侧只读取已验证 surface 的 inner_rect 或 popup dimensions 来设置固定 grid，编码完成后仍复核 lifecycle/session/serial。提取过程增加逐行取消检查，非法 cell counts/矩形仍由原提取层拒绝。
- 移除每个 render 为判断 readiness 而调用 readViewportText 的整屏文本导出；使用实际 attach/window、surface grid 和 cell metrics 就绪证据。没有通过文本内容来决定 native parser 已完成，解析仍由后台输出屏障确认。
- 更新异步 renderer 用例为 target/full surface 入口，保留未提交候选不消费正式基线、输出正确及取消检查。未编译/执行或测量真实帧率/图片，仅静态 whitespace 检查。
- 这一改动不证明 Ghostty GPU 已显示、跨 surface 同帧或旧完整 native view 保留；整体迁移验收仍未完成。


### 持续输出的 in-flight presentation 固定（未运行验证）

- 异步准备/解析期间若每条内容更新都替换 offered serial，旧批次可能始终被判迟到而没有任何 native ACK。窗口现在显式 begin/end presentation；session 对同 boot/projection、相同 pane/popup 几何和 mouse/pixel modes 固定正在处理的 offer。
- 新 surface/patch/assets 仍顺序吸收并更新后台状态，只暂缓同几何的下一次 UI offer。当前批次提交并 ACK 后立即 offer 最新 scene；不丢图片资产或让一个旧批次覆盖新焦点/拓扑。
- canPresent 允许被固定的内容帧在最新 serial 已前进时完成，仍要求当前 snapshot revision、尺寸、选择/几何一致、无 pending future surface/navigation/fence。尺寸、popup、鼠标模式或 projection 变化解除固定并拒绝旧提交。
- 被固定帧 ACK 后，同几何内容更新不会冻结语义输入；未使用显式固定的旧调用方仍保持原 exact-frame ACK 规则。状态切换仍基于真实已提交的 backend geometry，没有乐观本地选择。
- 更晚画面的 presentation effects 保留到其 surface serial 已提交；ACK 旧固定帧不丢弃或提前执行这些 effects。缓存/队列预算和断线不重放规则保留。
- 新增隔离内容更新 fixture 用例：编码尚未完成时最新 serial 已前进、offer 未被替换、旧固定帧可以 ACK、随后 offer 最新帧，以及 resize 使固定失效。未编译/运行或测量持续真实输出；仅静态 whitespace 检查。
- 旧完整 host view 保留、effects 混合场景、持续图片/服务重启与最终迁移仍待完整验收，不将本次规则称为已经证明无饥饿。


### 固定帧与未来副作用混合回归（未运行验证）

- 隔离 fixture 新增 effects-in-flight：初始已呈现后固定第二帧，随后送第三帧及其 clipboard/bell，模拟解析期间继续输出。
- 新增两条回归分支：第二帧 ACK 后未来 effects 仍保留、只有第三帧 ACK 才执行且重复 ACK 不重放；resize 使第二帧和未来 effects 失效，断开不得执行旧 effects。
- 用例同时核对 deferredEffects credit 在保留、最终 flush、失效时归零，稳定几何输入 readiness 不等于最新图片的 effect 已获执行许可。
- 未运行 Python fixture、Swift 用例、原生 app 或真实服务，只更新回归源码及静态 whitespace 检查。仍不能将持续内容更新/副作用规则称为实际已通过；图片和完整迁移验收继续未完成。


### Ghostty 输出入队回执与非法资产断言修正（未运行验证）

- 静态核对 vendor surfaceAccess 确认 receive 在没有 C surface 时会丢弃 bytes，并且上层无法获知。新增可复现 Swift-only OutputReceipt patch 的 receiveIfAttached；旧 receive/Data/String 调用行为与签名保留，仅新 CS 提交使用 Bool 入队结果。
- Pane/popup 只有成功入队才推进正式 renderer 基线；失败返回 nil，不发送 native ACK。异步队列屏障后仍检查 display lifecycle/session/serial，防止 enqueue 后被替换的 surface 获得旧 ACK。回执只证明入队，不证明 GPU 可见或整个显示已成功。
- prepare-ghostty 增加幂等 patch 接线，ignored Vendor 副本同步源码；没有运行 prepare/generate/build，也不重编 C 核心。
- 发现前次原生测试用缺 assets 断言抛错与现有 renderer 的 deferred delivery 规则不符：改成 key 声明长度与实际 bytes 不一致的非法资产，真正检查编码失败不推进基线。合法缺像素仍等待服务端后续交付，不伪称画面图片已见。
- 图片上传每个 3072-byte chunk 增加 cancellation 检查，避免单张大图长时间拖延取消。
- 新增 unattached memory 输出回执拒绝的断言；未编译/运行任何用例、fixture 或服务，仅静态 whitespace 检查。native 入队/解析/GPU/multi-client 与完整迁移继续未验收。


### Endpoint 原生命令的身份核对取消 API 往返（未运行验证）

- 静态核对发现已路由的 pane focus/layout 操作仍先 verify → management session.snapshot，再向 endpoint 发命令。改为在已绑定的窗口 session 上核对公开 pane/workspace/tab、peer identity、绑定 boot 和呈现 readiness，不进行额外 API ping/snapshot 或 executable 探测。
- 未绑定 client、真实 runtime/history/process 验证和旧 direct 操作保留管理查询。Endpoint 不提供普通 runtime terminal ID；快速核对仅返回真实公开元数据，terminal_id 保持 nil。
- 命令路由绑定记录 boot ID；旧 route 在 disconnect/service/boot/归属变化后明确失败，不退回另一通道修改后端。verify 进入 MainActor 读取 endpoint session，返回类型仍 Sendable。
- 新增只有 client socket、完全没有 API listener 的隔离验证用例，覆盖 endpoint verification + rename、错误归属和断开后无 API fallback。未执行 fixture/test，只有静态 whitespace 检查。
- Source 搜索未发现当前 Swift 封装可导出 Ghostty 终端图片的接口；尚未证明底层预编译 renderer 是否另有可用 framebuffer 合约。未实现截图覆盖层，也未把旧完整画面保留标为完成。
- 真实切换延迟、旧 host view 保留及完整迁移/图片验收仍未完成。


### Pane focus 期间鼠标 release 与已按下手势（未运行验证）

- pinned server 明确接受当前可见 pane 的语义鼠标输入，不要求它已经是 focused pane；AppKit 成为 first responder 触发的 pane.focus 随后可能执行。原 sendNext 无条件释放所有已按下事件，会过早结束这个已送出的鼠标按下。
- 仅 pane.focus 指向当前已呈现/可见的同一鼠标 target 时保留该 target 的鼠标按下；键盘和其他 target 仍先释放。新 scene 仅改变 focused pane、未改变 pane 集合/矩形/popup/mouse modes/pixel geometry 时保留；resize、host focus loss、其他命令、失败或真正几何变化继续释放。
- 已登记的 release 可在 pending navigation/非交互等待期间独立发送，并保持原 target/boot 生命周期；不允许新按下、文本或 motion 跨等待发送，不积压/重放拖动轨迹。上游会接收曾按下 pane 的 release，即使其现已不可见。
- Pane controller 依据 session ledger 保留或清理按钮记录，避免焦点切换时提前清空导致之后拖动/真实鼠标抬起丢失；几何恢复后只使用当前有效输入路由。
- 新增同 viewport 的 pane focus 延迟 fixture，断言按下没有自动释放、pending motion 被拒绝、真实抬起可发送且 wire 上保留其真实坐标。未运行 fixture/Swift/native 验证，仅静态 whitespace 检查。
- 当前隔离用例覆盖保持 viewport 的 focus 请求；真实跨 pane 点击、拖动、popup/zoom/模式变化、服务 restart 与完整迁移仍需验收，不能称鼠标路径已全面通过。


### 同 tab 双 pane 鼠标焦点回归（未运行验证）

- 新增 mouse-focus 隔离 endpoint fixture：当前 tab 同时展示两个 1×1 内容矩形，均启用 mouse reporting；pane.focus 更新 endpoint snapshot revision 和 coherent surface，保留几何/pixel/mouse 模式。
- 新增真正从已 focused A 向当前可见 B 输入按下、切 focus 到 B、提交匹配 scene 后发送 drag/up 的完整 session 回归。断言 wire target 始终为 B、切焦点没有额外提前释放、随后 tab.focus 会自动释放新按下。
- 该 fixture 的 full surface 按冻结 bincode 布局手写，只有 client socket，不接触外部 Herdr；它不取代独立 upstream golden。未执行 Python/Swift/原生验证，仅静态 whitespace 检查。
- AppKit 真实跨 pane 事件顺序、拖动过程中 resize/popup/模式改变与完整迁移/图片验收仍待执行，未将源码回归称为通过。

### 提示编辑器跨重连提交隔离（未运行验证）

- 静态检查 IME/Paste hooks、菜单/文件路径拖放与提示编辑器；现有 ClientShell 分支使用语义事件，未发现这些调用会同时发送 Ghostty 编码 bytes。
- 发现 Prompt Editor 的 sheet completion 仅检查当前 canAcceptInput，打开后断开/重连会把旧编辑内容发送到新连接。打开时记录 pane 的 Herdr generation 和 ClientShell boot ID，Send 时核对；失效时拒绝发送并提示 beep。直接 submitPrompt 仍使用当前目标，普通本地终端行为保留。
- 在已有原生 pane 回归源码中加入打开 sheet → 填写旧 prompt → disconnect/rebind → Send 的路径，检查替换连接可输入但 trace 不含旧 prompt payload。该回归涉及真实 AppKit sheet completion，尚未执行，等待方式和时序仍需后续验证。
- 没有运行构建、测试、fixture、prepare 或真实连接；仅静态 whitespace 检查。完整 native host 提交、IME 实际表现、图片可见性与完整迁移验收仍未完成。

### 共享输入入口拒绝孤立 drag / tracked repeat（未运行验证）

- 静态检查发现 session.input 的 mouse 分支把无已登记 press 的 drag 也写入 heldReleases；这会向后端发送缺少按下的拖动，并在后续命令时制造额外 release。原生 pane/popup 调用方已有部分过滤，但共享 session 入口仍需统一保证。
- 在临时 ledger 中按事件顺序要求 drag 对应已登记鼠标按钮，tracksRelease 的 key repeat 对应已登记按键。非法批次返回 false，不发送任何 bytes，也不提交临时 ledger；同一批次 down/drag/up 仍有效。未跟踪 release 的语义 repeat 保留原行为。
- 新增隔离回归源码，检查初始 orphan drag/repeat、合法批次、抬起后的 orphan drag，以及后续命令不会制造 synthetic release。未运行 fixture 或测试，仅静态 whitespace 检查。
- 另确认 pane/popup 的 clipboard receive 会在主线程等待 outputQueue.sync。暂未移除：当前 clipboard patch 在解析 callback 时捕获 generation；异步化前必须解决旧输出延迟解析后被错误归入新连接的风险。队列关联和回调身份需一并处理，不能以减去 wait 掩盖竞态。
- 原生 host 提交、剪贴板非阻塞且跨连接安全的路径、真实图文/输入及完整迁移仍未完成。

### Host focus 释放后原生鼠标记录同步（未运行验证）

- setFocused(false) 会在 session 内发送已登记 release，但它不一定触发 state 变化；pane/popup 本地按钮记录可能继续把后续 Shift 选区、drag/up 当成远端旧手势。两个鼠标入口现在每次事件前按 session ledger 清理本地按钮；hasHeldMouse 增加默认 false 的 popup 参数，防止 pane/popup target 混用。
- 共享入口同时拒绝没有已登记按下的 mouse up 和 tracksRelease key up，包括已经由 host-focus/navigation 合成释放过的事件；合法非跟踪语义事件保留原规则。拒绝批次不写 wire、不修改正式 ledger。
- 隔离回归源码补充 orphan release；既有原生 pane 回归加入 down → host focus loss/restore → Shift drag/up，预期仅最初 down 与 focus-loss 的 synthetic up，Shift 手势留在本地。未执行用例或真实 AppKit 事件验证。
- 继续静态追踪 clipboard：Swift outputQueue 直接调用 ghostty_surface_write_buffer，但当前可读源码不能证明预编译核心的 writeClipboard callback 总在该调用同线程同步执行。未添加依赖此假设的 thread-local epoch patch，也未移除主线程 barrier；需要可证实的输出关联或可验证的核心 API 合约再异步化。
- 本轮只改 session/pane/popup 和回归源码、记录，执行静态 whitespace 检查；没有 build/test/prepare/generate 或外部连接。完整 host 保留、clipboard 路径及最终迁移仍待完成。

### 已挂载同几何 host 的焦点延后提交（未运行验证）

- 原 applyHerdrShellProjection 在异步 prepare 与输出屏障之前更新 tab focusedPaneID 并调用 applyFocusedPaneResponder；popup 也在输出准备后、屏障前成为 first responder。几何未变的既有 host 无需此提前切换。
- 同 tab/同原生几何更新保留原焦点直到批次输出屏障完成并再次检查 session/boot/canPresent/isCurrent；然后更新 endpoint focus、原生 responder 和 pane presentation，最后 native ACK。Popup first responder 同样延后；popup 消失时也延后移除旧 overlay，避免内容准备失败先拆除旧显示。
- 最终提交重新读取当前本地辅助焦点，保留编码期间用户切到 Notes/Browser/本地终端的选择；不以等待前捕获的焦点覆盖新的本地意图。副作用仍在 ACK 后按实际 responder 判断目标。
- 跨 tab/拓扑变化仍先安装几何以获取挂载及 grid，新增/替换 popup 也仍需要提前附着；完整旧 native host 保留尚未解决。本次不承诺跨 GPU 同帧或失败后完整 UI 回滚。
- 既有 popup 原生回归源码增加 readiness 与已准备 pane host 的断言；既有本地 Browser 保留与 tab/popup 切换用例继续覆盖最终行为。未执行任何用例，仅静态 whitespace 检查；真实时序、图片与完整迁移仍未验收。

### Endpoint 标签和元数据随图文提交（未运行验证）

- 将常规 applyHerdrShellProjection 中的 backend tab title、pane endpoint metadata 和 workspace switcher 更新移到成功输出屏障与身份检查之后、native ACK 之前。既有同几何内容更新不再先发布新标签再等待对应图文；初始化/拓扑候选仍需完整 native host staging 才能实现全部原子替换。
- 发现 pane.rename / tab.rename 命令响应回调直接设置 pane.name / customTitle，绕过 scene 提交并制造持久本地覆盖。ClientShell 分支现在只等待 endpoint 投影更新 backend 标签，不新增本地覆盖；direct 和本地重命名保留原行为。既有用户保存的本地名称未清除。
- window fixture 的 tab.rename 补齐权威 snapshot label 更新；无 runtime ID 的窗口回归源码增加原生重命名、等待呈现、backend displayTitle 及保存中无新增 customTitle 的断言。仍未执行 fixture/test，不能据此证明真实排序或显示已通过。
- 没有构建、生成、prepare 或外部连接，只静态 whitespace 检查。旧完整 host 保留、剪贴板队列身份及真实图文/多客户端验收继续未完成。

### 排序与关闭操作的剩余管理往返（未运行验证）

- moveTab 原先在 verify 后额外请求 session.snapshot 来计算 tab.move 插入索引。新增 orderedTabIDs(for:)：已绑定 endpoint 时使用同 boot/service/workspace 的 snapshot 顺序及 presentation readiness；断开/身份变化明确失败，不回退管理 API。窗口排序调用此共享入口；direct 保留真实 runtime verify 和管理查询。
- endHerdrTerminal 的 ClientShell 分支在 pane.close 响应后不再请求管理 snapshot/reconcile；由同连接的 endpoint snapshot/surface 更新原生 pane 生命周期。旧 direct 的关闭后查询保留，关闭命令本身仍验证并只发送一次。
- 现有没有 API listener 的隔离回归源码加入 endpoint tab 顺序及断开后无 fallback 的断言。未执行 fixture/Swift 测试或真实排序/关闭，未测量延迟改善。
- 本轮仅静态 whitespace 检查；完整 native host staging、剪贴板队列身份、真实图文/多客户端和完整迁移验收仍未完成。

### 创建操作由 endpoint 同时选择目标（未运行验证）

- 静态追踪发现 client.create 始终发送 focus=false，而完整窗口 createHerdrPane 不执行旧 installHerdrPane 的本地选择；新 tab/分屏因此可能仍停留在旧目标。Pinned server 的 endpoint 创建路径在执行 API 操作后同步客户端 location，TabCreate/PaneSplit 参数均支持 focus。
- 已绑定 endpoint command route 时创建请求发送 focus=true，由服务端在同一次操作中选择目标；未绑定 direct/管理创建继续 focus=false，保留旧单 pane 视图安装行为。没有额外 pane.focus 请求、鱼壳进程或乐观原生选择，窗口仍等待匹配投影。
- 新增 creation 隔离 fixture 的 request/ACK 源码及回归：无 API listener 时 tab.create、pane.split 均发送 focus=true，返回 pane 的服务身份来自绑定 route，wire 中没有追加 pane.focus。该 fixture 仅验证请求参数与回执，不模拟真正新增拓扑，不代表真实窗口创建/分屏已验收。
- 未执行任何构建、测试、fixture 或服务连接，仅静态 whitespace 检查；完整 native host staging、clipboard 队列身份及真实图文/创建/多客户端仍需完成验收。

### Snapshot/surface 配对空档的 release 保留（未运行验证）

- input 最前面的 coherentSurface guard 会在新 snapshot 尚未收到匹配 surface 时拒绝所有事件，包括已接受 press 的 release。现在先按当前 live transport/ledger 判断 release-only；仅新输入继续要求 coherent surface、presentation readiness、有效 target 且无 navigation/pending。断线清空 ledger，boot 变化仍触发失效，不跨连接发送旧 release。
- Pane/popup 进入 connecting 时原先无条件清空本地 key records，导致 AppKit keyUp 连共享 release 入口都到不了。新增按 target/popup/physicalKeyID 查询的 hasHeldKey，并按 session ledger 保留有效记录；popup 按钮也按 ledger 过滤。真正 resize/focus-loss/失败释放后的记录仍被清理。
- 新增 snapshot-gap fixture 与回归源码：接受 down 后只发送新 snapshot、无配对 surface，拒绝新文本，允许旧 up 恰好一次，pane/popup ledger 不混用；尚未执行。
- 静态复核同时发现既有 fixture 的 presentation/effects 后续帧误缩进在 window-drop return 之后而不可达。修正到 presentation.sync 分支，health ping 恢复其独立分支。相关旧回归此前未运行，不能视为通过；仍需执行确认新的 fixture 时序。
- 未运行 build/test/fixture/prepare/generate 或真实连接，仅静态 whitespace 检查。完整 native host staging、clipboard 回调身份、真实输入图文和完整迁移仍未完成。

### ClientShell 剪贴板改为带提交身份的宿主事件（未运行验证）

- 静态读预编译 macOS 头文件及 package host-managed IO patch：write_buffer 调用 processOutput；另读调查副本 Ghostty stream_handler/Surface 源码，OSC52 先进入 surface mailbox 再处理 clipboardWrite。因此 Swift outputQueue drain 不是最终 clipboard callback 身份屏障，不能以 thread-local 同步 callback 为前提修复。
- 新增可复现 Swift-only TerminalClipboardWrite+HostEvent.patch。AppTerminalView.requestClipboardWrite 从 TerminalController 当前 resolved config 读取 clipboard-write（C config_get enum 字符串合约），deny 直接处理不写，allow/ask 复用原有 MainActor 确认/写入 helper；未知配置/无 surface/超过 2 MiB 明确拒绝。提交时捕获 bridge generation，在确认前后沿用 generation、surface、delegate 焦点检查。
- Pane/popup 的 endpoint clipboard effect 使用新 host event 入口，不再编码 OSC52、进入图文 output queue 或在主线程 waitForPendingOutput。Root 仍只处理有效的远端键盘焦点；没有复制第二套 pasteboard/确认 UI，也不改变 legacy C callback 的外部签名或重编 C 核心。
- prepare 脚本按 marker 在原 policy patch 之后接入新 patch；ignored Vendor 镜像同步源码。普通 C callback 的 shared helper 仍保留并测试原有路径，不宣称已解决所有 legacy mailbox 消息的归属。
- 现有原生 clipboard policy 回归源码补充 host event 的 ask→host reject、提交后 invalidate、超预算拒绝及 resolved deny 不开确认；不接触实际 clipboard，因为测试 delegate 一律拒绝。未运行测试/prepare/build 或连接服务，读取不同源码副本的 C config ABI 仍须用实际预编译包验证。
- 本次仅静态 whitespace 检查，不能证明真实确认与失效时序或主线程延迟。完整 native host staging、图片及多客户端/本地功能最终验收仍未完成。

### 宿主剪贴板事件队列预算（未运行验证）

- requestClipboardWrite 原先只有单条 2 MiB 限制；连续 endpoint events 可形成无界 MainActor Tasks/待确认字符串。新增每 bridge 的 host event credit：allow 至多 128 个、总 UTF-8 文本 4 MiB；ask 同时只允许一个待处理请求，防止 modal nested loops 打开多层确认。
- 预算在提交时预留，helper 的 MainActor defer 在完成、delegate 拒绝、generation 失效、surface 失效和用户取消时归还。invalidate 不重置计数，避免旧任务随后归还形成负额度；bridge 消失时其 credit 生命周期一起结束。超预算返回 false，由既有窗口错误路径报告，不重放请求。deny 不预留任务或额度。
- 新增 HostEventBudget Swift-only patch 并在 prepare 中按 marker 接到 HostEvent patch 之后，ignored Vendor 镜像同步。Legacy C callback 不使用 host credit，本次保证限定于 ClientShell host event 入口。
- 回归源码补充重复 ask 拒绝、两条 2 MiB 达到总上限、空请求占用数量额度、invalidate 后归还并接收下一条。测试 delegate 仍始终拒绝系统写入；未运行测试/prepare/构建或真实事件，只静态 whitespace 检查。
- 实际 callback/config ABI、MainActor 调度和确认行为仍待验证；完整 native host staging 及真实图文/多客户端最终验收继续未完成。

### 候选 host 挂载契约的原生回归源码（未运行验证）

- §11.7 依赖同 window 下遮挡候选仍能附着 Ghostty 并取得 grid。新增 HerdrClientShellHostStagingTests，使用两个独立 in-memory TerminalView，无 PTY/Herdr 服务；候选位于旧 host 下层且 alpha=0，不移动旧 host。
- 源码断言候选 window/grid/cell pixels、队列解析后的候选文字、旧文字和 frame 保留、hit target 仍为旧 host，并分别覆盖 commit 替换和 cancel 移除。该测试只检查挂载/解析/NSView 生命周期，不检查 Metal 像素、图片或同 pane 重用，不可用来宣称 GPU 画面正确。
- 新文件由 Project.swift 的 Santty/Tests/** source glob 覆盖，但未生成项目、未编译、未执行。是否恢复隔离验证的用户问题仍待回复；原“不验证”继续有效。
- 没有添加未接线的容器 API，也未据未经验证的挂载假设改写正式显示所有权。完整候选 host/floating/popup 提交及最终图文验收仍未完成。

### 独立 tab host 的候选容器接线（未运行验证）

- 将上一条挂载契约接入正式源码：Root stage/commit/cancel 容器在同 window 下方保持 alpha=0，layout 同步候选 frame；成功 commit 才移除旧 renderedContentView，失败或取消按候选 identity 移除，不触碰新候选。
- applyHerdrShellProjection 在既有完整 tab 身份匹配、跨 tab、目标 host 均尚未附着、无当前/目标 popup、目标无 active detached/floating 的情况下使用候选 tiling。旧 selectedTab/容器/floating 保留到图文准备与输出屏障完成，随后切换 tiling/选择/metadata/输入路由并 ACK。viewport helper 临时以候选 tab 计算几何，避免使用旧 tab 辅助区比例。
- stop/Leave 清除候选 tab 和容器；旧异步任务的 defer 仅在同窗口 generation 时清理 stagingTab，容器取消按 NSView identity 检查。最终替换后再次检查 prepared outputs，避免生命周期变化获得旧 ACK。
- 原生 staging 回归源码改为调用正式 Root API，覆盖其 commit/cancel。未生成项目、编译或执行；此前挂载假设依旧未被证明，不能宣称 staging 已通过。
- 同 pane 重用、拓扑刷新、新/旧 popup 和 active detached/floating 目标继续走既有路径，尚不能保留完整旧 host。本次是完整 staging 中 disjoint-tab 路径的接线，不缩减最终要求，不称全面完成；Metal 图片/多客户端及完整迁移仍待验收。

### Popup 候选与正式显示生命周期（未运行验证）

- Root 增加独立 staged popup：旧 popup 和命中目标保留，候选 alpha=0 且可挂载，commit 后替换；cancel/stop 清理候选。debugHerdrPopupView 只返回正式视图，不能把准备中的候选报告为已经显示。
- WorkspaceFloatingOverlayView 原 hitTest 在子视图 hitTest 返回 nil 后仍返回该子视图，alpha=0 候选会截获输入。现在跳过 hidden/alpha-zero 子视图，旧 popup 命中保持正确。
- PopupController 区分 isPresented：候选挂载仍重置自己的 renderer epoch，但不使整个 session 的已固定呈现失效；正式显示的 lifecycle 变化继续 invalidatePresentation。候选不接收语义输入或 clipboard。替换/移除旧 popup 前 retire presented 标记，避免旧显示卸载反过来使新批次失效。
- 投影先准备候选 popup 输出，屏障后同时检查 tiling/popup candidate identity，再提交容器、正式 popup、选择/metadata/responder 和 ACK。独立 tab staging 不再排除当前/目标 popup；即使 terminal ID 相同，跨 tab 的候选仍使用独立 in-memory display 和上传基线。
- 新增 Root popup commit/cancel/hit-target 原生回归源码；原有窗口 popup、Browser/tab 切换回归继续覆盖最终接线。未编译/运行任何测试、fixture、生成或真实服务，只静态 whitespace 检查。
- active detached/floating 目标、同 pane 重用和拓扑变化的旧完整 host 保留仍未实现；挂载/解析/Metal 及多客户端时序未证明。整个迁移继续未完成，恢复验证问题仍待用户回复。

### 稳定 pane 与替换 display 的 delegate 交接契约（未运行验证）

- 静态读取 AppTerminalView+Lifecycle 确认移出 window 不直接 teardown C surface，重新挂载只在 surface=nil 时重建；改变 controller/configuration 则进入 rebuildIfReady/tearDownSurface。Coordinator.delegate setter 只更新 bridge，不重放 terminalDidAttachSurface。
- 同 pane 双 display 不能新建第二个 TerminalPaneController：其 init/deinit 自动注册/注销 Agent 身份，还会重新创建查询和输入状态。需要只替换 display 资源，稳定 controller/UUID/Agent/查询保持；候选单独跟踪挂载，promote 时显式转移已知 attached 状态。
- 新增原生 delegate handoff 回归源码：候选先用独立 lifecycle observer 挂载，旧 view 清除 delegate、新 view 交给稳定 owner，再替换容器并销毁旧 controller；断言旧 teardown 不向稳定 owner 发 detach，新 display 真正 teardown 才通知 owner。复用 staging test 的 display factory，不创建 PTY 或连接 Herdr。
- 该契约尚未执行，不能认为实际 C callback 时序已通过；正式同 pane display 资源交接尚未接线。仅写回归源码/记录，未编译、运行、生成、prepare 或外部连接；完整视图保留与真实图片验收继续未完成。

### 显示输入回调按 generation 与 view 隔离（未运行验证）

- 将 pane 的 Key/IME/Paste/Mouse/onPasteText 安装收口为 installClientShellInputHandlers，init 和新 ClientShell binding 使用同一实现；没有复制第二套事件编码。每个 callback 捕获安装时 generation 及 weak view/host identity，失效回调不能操作新显示的 ledger 或发送到新连接。
- 发现原 semanticTextCommitHandler 只捕获稳定 self，保存的旧 IME commit closure 在 disconnect/rebind 后可能送入新连接。回归源码保存旧 closure，重连后同时调用旧/新 handlers，检查 trace 只有 fresh commit，旧 prompt/IME 均未写 wire。
- Popup setPresented(false) 清理本地 key/button/wheel/preedit，防止旧显示保存的 key-up 在相同公开 popup ID 的替换显示上释放新按下。共享 session 的 release 所有权不改变，未跨显示重放输入。
- 正式同 pane 双 display 的资源交换尚未接线；本次完成其共享输入入口及旧回调失效边界。未构建、运行用例/fixture、生成或接入真实服务，仅静态 whitespace 检查；完整 host staging 与真实图文最终验收仍未完成。

### 恢复验证、接通同 pane/拓扑/浮动显示交接（2026-10-12）

用户明确要求“继续实现，并执行必要的验证”，覆盖此前“不验证”的限制。执行 `mise run tuist:generate`（包含 prepare-ghostty），以 FlowDeck 的既有 Debug/My Mac 配置构建并运行 XCTest；未安装或启动外部 Herdr，未操作用户的图片 pane，也未更改 SSH 跳过决定。

- 编译发现并修复 Agent 状态色 switch expression、HostColors writer 写入权限、surface scroll 覆盖区间类型推断，以及测试调用过时输入方法。HostEvent/Policy/Budget、语义输入和 in-memory output patches 已实际参与编译和相关测试。
- 原生交接验证发现候选 attach/cancel 和旧 surface teardown 会使整个 session presentation 失效；以 presented/candidate 生命周期隔离修复。尺寸改变后立即丢弃旧尺寸准备，等待对应 scene；焦点操作在异步执行前再次检查 readiness，不因调度间隙失去选择请求。
- 同 pane 只替换 host/view/controller/memory/feedback/renderer，保留稳定 TerminalPaneController、UUID、Agent 和查询状态。候选图片上传基线独立，CPU 资产复用；安装新的 generation/view 输入 handlers，旧 callback 无法写入新显示。移除旧 delegate 后释放旧 C surface。名称提示和已打开的 persistent history 随提交保留。
- 拓扑管理返回不再立即 rebuild 原生 UI；旧展示的 controller 在候选完成前保留。tiling/floating/popup 在同窗口准备，批次 parser drain 和身份检查完成后交接。候选被尺寸变化撤销时保留 native layout pending 标记，防止下一帧误判布局已经展示。
- 新增同 pane 撤销/提交与稳定身份、外部 split 拓扑、浮动 tab 往返和浮动容器撤销/提交回归；已有 Browser 辅助状态保留、popup、输入/剪贴板、颜色、断线恢复、持久化回归一起运行。
- 修复测试夹具遗漏的 `tab.focus` 能力和 metadata trace 断言；原生 pane 测试在 attach 后重新 bind，按实际生命周期验证。压力测试显式销毁原生 Ghostty controller 后，100 次释放的原 FD 阈值通过，未放宽限额。当前 OS 缺少私有圆角 getter 时明确 XCTSkip。
- 全套执行曾在不同 Direct 夹具清理处超时，单项重跑通过；把 HerdrWorkspaceTests 的 Process 等待移到 XCTest 异步 teardown，在 worker 等待子进程并完成文件清理，释放 MainActor 处理回调。最终结果另列于下。

证据边界：测试证明实际 C surface 挂载、文本解析、资源交接及输入路由；没有验证外部 Herdr 的当前图片像素或多客户端真实几何，也不承诺多个 Metal surface 在同一 GPU 帧更新。reuse/delta/scroll 协商保持关闭，上游实际编码 golden 尚待运行；整个迁移未标为最终交付。

最终回归结果：FlowDeck 全套 XCTest **446 项：437 通过、9 跳过、0 失败**（88.90 秒，`/tmp/santty-final-validation.jsonl`）。9 项跳过包含当前 OS 不提供私有圆角 getter 的用例及依赖显式外部环境的用例。此前完整历史反向逐行选择经跨页合成鼠标返回 nil；完整历史范围改用现有 Ghostty 原生 select_all，保留 viewport，不发送 PTY 输入，滚动交互 10 项及全套回归通过。

全套通过后补齐候选图片反馈：候选准备期间收到 Ghostty rejection 会记录错误并使 prepared render 失效；提交后到达的反馈仍能定位到已提升显示。向独立候选 C surface 注入不完整 RGBA 图片，验证拒绝可见、候选不能提交、旧 surface 保留并能重新准备有效显示。该新增边界的定向 XCTest **1 项通过、0 失败**（`/tmp/santty-image-rejection-validation.jsonl`）；没有向外部 Herdr 写入测试内容。最终 standalone build 结果见下。

最终 `flowdeck build --json` **BUILD succeeded**（`/tmp/santty-final-build.jsonl`）；`git diff --check` 通过。未部署或替换 `/Applications/Santty.app`，工作树保留供审阅。


### 2026-10-12：移除旧 terminal transport

用户在真实服务窗口从 direct 切换 ClientShell 后确认图片可见，并要求移除旧通道。本节替代上述保留 direct/Observe 的迁移策略。

- 删除 HerdrTerminalSession、ANSI terminal.frame 解码器、HerdrInputRelay 和 Debug prototype window；生产代码不再启动逐 pane 的 terminal session 子进程。
- Connect、Reconnect、Take Control、恢复统一使用 ClientShell；移除 Read Only / Legacy Control / Observe 菜单、命令与快捷键设置。Take Control 仍通过 endpoint pane.focus 取得当前 tab 几何控制权。
- 删除运行时 mode/transport 选择参数。transport/mode 的单值类型仅用于现有存档和诊断；旧 direct、observe 字段解码为 clientShell、control，未知值及 takeover 存档仍拒绝。v1/v2/v3 读取兼容和原有数据校验保留。
- 旧完整窗口按保存的服务身份恢复为 ClientShell；旧混合布局保留本地 Notes/Browser/终端位置与已有 backend 身份，以占位显示提示显式进入完整 Herdr 工作区。第二实例不激活 ClientShell、不控制 backend 尺寸、不覆盖 owner 文件。
- Herdr 模式中的新 tab 和分屏使用现有后端创建路径。管理 API 仍用于拓扑和历史/进程/Agent 查询，未把这些查询接口误删为旧显示通道。
- 删除只测试旧通道的用例及 API fixture 的旧 terminal emulation。保留协议、输入、图片、隔离查询、本地呈现与持久化测试，并加入旧窗口迁移、单 writer 保护和 ClientShell CLI 查询回归。

验证边界：最终 standalone FlowDeck build 成功（/tmp/santty-remove-direct-final-build.jsonl）。一轮无需显示器的测试 80 通过、2 跳过（/tmp/santty-remove-direct-pure-tests.jsonl）。最终参数收口后的协议复测 **90 通过、2 跳过、0 失败**（/tmp/santty-remove-direct-protocol-validation.jsonl）。需要显示器的 12 个原生 session 用例及 2 个原生 renderer 用例通过 selector 排除，未计入这次通过数；AppKit 恢复类此前通过，联合复测停滞后的最终原生复测未完成。

运行原生窗口测试时，FlowDeck screens 返回 0 个显示器，Ghostty 报 CVDisplayLink invalid display count (0) / surface OutOfMemory，图片与窗口迁移用例不能完成。一次联合复测也在 AppKit 恢复布局时出现无效几何并停滞；仅停止由 XCTest 日志和 UI inventory 同时确认的测试主机 PID 82448，未退出用户开发版 PID 50765、正式版 PID 88327 或独立 Herdr 服务。已请求恢复显示器；原生图片、旧完整窗口真实恢复和多客户端验收仍待恢复环境后执行。

### 2026-10-12：切换 tab 卡死调查（未复现，未修复）

用户确认问题发生在构建版，并选择保持各客户端独立选择。上游 `src/server/headless/client_views.rs` 的 ClientShell endpoint 导航仅更新请求客户端；公共 API focus 才同步所有客户端。当前保持 endpoint 导航，不增加全局 focus。

新增两个原生回归探针：40 次逐次切换等待可输入，以及服务端延迟响应下 60 次快速切换并等待最终目标可输入。两个用例分别通过（`/tmp/santty-tab-freeze-repro.jsonl`、`/tmp/santty-tab-freeze-rapid-repro.jsonl`），但没有产生用户所述卡死，不能作为修复证明。

FlowDeck 后台启动最新开发版 PID 18018，使用真实外部 Herdr 在三个现有 tab 间切换，不输入终端命令。原生菜单及诊断仍响应；诊断记录 34 个已完成导航，pendingRequests=0、navigating=false、navigationAwaitingHostCommit=false、presentationReady=true，各传输队列均空。请求响应 P50/P95 为 8.91/31.28 ms，含主机显示提交的导航总耗时 P50/P95 为 96.59/293.92 ms。证据 `/tmp/santty-tab-freeze-diagnostics.json`。中途截图返回无可见窗口，但进程仍运行且 AX 可读取诊断；这不足以证明卡死。

本轮没有修改生产逻辑，没有停止独立 Herdr，也没有替换正式版。真实卡死现场、主线程阻塞位置及触发条件仍待捕获；新增用例仅覆盖当前可运行路径，不宣称问题已解决。

### 2026-10-12：捕获失败现场及修正拒绝通知语义

用户提供已卡住构建版 PID 23048。FlowDeck AX、截图和诊断菜单仍响应；ClientShell state=failed、capturedAtFailure=true、presentationReady=false，所有 backend pane 失败但旧画面保留。管理 API 仍 subscribed。失败前完成 62 次导航，最后一次总耗时 30.21 ms，无待处理请求或导航／host commit 等待。现场保存在 `/tmp/santty-hung-23048-diagnostics.json`。诊断导出将原始失败文字泛化；已请求从保留实例的终端 tooltip 取得原文，尚未确认具体触发报文。不能称为主线程死锁，也不能断言当前现场由以下修复覆盖。

对照上游 `src/client/mod.rs`、`src/client/shell/actions.rs` 和 `src/server/headless.rs`，wire tag 15 `ClientShellError` 是操作拒绝 notice（例如粘贴超限），常规客户端不退出连接。Santty 原先把它抛为致命异常，导致所有 pane 禁用输入和导航。现在经现有 effect callback 显示拒绝原因并保持连接，不回放被拒绝操作；notice 不依赖 presentationReady，导航交接期间也可显示。真正协议损坏仍 fail closed，但改为弹出原始失败原因；诊断面板本地提示显示 herdrLastError，JSON 导出继续使用分类摘要。

新增隔离原生测试，在已挂载窗口切 tab 的过程中发送真实 tag 15。修复前失败并复现旧画面与导航／输入失效（`/tmp/santty-endpoint-rejection-before.jsonl`）；修复后可继续往返切 tab、可输入、无恢复尝试。拒绝通知、致命协议提示、普通断线恢复、损坏报文不回放共 4 项通过（`/tmp/santty-endpoint-rejection-after.jsonl`）。没有停止外部 Herdr 或重启保留的现场实例；真实此次触发原因仍待原始错误验证。

Standalone FlowDeck build 成功（`/tmp/santty-clientshell-error-build.jsonl`），`git diff --check` 通过。修复尚未替换运行中的现场实例。

### 2026-10-12：修正 patch 内容标记误判为几何变化

用户再次提供明确错误 `Herdr patch changed pane geometry`。定位到 `HerdrShellProjection.receive(patch)`：同一个 guard 除检查矩形、焦点、像素尺寸外，还错误要求 `content_revision` 不下降。上游 `src/server/client_shell.rs` 会在渲染期间内容不稳定时设置 `after | 1`，后续 retained patch 使用实际稳定内容值；因此标记可从 9 变为 8。上游常规客户端 `src/client/shell/surface_patch.rs` 的 geometry 判断不比较内容标记；有序基线由 projection/base_surface/surface revision 保证。

新增确定性回归：几何完全一致，完整 surface 带 content_revision=9，后续 patch 带 8。修复前报出与截图一致的错误（`/tmp/santty-patch-content-before.jsonl`）；移除多余内容单调性判断后通过。保留全部实际几何、基线、行范围与原子提交检查，并断言真实 rect 变化仍拒绝且不改动已提交 surface。状态类 10 项通过（`/tmp/santty-patch-content-after.jsonl`）。原生 fixture 按真实 wire 交替发送不含图片的完整帧和 9→8 patch，连续 40 次切 tab 后仍可输入，原生用例通过（`/tmp/santty-patch-content-native.jsonl`）。没有改 Herdr 服务端。

这是已证明会触发该错误的客户端校验缺陷；截图未记录实际各字段差值，不能排除其它真实几何变化路径。真实多客户端操作仍需运行修复版继续验收。

Standalone build 成功（`/tmp/santty-patch-content-build.jsonl`）。FlowDeck 启动修复版 PID 51862（`/tmp/santty-patch-content-run.jsonl`）；截图可见原有 image tab 及图片。诊断菜单调用返回成功但 AX 没有找到面板，未用此结果宣称现场连接状态或多客户端长期验收已通过；没有重启 Herdr 服务。

### 2026-10-12：减少 tab 画面编码开销

使用固定 314×41、含交替前景色的 ASCII 冷帧，重复 30 次 Debug 编码建立基线。优化前输出 130365 bytes，P50/P95 36.99/37.79 ms（`/tmp/santty-encoder-perf-before.jsonl`）；优化后输出 22031 bytes，P50/P95 4.75/4.87 ms（`/tmp/santty-encoder-perf-after.jsonl`）。编码中位数约减少 87%，输出约减少 83%；这不是完整 tab 切换时间，也不覆盖 Unicode 密集帧、图片上传、Ghostty 解析或 GPU 呈现。

仅修改共用编码器：连续可打印 ASCII 顺序输出，跳过单元打断 run；非 ASCII 及其后首字符仍显式定位，保留原宽字符处理。相同 fg/bg/modifier 复用已有样式，不再每个字符构建 SGR；ASCII 跳过 Unicode 清洗和宽度扫描。链接、控制字符过滤、图片和显示提交／身份／几何同步校验不变。

渲染类 17 项通过，含候选取消、字符样式／宽度／链接／控制字符、真实 Ghostty 文字与 Kitty RGB/RGBA/PNG 图片。导航类 4 项通过，覆盖 40 次正常切换含 9→8 patch、60 次延迟响应下快速切换、floating pane 往返及本地 Browser 切换到含 popup 的 backend tab（`/tmp/santty-encoder-navigation-tests.jsonl`）。没有新增依赖，没有改 surface 生命周期或并行扩大准备批次；真实多客户端操作的整段延迟仍待运行优化版测量。

Standalone build 成功（`/tmp/santty-encoder-optimized-build.jsonl`），FlowDeck 已启动优化版 PID 72056（`/tmp/santty-encoder-optimized-run.jsonl`）；`git diff --check` 通过。截图可见真实 Herdr image tab 的文件管理器当前选中 ZIP 的文字预览，当前没有图片；真实图片验收未在这次启动重复，图片验证来自上述原生测试。未停止或重启 Herdr 服务。

### 2026-10-12：workspace picker 切 tab 闪烁

定位两条更新路径：每个 ClientShell 画面提交调用 updateWorkspaces，原实现无条件清空并重建菜单；通用 runHerdrOperation 对 pane.focus 也禁用／启用 workspace picker，造成短暂变暗。修复前定向回归确认菜单对象变化和控件禁用（`/tmp/santty-picker-flicker-before.jsonl`）。

updateWorkspaces 现在只比较 workspace ID、标签及顺序，active_tab_id 变化不重建菜单；相同已确认选择不触发控件更新。用户选 workspace 后保留服务端已确认标签，待实际投影提交才更新，以免忙状态拒绝请求后留下错误名称。通用命令不再禁用 workspace picker，禁用只保留在 workspace focus、重连与恢复流程；操作 pending 的 workspace／Leave 请求仍经原串行门控拒绝，不增加并发 mutation。

3 项定向回归通过（`/tmp/santty-picker-flicker-after.jsonl`）：相同 workspace 下 tab 元数据更新保留 NSMenuItem 身份、更名／选择／隐藏更新正确、深色外观和左下角布局正确，以及延迟响应下连续 60 次切 tab 控件保持启用。没有改 Herdr 协议、输入或导航提交语义。真实像素层面的闪烁验收仍需运行修复版。

Standalone build 成功（`/tmp/santty-picker-flicker-build.jsonl`），修复版已启动 PID 84952（`/tmp/santty-picker-flicker-run.jsonl`），截图与 AX 验证 picker 保持左下角且可用。`git diff --check` 通过。未重启 Herdr 服务；没有做切换过程逐帧录像。

### 2026-10-12：Leave 恢复为可用本地终端

用户退出 Herdr 后看见旧 backend 占位提示。原因是 Leave 原样恢复 parkedLocalTabs；旧混合布局中保存的 persistentTerminal 占位也被恢复。现在显式 Leave 将恢复布局中的终端占位及旧 backend TerminalPaneController 转换为本地终端，保留 pane ID、名称、布局、本地 Notes/Browser 和已有本地终端对象。仅继承本机存在的目录，远端或已删除目录使用默认本地目录。清除 tab backend 元数据；没有原本地 tab 时创建本地 tab。已出现窗口的所选本地 tab 启动终端。

releaseHerdrConnections 在退出清理前设置关闭标志，使关闭窗口／App 不触发新的本地 shell 创建；不关闭外部 Herdr 终端。新增旧 mixed terminal + Notes 回归在修复前失败（`/tmp/santty-leave-local-before.jsonl`），修复后保留 Notes/布局/名称且 terminal kind=localTerminal、binding=nil。最终旧完整窗口迁移、普通 Leave、旧混合占位转换共 3 项通过（`/tmp/santty-leave-local-final-tests.jsonl`）。

### 2026-10-12：合并连接设置与 Enter 入口

移除菜单和命令面板的独立 Herdr Connection Settings 入口及 selector。统一使用 Enter Herdr Mode…：先确认可执行文件、session、socket，再选择 workspace。Enter 每次可查看／修改设置；预填当前连接，未设置时使用保存值和原默认值。相同 endpoint 不重建 client 或 management subscription；改动 endpoint 仍受已有“必须先移除现有 backend views”保护约束。原 Enter 命令 ID 和快捷键保持，README 已更新。

AppMenu 与命令面板定向测试共 3 项通过（`/tmp/santty-herdr-entry-merged-tests.jsonl`）；不再暴露独立设置入口。

构建通过（`/tmp/santty-herdr-entry-merged-build.jsonl`），开发版启动 PID 15648（`/tmp/santty-herdr-entry-merged-run.jsonl`）。后台打开统一菜单入口，AX 确认 Continue 按钮可用后取消，没有提交连接变更；未重新验收实际 workspace 连接。

### 2026-10-12：统一 workspace picker，移除模式入口

picker 始终在左下角显示本地 Default，以及发现的本机 Herdr workspaces；用 desktopcomputer / server.rack 图标区分来源。启动恢复到 Default，异步读取已运行的本机 Herdr 管理 API 并订阅变更，不自动激活 ClientShell。发现失败不弹启动错误，不影响本地 workspace。选择 Herdr 条目直接建立 ClientShell，后续 Herdr workspace 切换仍通过该客户端的 endpoint 命令完成；选择 Default 断开终端显示连接并恢复仍运行的本地 tabs。没有启动、安装、停止或升级外部服务，也不通过 fish 执行连接命令。SSH Herdr workspace 暂未实现，没有虚假的可选条目。

移除 Enter / Leave Herdr Mode 菜单、命令面板条目和旧 Enter 快捷键动作；保留新建、诊断、断连／重连及显式结束操作。连接配置移到 Settings → General → Herdr Workspaces（Executable、Session、API socket），Apply and Refresh Workspaces 验证后保存并刷新；连接目标改变时先回 Default。重复应用相同目标不重建已连接 ClientShell。旧设置键保持兼容。

Herdr workspace 内的本地 Notes、Browser、浮动／隐藏本地 pane 保留归属，不再在回 Default 时全部转成本地 tabs。workspace 格式升级到 v4，允许在 Default 下保存这些附加 tabs；读取 v1/v2/v3，旧完整 Herdr 窗口恢复本地 parked tabs 和 backend 附加内容，等待 picker 显式选择。服务身份匹配时复用附加内容；服务重启复用同名 ID 或 backend tab 已删除时，将附加内容安全恢复到 Default。保留单写者锁、布局／身份验证、原子保存和 Notes 关闭确认。

菜单／picker／原生连接 8 项定向测试通过（`/tmp/santty-unified-workspaces-tests.jsonl`）。最终数据格式、旧保存迁移、单写者、发现失败及 picker 往返保留 Notes 和焦点等 18 项通过（`/tmp/santty-unified-workspaces-final-tests.jsonl`）。旧混合占位回本地等 4 项也通过（`/tmp/santty-unified-workspaces-roundtrip-tests.jsonl`）。Standalone build 通过（`/tmp/santty-unified-workspaces-build.jsonl`）。

开发版已启动并保持运行 PID 37215（`/tmp/santty-unified-workspaces-run.jsonl`）。后台 AX 验证启动选择 Default、picker 左下角可用，自动发现 pixcall-ios / Santty；picker 与菜单没有模式入口。Settings → General 验证三个配置字段及 Apply and Refresh Workspaces 按钮（`/tmp/santty-unified-workspaces-general-tree.json`）。未提交真实配置变更或选择真实 backend；实际服务的切换仍由用户验收，隔离 fixture 的原生切换已通过。Settings 窗口保持打开。`git diff --check` 通过。

### 2026-10-12：picker 胶囊外观与 Tab 对齐

原 NSPopUpButton 使用 32pt frame，但系统 roundRect bezel 的可见高度更小。保留原生 popup cell 的文字、图标、菜单及可访问性，覆盖 drawBezel，在完整控件 bounds 内绘制胶囊；系统箭头原本随 bezel 绘制，使用 chevron.up.chevron.down 系统 symbol 补回。圆角复用 WorkspaceTabButtonView.cornerRadius（16pt）。两项 picker 布局／深色可读性和菜单稳定选择测试通过（`/tmp/santty-picker-capsule-tests.jsonl`），构建通过（`/tmp/santty-picker-capsule-build.jsonl`）。

最终开发版 PID 53674，截图 `/tmp/santty-picker-capsule-final.jpg` 确认完整胶囊与相邻 Tab 顶底对齐、箭头可见；AX 及后台点击确认原生菜单可以打开，没有切换 backend 或输入终端命令。`git diff --check` 通过。

用户随后指出箭头被压扁：之前将系统 symbol 强行画入 12×12 正方形，改变了原始纵横比。改为按 NSImage.size 原始尺寸居中绘制，保留字体配置及位置；构建通过（`/tmp/santty-picker-arrow-build.jsonl`）。

修复版 PID 59012，截图 `/tmp/santty-picker-arrow-final.jpg` 确认箭头纵向比例恢复、胶囊保持不变。随后窗口变为不可见，未再次验证下拉交互，未强制激活窗口。

## 2026-10-12 — Unified command palette navigation

- Added Workspace / Tab / Pane / Command categories to the existing AppKit palette. Results include ownership, current selection and pane presentation; explicit pane names take priority. Empty All searches keep panes out of the initial list, while each category can list all its targets. Search matches name and ownership tokens and ranks exact/prefix/substring before fuzzy matches.
- Catalog uses local tabs, parked Default tabs, cached Herdr local auxiliaries and existing management/ClientShell snapshots; it does not launch shells or attach unopened workspaces. Palette-only navigation entries are excluded from CLI command exports. Live refresh runs only while the palette is open, compares visible metadata and preserves query/category/selected identity.
- One cancellable navigation intent waits for the operation gate and committed native layout. Herdr mutations stay on ClientShell; pane focus selects its tab with one request, workspace and tab navigation preserve per-client selection. Targets are revalidated against endpoint, service identity and topology before/after workspace entry. Local hidden/floating panes retain their presentation on focus. Errors appear in the toolbar rather than a sheet.
- Cross-workspace fixture exposed an actor-hop race: a resize can invalidate presentation after the caller checks readiness. Routed ClientShell focus requests now wait for presentation at the send point with cancellation, identity checks and a bounded timeout; no mutation is retried.
- Validation: seven focused tests passed in /tmp/santty-palette-final-tests.jsonl; the eighth integration test passed after refining request-target assertions in /tmp/santty-palette-herdr-final-tests.jsonl. Coverage includes ownership search, same-name ranking, filters, live selection preservation, floating/hidden local targets, removed local tabs, unopened Herdr tabs, another Herdr workspace, cached local Browser recovery, latest navigation intent, changed settings, CLI export compatibility and an existing ClientShell tab/popup regression. Final FlowDeck build succeeded: /tmp/santty-palette-final-build.jsonl. UI verification follows below.

- Background UI verification on development PID 29712 confirmed workspace/tab/pane/command categories, discovered Herdr workspace results, owner subtitles and Current markers. Evidence: /tmp/santty-palette-ui.jpg, /tmp/santty-palette-ui-all-tree.json, /tmp/santty-palette-ui-tabs-verified-tree.json, /tmp/santty-palette-ui-command-tree.json. Palette closed before the attempted search input; automation accidentally typed `creart` into the local fish prompt without Return. No command ran, and input was left untouched to avoid changing user text. Evidence: /tmp/santty-palette-ui-after-search.jpg. Live search, result selection and scrolling were not verified through background UI automation; their filtering/navigation behavior is tested. Results now occupy a scroll area below the category bar, with a layout assertion preventing overlap.

- Final acceptance: all 9 targeted tests passed together in /tmp/santty-palette-acceptance-tests.jsonl, including category/scroll layout isolation. Final normal build recorded at /tmp/santty-palette-final-build.jsonl. SSH remains deferred.

### 2026-10-13：输入回显增量路径与原生 Herdr 对照

对照 Herdr v0.9.3（`2563803dca97c040beaf3dc3acdcb5a3221b4238`）的 `src/client/mod.rs`、`src/client/state.rs::present_surface_patch`、`src/protocol/render_ansi.rs::BlitEncoder` 和 `src/client/terminal_geometry.rs`：原生客户端让普通 pane patch 直接进入增量编码，只输出变化的 cell；尺寸检测独立于每次内容提交。Santty 原路径在每次内容更新时查询 Ghostty 尺寸并等待解析、重写整条变化行，并重复触发标题通知、原生标签栏／workspace picker／焦点和保存任务。

本次改动：缓存已确认的 Ghostty viewport，resize、surface attach/detach 时通过 generation 失效；逐 cell 增量输出并修复宽字符变窄后的覆盖区；仅在 snapshot、布局或 popup 变化时更新原生 UI，连接状态／错误未变时不发送标题通知。普通内容更新允许沿用已提交的相同 boot、projection、输入几何接受键鼠，导航、resize、断连及副作用仍受原有提交校验保护。每个实际提交仍等待 Ghostty 解析，未移除提交边界。

新增 `window-typing` 隔离 fixture，通过真实 socket、WorkspaceViewController、ANSI 编码与 Ghostty in-memory surface 测量。Debug、2400×1200 窗口、90 次交替单字符输入，前 10 次预热，80 次统计；采样点是输入发送到 Ghostty 可读屏幕出现回显，**不是 GPU 上屏或真实 Herdr 服务的端到端延迟**。基线已包含输入资格修正；下表衡量本轮 viewport／增量绘制／UI 去重优化。

| 指标 | 本轮优化前 | 优化后三轮 |
| --- | --- | --- |
| 回显解析 p50 | 8.39 ms | 5.46–5.55 ms |
| 回显解析 p95 | 10.67 ms | 6.42–6.89 ms |
| 场景 offer 到 host commit p50 | 6.36 ms | 3.31–3.33 ms |
| 300 列文本行改一个 cell 的输出 | 365 bytes | 67 bytes |

最终测试追加 100 次间隔约 1 ms 的原生 `insertText`，与渲染并发；fixture 确认全部 190 次输入到达，最终回显正确。Renderer 20 项通过，涵盖真实 Ghostty resize、缓存失效、中文／emoji／窄字符替换及既有图片／链接行为。Session + Renderer 共 72 项中 69 项通过；失败的 divider keyboard preview、legacy whole-window restore、workspace picker round trip 三项在未修改的 Git HEAD 上复跑也失败，legacy restore 的错误表现有波动。恢复优化代码后，输入基准、40 次 tab 切换、popup 与 host staging 共 8 项通过。

原始记录：`/tmp/santty-herdr-typing-before-raw.log`、`/tmp/santty-herdr-typing-chrome.log`、`/tmp/santty-herdr-full-optimized.log`、`/tmp/santty-herdr-head-failures.log`、`/tmp/santty-herdr-typing-final.log`。未重启用户正在运行的客户端或 Herdr 服务，未测物理键盘到屏幕发光的延迟；真实工作负载的卡顿是否全部消失仍需运行优化版确认。

### 2026-10-13：保留 patch 变化区域，跳过未变化 pane

`HerdrShellProjection` 在验证完整个 patch 后，使用有序 surface revision 记录变化行及相交 pane 的最后内容变化。标记随不可变 surface 快照保留，渲染器与自己已提交的 revision 比较；中间帧合并、候选取消不会丢失未绘制的行。全量 surface 重新标记全部内容，boot／projection／几何不匹配时走完整比较。标记是本地数据，不从协议 JSON 解码，也不依赖带 unstable bit 的后端 content_revision 单调递增。

pane 提取共享当前 surface 的 cell 缓冲，通过局部矩形访问行；编码器的长期基线只保留自己 pane 的各行，更新时只复制变化行，避免多个空闲 pane 各自保留整张历史 surface。未变化 pane 在光标、图片及几何也一致且 Ghostty viewport 已确认时，跳过尺寸适配、后台编码、ANSI 写入与解析等待；仍检查显示生命周期并更新输入模式。viewport 校准失效时重置编码基线，防止缩小后回到同一 grid 时漏画已被 Ghostty 截断的 cells。

Debug 基准（各 90 次、前 10 次预热）：600×60 cells 双 pane 的单字符 patch 处理 p50 从 4.58 ms 降至 0.24 ms，p95 从 4.76 ms 降至 0.26 ms。2400×1200 原生窗口的输入至 Ghostty 可读回显 p50 从本轮基线 4.99 ms 降至 2.72–2.74 ms；p95 从 8.19 ms 降至 5.66–6.68 ms。双 pane 原生输入 p50 为 2.41–2.47 ms，无同场景优化前端到端基线。这里不包含 GPU 上屏时间，不能视为 Release 或真实 Herdr 服务的延迟。

验证：新增共享缓冲测试在修复前失败；合并／取消后与完整扫描输出一致，覆盖不同位置的行修改、中文宽字符、光标单独变化、未变化 sibling 的零字节输出、完整帧替换及 reset。单 pane 和双 pane 各验证 190 次输入均到达 fixture；双 pane 检查 sibling 保持附着且文字未变。最终 61 项定向组合中 60 项通过；缩放用例曾观察到异步位置回复晚于写入队列排空，已改为等待本次新回复。组合运行另出现 `InvalidTransition { phase: idle, targetPhase: failed(deinit) }`，来源未定位；最终单独复跑缩放用例通过，不将组合结果记为全绿。

记录：`/tmp/santty-herdr-incremental-encode-before.log`、`/tmp/santty-herdr-incremental-typing-before.log`、`/tmp/santty-herdr-incremental-rows.log`、`/tmp/santty-herdr-incremental-final.log`、`/tmp/santty-herdr-incremental-resize-final.log`。完整 surface 的 projection 仍使用连续 cell 数组，应用 patch 可能触发该数组的写时复制；本次消除的是逐 pane 的全量提取与重复编码。未启用额外 wire codecs，未新增依赖，未重启用户客户端或 Herdr 服务。

### 2026-10-13：后续性能优化方向（优先级 1／2 已推进，验收记录见下文）

当前 Debug 基准中，双 pane 的单字符 patch 处理 p50 已约为 0.24 ms；单 pane 原生输入到可读回显 p50 约 2.7 ms，p95 为 5.66–6.68 ms。两个基准的场景不同，不能相减作为其它阶段的精确耗时。下一轮优先调查投影数据处理和延迟长尾，收益尚未量化，不预设能再次获得同等幅度的提升。

#### 先建立真实场景的阶段测量

- [ ] 用 Release、真实 Herdr 服务建立单 pane、多分屏、大窗口及持续输出／滚屏基线；在相同服务、窗口网格和负载下对照 Herdr 自己的 client。
- [ ] 分别记录收包／解码、MainActor 等待、projection 应用、pane 准备／编码、Ghostty 解析和 host commit 的耗时，统计 p50／p95／p99、分配量、主线程占用及队列积压。沿用现有诊断入口，仅补缺失采样点。
- [ ] 将可读回显、host commit 与 GPU 实际上屏指标分开报告；没有上屏测量时，不把前两者称为键盘到屏幕的延迟。先定位已有缩放用例的间歇性 `InvalidTransition { phase: idle, targetPhase: failed(deinit) }`，再扩大调度或生命周期改动。

#### 优先级 1：减少 projection 的整屏复制和中间状态处理

- 现状（本轮更新）：`HerdrShellFrame` 已使用按行共享的 cell slices，`HerdrShellProjection.receive(patch)` 只写时复制变化行；wire decoder 保留连续 cells 接口。`HerdrClientShellSession.swift` 仍逐条校验、应用 patch 并 publish。
- [x] 测量保留旧快照时每个 patch 的净新增存活堆占用及应用耗时，确认整屏复制成本，采用按行共享存储；未批量应用或跳过中间 patch。
- 预期受益场景：大网格、多 pane、连续高频输出。批处理仍必须依序校验和应用每个 patch，不可丢掉后续 patch 所依赖的基线；不能跨越控制消息、导航、effect 或几何切换重新排序。
- 验收：保留 patch 原子提交、快照不可变、候选取消和完整帧回退语义；对照逐条处理结果，覆盖中途无效 patch、全量帧替换、resize／导航交错及持续输入，比较分配量和 p95／p99。

#### 优先级 2：逐项启用额外的增量协议能力

- 现状（本轮更新）：`HerdrShellHello` 默认请求 reuse／scroll／delta，连接同时检查 welcome capabilities；未协商时使用完整帧／普通 patch。普通 `PaneSurfacePatch` 的含义保持。
- [x] 对照 pinned Herdr 源码并用隔离的真实 0.9.3 服务分别验证 reuse／scroll／delta；全场景更新先 delta 后 reuse，普通 patch 尝试 scroll；未协商继续现有路径。
- [x] reuse／delta 保留共享行和累计 damage；scroll 保留区域操作和残余 spans。分别记录 wire bytes、解码成本与原生可读回显，结论见本轮验收记录，不以压缩比替代延迟。
- 预期受益场景：滚屏、重复内容和适用的增量更新。验收覆盖混合完整帧／patch／额外 codec、重连／基线失效、图片和 popup，并验证未协商能力及无效报文的既有拒绝行为。

#### 优先级 3：减少多 pane 准备的任务调度开销

- 现状（本轮更新）：pane／popup 先在主线程校准 viewport 并产生带显示身份检查的 render request，再使用一个 scene worker 依序编码；输出解析仍有独立屏障。所有目标的 encoder 都可复用时不创建编码任务；socket I/O worker 保持。
- [x] 测量串行 pane 的调度成本，合并同一 scene 的后台编码并对照 p95／p99 与 MainActor 定时器响应。
- [ ] 恢复显示环境后完成快速输入、tab 切换、popup、resize 与 host staging 的原生验收，并复测真实服务回显。
- 验收：保留取消、generation／view 身份校验、viewport 校准、图片错误传播与 Ghostty 解析后的 ACK；覆盖快速输入、tab 切换和 resize 交错。不以盲目并行、主线程编码或提前 ACK 换取较低的测量值。

执行顺序：先补阶段测量，优先验证第 1 项；第 2 项逐能力验证，第 3 项只在调度开销被测量证实时实施。以上是最初文档计划；本轮已实施的内容与验证限制见下面的按行共享记录。


### 2026-10-13：projection 按行共享与 Release 分阶段基准

本轮目标是减少大网格的整屏写时复制，建立真实服务的阶段测量。没有启用 reuse／scroll／delta，没有合并后台任务、提前 ACK 或更改 surface 生命周期。

`HerdrShellFrame` 保存共享的 `ArraySlice` 行；完整帧创建行索引时共享原 cell 缓冲，patch 先完成全部验证，再仅复制变化行。连续 `cells` 访问接口用于既有 wire decoder，renderer 改为直接访问共享行，队列预算计算也不再为了估算大小展平 cells，并计入行索引开销。旧快照、完整帧替换、变化区域标记和候选取消语义保持。新增同一行多个 span 的共享／不可变回归，在修复前失败，修复后通过。

诊断增加 payload 读取、wire decode、MainActor 排队、snapshot／surface／patch 应用、publish、pane／popup 准备、后台编码排队／执行／actor 返回、Ghostty 解析屏障和 host finalize。每项使用最近 1024 个样本的环形缓冲，报告 p50／p95／p99；不会在热路径移除数组首元素。`payloadRead` 包含 socket 等待；`ghosttyBarrier` 包含任务调度和解析等待；panePrepare 与编码阶段重叠，各阶段样本数量不同，不能相加分位数。wire decode 采样不包括之后的 decoded-byte 预算估算。以上均不是 GPU 上屏指标。

#### projection 单独测量

Release，每组 1100 次单 cell patch，前 100 次预热，保留旧 surface，统计 1000 个原始样本，优化前后各三轮。除 cell 存储方式外，诊断与负载相同。堆数据来自 patch 前后 `malloc_zone_statistics.size_in_use` 的差值，报告中位数；这是保留旧快照时的**净新增存活堆占用**，不是累计分配次数、进程峰值或物理内存占用。

| 网格 | 优化前 p95／p99 | 优化后 p95／p99 | 单 patch 净新增堆占用中位数（前 → 后） |
| --- | --- | --- | --- |
| 600×60 | 0.111–0.115／0.118–0.138 ms | 0.0058–0.0070／0.0094–0.0121 ms | 1,442,464 → 27,296 bytes |
| 1200×120 | 0.432–0.468／0.483–0.546 ms | 0.0094–0.0118／0.0136–0.0189 ms | 5,768,352 → 54,432 bytes |

这一结果证明复制从整屏降到变化行与行索引，净新增堆占用减少约 98%–99%。它不能代替真实窗口回显或 GPU 测量。

#### 真实服务测量与限制

新增 opt-in `testRealHerdrServiceTypingAndScrollBenchmark`，通过 `TEST_RUNNER_SANTTY_HERDR_PERF_BINARY` 指定已安装 Herdr。测试启动自己的临时 headless Herdr 服务，隔离 socket、配置和状态目录；关闭版本／manifest 检查，结束时只回收自己创建的服务和工作区。没有连接、重启或停止用户正在使用的服务。`Scripts/herdr-performance-workload.py` 提供原始 PTY 单字符回显及 2000 行连续输出，单 pane、小窗口／大窗口、双 pane 每场景预热 100 次、统计 1000 次。场景使用独立工作区，避免上个场景滚屏后 resize 的历史重排影响采样。

同一字体度量 16×34 pixels、同一窗口与 grid 下，优化前三轮完成输入和滚屏采样；优化后两轮完成三场景，第三轮只完成小窗口。可读回显从输入写入到 Ghostty 可读屏幕，以约 1 ms 轮询观测。

| 场景与 grid | 优化前可读回显 p50／p95／p99 | 优化后前两轮 p50／p95／p99 | 主线程 patch 应用 p95（前 → 后） |
| --- | --- | --- | --- |
| 单 pane 124×34 | 18.08–18.11／22.86–23.25／25.89–27.93 ms | 17.79–17.98／21.13–23.07／22.49–26.58 ms | 0.125–0.138 → 0.047–0.062 ms |
| 大窗口 299×67 | 18.00–18.13／24.94–25.67／27.87–30.50 ms | 17.84–18.08／22.37–23.82／24.71–27.28 ms | 0.339–0.403 → 0.043–0.055 ms |
| 双 pane 301×69 | 18.09–18.11／23.62–24.45／26.71–27.68 ms | 17.93／21.97–22.04／24.18–25.65 ms | 0.405–0.458 → 0.044–0.050 ms |

各完成场景的输入回显和滚屏最终 marker 正确，采样时队列已排空；decoded queue 峰值约 0.18／0.83／0.86–1.68 MB。真实服务 p50 仍约 18 ms；前两轮大窗口／分屏长尾改善，但第三轮未完整完成，不能宣称真实服务整段回显优化已完整验收。也没有量化整个主线程 CPU 占用或累计分配量。

真实服务测试发现已有 `Ghostty host color query is incomplete or retired`：优化前三轮中两轮也失败，优化后前两轮也出现。文字和滚屏采样完成不意味着整个测试通过。失效 surface 的颜色查询失败是否被错误上报仍待定向验证，本轮未做未经证实的生命周期修复。

后期环境出现 `CVDisplayLinkCreateWithCGDisplays error -6661 ... invalid display count (0)`，Ghostty 报 surface 初始化失败，grid 为 nil，原生窗口测试无法启动。对应的 `InvalidTransition ... failed(deinit)` 会掩盖原始失败；缩放测试现在显式报告原始错误，捕获到了 nil grid。本轮没有确认旧缩放日志中的异常也来自同一环境原因。已请求恢复显示器／解锁后再验收；没有强制激活或解锁用户电脑。

Herdr 原生 client 的隔离 PTY 对照探针未完成，已中断并确认清理其子进程，没有有效数据。它原本测的是 native ANSI 字节接收，仍不等于 Ghostty 可读回显或 GPU 上屏，不用于本轮性能结论。

#### 验证与复跑

最终无需显示器的 Release 组合 **56／56 通过**，覆盖 protocol、state、renderer（排除 4 个原生显示用例）、延迟环形缓冲，以及 activation fence、future effects／resize、内容刷新输入资格与导航 ACK 时序。原生输入 fixture 扩大到 1100 次回显 + 100 次并发输入，严格统计 1200 次文字提交；同时允许后台 AppKit 的偶发鼠标 motion，避免错误地将所有输入包都当成文字。早期该 fixture 的单 pane／双 pane 各 1000 样本运行通过；后期三轮重跑因显示器不可用失败，不记为最终全绿。

复跑核心检查使用 FlowDeck Release 加 `ENABLE_TESTABILITY=YES`（只用于测试，正常 Release 构建不需要）。真实服务基准示例：

```bash
rtk proxy flowdeck test -C Release \
  --xcodebuild-options='ENABLE_TESTABILITY=YES' \
  --xcodebuild-env='TEST_RUNNER_SANTTY_HERDR_PERF_BINARY=/absolute/path/to/herdr' \
  --only SanttyTests/HerdrClientShellSessionTests/testRealHerdrServiceTypingAndScrollBenchmark
```

原始记录：`/tmp/santty-projection-copy-before-raw.log`（共享回归修复前失败）、`/tmp/santty-projection-rows-after-raw.log`（共享回归与协议／状态／编码通过）、`/tmp/santty-projection-ab-before-raw.log`、`/tmp/santty-projection-ab-after-raw.log`（三轮对照与失败记录）、`/tmp/santty-projection-colors-probe-raw.log`（display count 0 与原始 nil grid）、`/tmp/santty-projection-core-final-raw.log`（56 项通过）。正常 Release build（未开启 testability）通过，记录：`/tmp/santty-projection-release-build-final.json`。

后续仍需恢复显示环境后完成原生输入、缩放、快速 tab 切换、popup 与 host staging 的最终组合，定位已有颜色查询及旧缩放异常，并补原生 client／GPU 对照。此记录当时第 2／3 项尚未实施；第 2 项的后续推进见下文，第 3 项仍延后。

### 2026-10-13：优先级 2 — 协商增量 codecs 并保留变化信息

对照 pinned Herdr `2563803dca97c040beaf3dc3acdcb5a3221b4238` 的 `endpoint.rs`、`render_stream.rs` 和三个 codec 实现，用安装的 Herdr 0.9.3 在独立临时 socket／config／state 上分别请求 legacy、reuse、scroll、delta、全部能力。完整场景优先 delta，再尝试 reuse；普通 pane patch 尝试 scroll。默认 hello 请求三项，但只接受请求且 welcome 明确支持的 codec；缺少能力时使用完整帧／普通 patch，不根据版本字符串猜测支持情况。

连接 worker 的基线改为共享 `HerdrShellFrame` 行。reuse 只替换 metadata；delta 写时复制 sparse spans 所触及的行，popup 基线独立；scroll 保留经过校验的区域操作和残余 spans，投影依次应用区域行序和 spans，不再生成每个移动 cell 的展开 patch。整行滚动交换共享 slices；带边框／分屏的局部滚动按上游交换规则计算最终行序，每个受影响行只写一次局部 span。

解码产生的累计行／pane damage 进入 projection 和 renderer；每次完整帧建立新的 damage origin，reuse／delta 在同一基线内跨 projection revision 保留变化信息。编码候选取消或被合并不能消费未提交的变化；boot、origin、几何、链接变化仍触发比较。popup 不采用主网格的行标记，避免相同高度时漏绘。共享 cells 的 hyperlink 最大索引和符号字节数按行缓存；metadata 链接表变化仍重新校验索引，新增 wire cells 仍受 reader／字符串预算限制。完整帧、非法 spans／区域／链接、重连和基线丢失保留拒绝和原子提交行为。

诊断新增 `surfaceTraffic`，按 full／patch／reuse／scroll／delta 记录报文数、载荷 bytes、保守估算的 decoded bytes，以及 `wireDecode.<codec>` 分阶段延迟。decoded bytes 包含共享存储的保守收费，不代表实际分配量；decode 阶段不含之后的队列预算估算，也不能代替可读回显或 GPU 上屏。

#### 真实报文与解码基准

隔离服务的 120×30 负载依次做 10 次 metadata rename、70 行不同内容滚屏、resize 为 140×35 和最终 `X` 回显。全部能力场景额外创建右侧 pane，验证局部滚动和最终 pane 回显。legacy 没有任何额外 codec；分别请求时对应 codec 确实出现，未请求的 codec 均未出现；全部请求时观察到 delta＋scroll，符合上游选择顺序。

| 请求能力 | 全量 surface 数／载荷 | 增量报文数／载荷 | 普通 patch 数／载荷 |
| --- | --- | --- | --- |
| legacy | 13／337,915 B | 无 | 72／745,331 B |
| reuse | 3／85,145 B | reuse 10／7,437 B | 71／745,219 B |
| scroll | 13／337,915 B | scroll 41／75,355 B | 30／42,712 B |
| delta | 2／59,868 B | delta 11／1,452 B | 71／745,219 B |

以上只比较 surface 类报文，不含 snapshot／control，不能将各 profile 的所有网络流量直接相减。scroll 将本负载的 patch＋scroll 载荷减少约 84%；单纯每行仅数字不同的负载曾不产生 scroll，因为 sparse patch 已更小，这是服务的收益选择。

Release reuse 微基准每种尺寸 100 次预热、1000 次样本；消息 JSON 创建不在 decode 计时内，报文带独立 popup／graphics metadata。原实现每次展平／恢复／校验整屏，新的实现共享行：

| 主网格 | wire JSON | 原解码 p50／p95／p99 | 共享行解码 p50／p95／p99（首轮） |
| --- | --- | --- | --- |
| 600×60 | 2,508 B | 0.906／0.974／1.010 ms | 0.089／0.098／0.136 ms |
| 1200×120 | 2,510 B | 3.474／3.610／3.695 ms | 0.089／0.107／0.155 ms |

实际捕获报文另经过 wire → connection decoder → projection → 每个 pane／popup renderer 回放，每次 ANSI 输出与清除 damage 后完整扫描的参考输出逐字节比较。此回放的 codec decoder 计时不含前面的 wire 解析，也不含 Ghostty，单一 codec 的样本较少，仅用于诊断和 correctness，不当成长期延迟基准。初版局部 scroll 重复复制行导致 decoder p95 从约 0.094 ms 增到 0.12 ms，随后改为最终行序的一次写入；最终数据与原生验收结果在下文记录。

复跑捕获与回放：

```bash
rtk proxy python3 Scripts/herdr-codec-capture.py /absolute/path/to/herdr /tmp/santty-codecs.json
rtk proxy flowdeck test -C Release \
  --xcodebuild-options='ENABLE_TESTABILITY=YES' \
  --xcodebuild-env='TEST_RUNNER_SANTTY_HERDR_CODEC_CAPTURE=/tmp/santty-codecs.json' \
  --only SanttyTests/HerdrClientShellProtocolTests/testCapturedRealServiceCodecsMatchUnhintedRendering
```

捕获脚本只管理自己的子服务，退出清理临时目录，不连接用户的服务；基准使用已安装二进制，不升级／重启用户的客户端或服务。回放测试未设置环境变量时明确 skip。


#### 最终解码与原生回归

最终 Release 组合 **72／72 通过，0 skip**。包括五种真实捕获 profile 的逐帧 ANSI 差分、全部协议／状态／编码测试、四项真实 Ghostty 文字／图片／宽字符／resize、快速及反复 tab 切换、popup 输入与焦点恢复、显示失效后重新 ACK、activation／future effects／导航时序，以及单 pane／双 pane 各 1100 次回显＋100 次并发输入。混合 reuse／delta／scroll 的图片替换与 popup 编辑另加入有／无 damage 的输出差分；未变化行地址和旧快照不变；局部／整行上下 1–4 行的行序与上游逐 cell swap 模型一致。

最终 reuse 微基准的 p50／p95／p99：600×60 为 0.085／0.087／0.088 ms，1200×120 为 0.084／0.087／0.088 ms。相同真实报文 profile 的 codec decoder p95：reuse 0.466 → 0.345 ms（10 条）、delta 0.135 → 0.0175 ms（11 条）、scroll 0.096 → 0.0795 ms（41 条）。这些少量真实样本不用于推算整段回显；全部能力 profile 后来增加分屏，不能直接与早期未分屏捕获的 p95 比较。

原生 fixture 的单 pane／双 pane 可读回显 p50／p95／p99 分别为 2.009／3.666／4.523 ms、1.700／3.674／4.455 ms；fixture welcome 未提供额外能力，用于验证默认请求后回退路径及输入不会丢失。fixture 修复了后台鼠标 motion 命中未聚焦 sibling 时错误退出的问题，仅允许当前可见 pane 的 motion，文字仍严格验证聚焦目标并计数 1200。

真实 Herdr A/B 使用同一 16×34 px cell、124×34／299×67／301×69 网格，仍是各 100 次预热＋1000 次样本。关闭 codecs 的单独运行和开启 codecs 的组合运行都完成最终文字与 2000 行输出 marker，但都在大窗口结束时观察到已有 `Ghostty host color query is incomplete or retired`，所以真实服务 benchmark 整项仍失败。组合运行的输入长尾没有改善，不能将 wire／解码收益当成原生输入收益；另做开启 codecs 的单独运行减少前序窗口测试的干扰，结果如下。


| 真实服务场景 | codecs 关闭（单独运行）p50／p95／p99 | codecs 开启（单独运行）p50／p95／p99 | 2000 行输出 marker，关闭 → 开启 |
| --- | --- | --- | --- |
| 单 pane 124×34 | 17.877／20.955／22.557 ms | 17.936／23.123／27.108 ms | 53.27 → 71.88 ms |
| 大窗口 299×67 | 17.927／23.522／26.348 ms | 18.109／25.338／29.828 ms | 70.02 → 55.65 ms |
| 分屏 301×69 | 17.754／21.960／24.656 ms | 18.071／23.629／26.956 ms | 70.38 → 63.68 ms |

每种配置只有一轮单独运行，不能归因为某个阶段的精确因果效应，但两次开启运行都没有改善输入长尾。普通 patch 为后续额外 codec 维护连接基线，wireDecode p95 从约 0.030–0.038 ms 增到 0.104–0.123 ms；完整／metadata 更新节省载荷并不意味着频繁单字符 patch 更快。原生 typing 负载主要是普通 patch，2000 行 burst 中也没有选中 scroll；不同字符行的独立捕获才稳定触发 scroll。当前默认开启三项的收益适用于 metadata、稀疏全场景更新和适合压缩的滚动；真实输入长尾与已有颜色查询失败仍需后续单独调查。本轮未扩大调度或修改颜色查询生命周期，未测 GPU 上屏。

最终正常 Release build（未开启 testability）通过，Python 脚本语法和 `git diff --check` 通过。原始记录：`/tmp/santty-codecs-before-raw.log`（共享回归在修复前失败）、`/tmp/santty-codecs-capture-final.json`／`/tmp/santty-codecs-capture-final.log`（真实报文和计数）、`/tmp/santty-codecs-replay-before-raw.log`（旧解码器差分／时序）、`/tmp/santty-codecs-core-final-raw.log`（72 项通过）、`/tmp/santty-codecs-native-before-raw.log`、`/tmp/santty-codecs-acceptance-raw.log`、`/tmp/santty-codecs-native-isolated-after-raw.log`（真实 A/B 与颜色查询失败）、`/tmp/santty-codecs-release-build-final.json`（正常 Release）。以上临时记录未入库，可通过文中的脚本和 FlowDeck 命令重建；此记录时优先级 3 尚未实施，后续推进见下文。


### 2026-10-13：优先级 3 — 同一 scene 合并后台编码（原生验收待完成）

此前真实服务样本中 encodeQueue p99 约 0.17–0.34 ms、encodeActorResume p99 约 0.10–0.15 ms；与 panePrepare／Ghostty 解析屏障相比仍很小，不能断定它们是输入长尾的主因。多 pane 同时变化时，每个 pane 都创建 worker 并返回主线程，调度次数随变化 pane 数增加。本轮目标是降低这段成本，不将上一轮颜色查询异常或输入长尾归因到这里。

`TerminalPaneController` 与 popup 先生成 render request：主线程完成 AppKit 布局、viewport 校准与显示 epoch／generation／session 检查，保存各自的不可变 renderer 候选。多个 host 的 request 收集之间协作让出 MainActor，再检查取消与 session 身份，保留处理待定输入的机会。窗口收齐当前 scene 的 request 后，`prepareScene` 在一个后台任务里依序编码各 pane／popup，保留每个 surface 的图片 ID 命名空间。所有目标的 encoder 都可复用时直接返回零 bytes、不创建编码 worker。输出预算在后台按 batch 累计检查；任何 pane 失败或取消都不会返回可提交批次，也不推进现有 renderer。

worker 返回后检查任务取消、session／scene 身份和每个 request 的 isCurrent；commit 仍再次验证显示身份。全部 ANSI 输出交给原有 Ghostty session 后，等待原来的解析屏障；随后再次检查 scene、candidate、popup、floating view 身份，再 finalize 和 ACK。未并行访问 AppKit、未将编码移到主线程、未改变 viewport 校准或提前 ACK，也未合并颜色查询／viewport／解析等待的任务。

诊断拆为 paneViewport／popupViewport（各 host 的校准与 request 准备）、scenePrepare（整 scene 的 viewport＋编码准备）。encodeQueue／encode／encodeActorResume 现在每个有变化 scene 采样一次，而不是每个变化 pane；阶段仍有重叠，分位数不能相加，也不与旧 panePrepare 直接比较。

新增差分检查覆盖两个 pane 同时变更、中文宽字符、全部未变化 scene 的无 worker 路径、后续 pane 图片错误导致整批次失败、取消及取消的无变化 scene、显示身份在编码完成后失效而拒绝 commit，以及 pane／popup 各自图片命名空间。候选结果与逐 pane 同步参考编码逐字节相等，失败后重试与未失败候选一致。

#### 测量方法

Release，1200×60 主网格，1／2／8 pane，每个 pane 每次改一个 cell；100 次预热＋1000 次记录，串行和 scene 模式在同一个构建内依次运行。串行模式对每个 pane 调用单目标 prepare（各一个 worker），scene 模式一次提交所有目标。输入每 60 行循环时切换 X／Y，确保测量区间每次确实变化。记录整批准备的 p50／p95／p99；MainActor 上另有 1 ms 协作定时器，记录实际 tick 间隔，用于观察 actor 能否在后台编码时继续运行，不代表物理键盘到屏幕、CPU profiler 或 GPU 上屏。

初始探针在预热后重复了相同字符，虽然仍反映了 row damage 下的任务调度，但不属于持续真实改单元格的数据；不采用其 0.283 → 0.069 ms 的 8 pane 结果作为正式收益。以下只使用修正后的同构对照。

#### 三轮准备耗时对照

表中为三次独立测试运行的分位数范围，单位 ms；只含候选准备，不含 projection 应用、AppKit viewport 校准、Ghostty 解析或 ACK。

| pane 数 | 串行准备 p50／p95／p99 | scene 准备 p50／p95／p99 |
| --- | --- | --- |
| 1 | 0.061／0.079–0.082／0.093–0.095 | 0.060–0.061／0.078–0.081／0.094 |
| 2 | 0.097–0.099／0.124–0.126／0.150–0.159 | 0.068–0.069／0.085–0.091／0.097–0.101 |
| 8 | 0.295–0.301／0.346–0.371／0.388–0.420 | 0.093–0.094／0.117／0.121–0.127 |

单 pane 基本持平；8 pane 的准备 p95／p99 约减少 66%–70%，支持减少同一 scene 的编码调度。串行模式仍在本轮实现中逐目标调用 prepare，因此这是同构任务组织对照，不是整个旧应用与新应用的端到端 A/B。

8 pane 的 MainActor tick p95 为 1.082–1.090 → 1.133–1.144 ms，p99 为 1.092–1.119 → 1.144–1.152 ms；两种模式定时器都持续运行，scene 模式的 tick p95 略增约 0.05 ms，不能宣称主线程响应改善。每轮 tick 样本数分别为 315–323 和 111–113，少于准备耗时的 1000 样本。生产路径另在多个 host 校准之间保留 `Task.yield()`；这一 AppKit 路径没有包含在纯编码对照中。

最终核心组合运行也重复执行了该基准：8 pane p95／p99 为 0.337／0.377 → 0.112／0.168 ms，收益方向相同，scene p99 比独立三轮更高。测试仅检查输出正确和定时器仍能运行，不以不稳定的时间阈值作为通过条件。

随后仅将测试共享状态放入 MainActor 隔离对象，清除新增的可变捕获警告；四个新增用例重跑 **4／4 通过**。该次 8 pane p95／p99 为 0.338／0.371 → 0.118／0.153 ms，tick p95 为 1.078 → 1.146 ms，继续支持准备成本下降但主线程定时器没有变快的结论。

#### 验证与待完成原生验收

最终无需显示器的 Release 组合 **66／66 通过，0 skip**：protocol（含真实捕获 codec 回放）、state、renderer（明确排除 4 个原生显示用例），以及内容刷新／held releases、pinned ACK、future effects／resize、显示失效和导航 ACK 时序。新增的批次差分、取消、失败不提交、显示身份失效与图片命名空间检查均通过。

本轮尝试的两个原生用例 `testNativePaneRendersFromWindowSessionWithoutStartingDirectBridge` 和 `testSamePaneCandidatePreservesOldNativeDisplayAndStableIdentityUntilPromotion` 失败。日志同时报告 `CVDisplayLinkCreateWithCGDisplays ... invalid display count (0)`，Ghostty 无法创建 surface，随后出现 nil prepared render／InvalidTransition；因此不能视为原生验收通过，也不能用这些失败证明调度改动导致了原生回归。已请求恢复显示连接／解锁，没有操作用户正在使用的窗口、服务或解锁电脑。

尚未完成快速输入、tab 切换、popup、resize 与 host staging 的最终原生组合，以及本轮真实服务可读回显对照；上一轮的原生通过结果不能代替本轮验收。没有测 GPU 上屏，也未修复或重新归因已有颜色查询异常。

复跑纯编码对照：

```bash
rtk proxy flowdeck test -C Release \
  --xcodebuild-options='ENABLE_TESTABILITY=YES' \
  --only SanttyTests/HerdrClientShellRendererTests/testScenePreparationBenchmark \
  --only SanttyTests/HerdrClientShellRendererTests/testSceneEncodingMatchesIndependentPanesAndDoesNotCommitFailedOrCancelledCandidates \
  --only SanttyTests/HerdrClientShellRendererTests/testSceneRequestRejectsOutputAfterItsDisplayIdentityChanges \
  --only SanttyTests/HerdrClientShellRendererTests/testSceneBatchKeepsPopupAndPaneImageNamespacesIndependent
```

正常 Release build（未开启 testability）及 `git diff --check` 通过，构建记录为 `/tmp/santty-scene-release-build-final.json`。

原始记录：`/tmp/santty-scene-benchmark-round1-raw.log`、`/tmp/santty-scene-benchmark-round2-raw.log`、`/tmp/santty-scene-benchmark-round3-raw.log`（修正后的三轮同构对照）、`/tmp/santty-scene-core-final-raw.log`（66 项通过及组合运行基准）、`/tmp/santty-scene-warning-cleanup-raw.log`（测试捕获警告修正后 4 项通过）、`/tmp/santty-scene-first-raw.log`（原生失败与 display count 0；其中初始基准不用于正式结论）。以上为未入库的临时记录，可通过测试重建。
