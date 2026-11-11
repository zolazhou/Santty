# Santty 与 herdr-app 共享 herdr-core：调查与建议

## 目标补充：移动端接续工作区

后续明确的目标是：在 Herdr 移动端继续 Santty 的工作环境，包括 workspace/tab/terminal 的组织，而不只是访问终端池。对这个目标，应采用下文“共享工作区方案”；仅布局独立的方案不足以满足需求。

## 当前实现：阶段一协议基础（尚未启用工作区同步）

新增：

- `HerdrWorkspaceDocument.swift`：保留未知 JSON 字段/节点的文档模型，受限的插入 space、按预期旧名重命名操作；无删除/kill 或整份替换接口。
- `HerdrWorkspaceProjection.swift`：稳定 UUID 映射、现有 Herdr 终端绑定和 row/column 权重转换；拒绝 Local PTY、外部 viewer、模糊 run、混合/浮动/隐藏/auto-resize 布局，不丢弃它们后继续导出。Herdr labels 仅返回为 intent，没有自动写入。
- `HerdrWorkspaceDocumentStore.swift`：按永久 core ID 访问本地或远程文档；保留 revision/tombstone，CAS 冲突不自动重试，旧连接 snapshot 不可回写。
- `HerdrCoreClient.workspaceDocumentsGeneration`：doc/missed/reconnect/disconnect 的刷新信号；不是 core revision。doc 事件不带 terminal address，已在 terminal-only 分发之前处理。
- `HerdrWorkspaceDocumentTests.swift` 与 synthetic fixture：codec、投影、两个独立客户端、真实隔离 core 的 CAS、事件失效、连接更换和远程路由/改别名验证。
- `Scripts/check-herdr-workspace-schema.sh`：下载且校验固定上游提交，使用未修改的 Rust 模块验证 fixture。只在临时目录编译 serde probe；不启动 App/core，不读取用户 workspace。

格式已由 `herdrdev/herdr-app` v0.1.14、commit `2405bf388c568c3ed479f05b8e405ccfa44b3f2c` 的 `src/mirror.rs` / `src/layout.rs` / `src/mirror_sync.rs` 核实。实际运行的上游 `Document → Model → Document` 验证通过：1 space、1 tab、2 terminal，JSON 值无损往返。

**未完成**：移动端实机互通、共享工作区 opt-in UI、本地 sidecar/ID 映射持久化、双向结构操作、pending intent/labels 的事务协调、共享关闭语义、多 viewer 尺寸与自动应答。当前基础层没有接管 `SavedWorkspace`，没有改动 v10、writer lock 或既有工作区的保存/关闭行为。

验证结果：`Scripts/check-herdr-workspace-schema.sh` 通过；FlowDeck 已构建并运行文档、transport、settings、Herdr workspace、agent 相关共 31 项测试，全部通过（9 项为新增文档/投影/隔离集成测试）。真实 core 测试使用独立 HC session/socket 与临时 XDG 路径，程序和 Herdr labels 也只在隔离 fixture 内创建，测试后清理；没有修改用户默认 core。

复跑相关测试：

```sh
flowdeck test --only SanttyTests/HerdrWorkspaceDocumentTests \
  --only SanttyTests/HerdrWorkspaceDocumentIntegrationTests \
  --only SanttyTests/HerdrCoreTransportTests --only SanttyTests/HerdrSettingsTests \
  --only SanttyTests/HerdrWorkspaceTests --only SanttyTests/AgentSessionTests --json
```

下一步先用手机验证兼容文档的发现、预览及交互；通过后再让显式选择共享的 workspace 采用 core 文档作为结构来源。不要把当前分屏投影直接接到全局自动保存回调。

## 已执行：一次性把 Santty workspaces 发布到 herdr-core（2026-11-11）

按用户选择（全部 workspace）执行，herdr-app 当时未运行。当时用一次性脚本（`prepare` 只读、`apply` 消费冻结计划）完成，脚本用完即删除，不进仓库：后续由应用内的双向同步负责，见上一节。

结果：

| core | 文档 revision | spaces | tabs | terminals |
| --- | --- | --- | --- | --- |
| `zolas-macbook-pro`（本机 `3c437dc572b0f559119cd9dfdba82dac`） | 23 → 24 | 3（pixlabs, config, zola） | 8 | 18 |
| `dellpc`（`36b8c7e798d1101039b088cd3c0b11c1`） | 1 → 2 | 1 | 1 | 1 |

- 写入前用 `doc.get` 取 revision，`doc.set` 带版本比较；两个文档均按永久 core ID 路由，远程文档经本地代理写到 dellpc 自己的文档。
- 同时写入 `herdr.space` / `herdr.tab` 两个标签，使这些终端被 Herdr 收纳。19 个终端进入 Santty 的 space/tab。
- 4 个只存在于旧 Herdr 布局、且不属于任何 Santty workspace 的终端（本地 `t9`、`t21`、`t22`，远程 `t1`）被移除工作区标签：它们仍在运行，只是不再被 Herdr 收纳。
- 没有创建、结束或重启任何程序；PID 与 `live` 状态在发布前后一致。除上述两个标签外，其他标签未改动。
- 设备本地状态未上传：选中 tab、焦点、zoom、窗口尺寸、侧边栏、以及 9 个 tab 的 auto-resize 偏好仍只在 Santty 的 v10 文件里。

备份与审计（目录权限 0700，文件 0600）：

```text
~/Library/Application Support/Santty/Workspace/HerdrBackups/<UTC>-<随机>/
  source-workspace.json          发布所用的 Santty 快照
  <core>-before.json             旧文档及其 revision
  <core>-proposed.json           发送的文档
  <core>-terminals-before.json   受影响终端的 PID/状态/标签
  <core>-after.json              校验后的文档
  plan.json                      冻结计划（含源快照 SHA-256）
  journal.jsonl                  写入尝试/完成/校验记录
```

校验：`Scripts/check-herdr-workspace-schema.sh <doc.get 的 value>` 用未修改的上游 v0.1.14 模型解析两个已发布文档，结构一致：3/8/18 与 1/1/1。注意上游 `layout.rs` 把 `weight` 存成 `f32`，所以 64 位浮点权重读回会变成 f32 精度（例如 `0.48333333333333334` → `0.4833333194255829`）；脚本按 f32 容差比较，这不是结构损坏。

已知限制：

- 这是一次性快照。之后 Santty 里新增、拆分、重命名或关闭 pane **不会**自动反映到 core 文档，反之亦然；连续同步仍需上文“同步与冲突”的实现。
- 发布时快照与执行之间若发生结构变化，工具会拒绝执行；实际执行后发现 Santty 只更新了标题/cwd，结构未变。
- 发布值是 Santty 的布局快照，因此 Herm 侧之后的任何结构编辑都会产生新的 revision；再次发布需要重新 `prepare`，不能沿用旧计划。

下一步：（1）在手机/桌面 Herdr 中确认三个 space 与 8 个 tab 能正确显示并进入原程序；（2）确认关闭语义（Herdr 关闭 pane 会结束程序）符合预期；（3）再实现双向同步与 opt-in UI。

## 双向同步已实现（2026-11-11）

`HerdrWorkspaceSync.swift` + `HerdrWorkspaceSharing.swift` + `HerdrWorkspaceDocument.setSpace/removeSpace`：

- 编辑以 `base / local / remote` 三方按 tab 合并；只写差异，写前读最新 revision。合并幂等，doc 事件不会引发写入循环。
- 本地改动（重命名、拆分、关闭、标签）在防抖后发布；远端改动（Herdr 桌面或手机）被采纳到对应 workspace，已有 pane 复用控制器与进程，新 pane 建成只读外部 viewer。
- 冲突：两侧都改同一 tab 时保留文档版本，并在工具栏报告；一侧删除、另一侧修改时保留存活副本并报告。
- 单侧删除且另一侧未改：删除。文档中整个 space 被删除时不在本地重建，避免复活。
- 布局删除**不会**结束程序；只有显式关闭 pane/tab/workspace 才 kill。
- 发布同时维护 `herdr.space` / `herdr.tab`；离开共享结构时清除这两个标签（不动其他标签）。
- 本地无法精确表达（浮动/隐藏 pane、混合类型、外部 viewer 工作区）时整个 workspace 跳过，不发布残缺结构。
- 偏好开关 `Settings → Herdr → Share workspaces with Herdr`（默认关闭，`herdr.shareWorkspaces`）。关闭时新代码完全不运行。

测试：`HerdrWorkspaceMergeTests`（合并、身份、适配器、文档操作）与 `HerdrWorkspaceSharingIntegrationTests`（真实隔离 core 的本地发布 → 远端改名采纳 → 本地拆分发布 → 远端删 pane 采纳且程序存活、标签清除 → 远端删 space 不复活）。全量 `flowdeck test`：362 passed / 1 skipped / 0 failed。

已知边界：尚无逐 pane 的并发合并（粒度是 tab）；发布的是 Santty 侧结构，因此 Herdr 的 mod pane 等 Santty 无法表达的内容会让该 workspace 停止参与同步；移动端未实机验证。

## 初步结论：仅共享 core 时

推荐保留现有 `hc connect` 架构：两个 App 分别作为同一个 core 的客户端，布局各自管理；需要时以外部 viewer 打开对方的终端。无需把 herdr-core 嵌入 Santty，也无需通过 herdr-app 的 UI socket 转发终端数据。

“共享 core”“共享同一终端”“同步整个工作区布局”是三个不同目标：第一项现有架构已支持；第二项已有部分基础，需补通用入口并验证多 viewer；第三项不建议作为首期目标。

## 已核实的现状

### 安装与运行

本机调查时：

- `hc`：0.1.19；`herdr-app`：0.1.14；协议 generation 1。
- `~/.local/bin/hc` 与 `herdr-core` 指向同一个用户级安装。
- Santty 进程的子进程是 `~/.local/bin/hc connect`。通过 `lsof -a -p <pid> -U`，确认它连接到 `~/.local/state/herdr-core/default/default.sock`。
- 同时打开两个独立的 `hc connect`，只调用 `hello` / `server.status`：helper PID 不同，但 core ID、server PID 完全一致。这些 helper 是传输桥，不是各自的 daemon。
- 默认 core 的持久化终端中同时存在 `santty-pane` 和 `herdr.space` / `herdr.tab` 标签，且有 `herdr-app` 文档。这说明两种客户端的数据已在同一个 core 中共存。
- `herdr-app status` 返回没有可连接的窗口；没有启动、聚焦或改动 Herdr 窗口。因此尚未完成两个 GUI 同时打开同一终端的验证。

单个 core 可以有多个 holder。`hc server status` 明确区分 current holder 与旧版本 draining holder；多个 `hold` 进程不等于多个独立 core。

### Santty

- `Santty/Sources/Herdr/HerdrCoreTransport.swift`
  - 启动 `hc connect`，继承环境，协商 framed RPC。
  - `close()` 结束自己的 helper，不调用 `server.stop`。
- `Santty/Sources/Herdr/HerdrCoreClient.swift`
  - 共用一个连接，订阅全量终端元数据与远程机器。
  - 保存并检查永久 core ID；替换连接先验证新连接，再断开旧连接。
  - 当前 session 来自 `HC_SESSION`，没有独立 session 设置。
- `Santty/Sources/Herdr/HerdrTerminalSession.swift`
  - 新终端使用 `santty-pane=<UUID>` 标签和 `keep: true`。
  - 自己创建的终端：显式关闭 pane 会 kill；隐藏、切换、退出 App 则 detach。
  - `viewerOnly` 的外部终端：显式关闭也只 detach，不 kill，不创建替代 shell。
  - **`viewerOnly` 不是只读模式**：现有 attach 不传 `observe: true`，仍可输入、提交尺寸和 display facts。
- `Santty/Sources/Workspace/WorkspaceViewController.swift` 的 `navigateToAgent`
  - 已能导航到现有 pane，或为外部 agent 创建持久化的 viewer pane。
  - 这条入口围绕 agent；尚不是任意 shell/终端的通用选择器。

### herdr-app

安装指南 `~/.config/herdr-app/AGENTS.md` 与 `herdr-app --skill` 明确说明：

- App 是 herdr-core 的一个客户端；关窗口不结束程序。
- 没有 Herdr 标签的其他 App 终端，默认不进入它的 spaces/tabs。
- `herdr.space` / `herdr.tab` 标签可让外部创建的终端被 Herdr 收纳。
- 关闭 Herdr 的 terminal pane 会结束该终端；共享终端不代表关闭动作只影响当前窗口。
- spaces/tabs/splits 存在 core 的 `herdr-app` 文档；多个 Herdr 屏幕共享结构，不共享焦点、zoom、attention。
- App 更新后可能更新同 generation 的 core；Santty 必须容忍共享 core 更新与重连，不能把 daemon 生命周期当作自己独占。

## 方案比较

| 方案 | 成本与风险 | 建议 |
| --- | --- | --- |
| 同一 core，布局独立、终端按需互看 | 复用现有连接和 binding；主要补发现入口、viewer 策略和测试 | 首选 |
| 自动把 Santty 终端都加上 Herdr 标签 | 会改变 Herdr 布局，并引入任一端 close 都可能 kill 的行为 | 不默认启用；如需要，仅显式导出 |
| Santty 直接读写 `herdr-app` 布局文档 | 要兼容私有布局 schema、mod pane、版本冲突及双向删除语义 | 不建议首期做 |
| Santty 通过 herdr-app UI socket 操作终端 | 依赖窗口存活，多一层转发，还会耦合焦点与布局 | 不采用 |
| Santty 自带/另起专属 core | 反而隔离终端池、远程机器和 agent 状态 | 不符合目标 |

## 推荐实施顺序

### P0：固定并显示连接目标

1. 继续使用用户安装的 `hc`，不打包另一个 core，不安装、不自动升级、不停服。
2. 在 Herdr 设置中明确展示当前 core ID、版本、session，并说明这是共享服务。
3. 连接目标由 `HOME`、`HC_SESSION`、`HC_SOCKET` 和相关 XDG 路径共同影响；同一可执行文件不保证同一 core，不同路径的可执行文件也不必然是不同 core。
4. 如需可配置 session，再增加显式 `hc connect --session ...`；先定义它与环境、`HC_SOCKET` 的优先级和冲突校验。不要未经确认就清除用户现有 HC/XDG 配置。
5. 切换 core 后，旧 binding 继续按 core ID 拒绝错误重附着；不凭相同 `t7` 地址替换身份。

只要求“共用后台服务”时，到此即足够，不必先做工作区同步。

### P1：增加“打开现有 Herdr 终端”

- 使用 `terminal.list` / 现有 metadata store，列出本地及已连接远程 core 的终端，不限于报告 agent 状态的程序。
- 选择后复用 binding 导航逻辑：已有 pane 则定位，否则创建外部 viewer，持久化 `herdrViewer`。
- 默认不修改终端标签，不导入对方布局，不把外部终端变成 Santty 所有。
- UI 明确区分“关闭此视图”和“结束共享终端”；前者只 detach，后者必须是独立、明确确认的操作。
- 双方自己的终端可以保持原有 close=kill 行为，但需要告知用户另一端的 viewer 也会结束。

### P2：验证多 viewer，并按结果完善模式

`hc schema` 的 `terminal.attach` 已提供：

- `observe: true`：只看，不输入、不改尺寸。
- `resize_notifications: true`：observer 能处理 core 发来的 RESIZE，再接收 replacement paint。
- 返回的 `resize_notifications` / `automatic_input` 表示整条路径的实际能力，远程代理不能只看本地 core 的能力。
- `resumed: true`：重连后仅在重新 active 时设置尺寸。

建议把“是否拥有关闭权”和“是否可交互”拆开：`viewerOnly` 继续描述生命周期；另设 observe/interactive 的 attach 策略。不要把现有 interactive viewer 无声改成只读。

需要重点验证的静态风险：

- 当前 output consumer 仅处理 DATA/CLOSE，其余 frame 忽略；attach 不请求 resize notifications。
- `events` 的 size 更新会刷新 record，但没有把 core 尺寸同步给 Ghostty 的独立渲染网格。
- 本地 viewport 变化仍发送 RESIZE；focus/display facts 也可能影响 core 的 active viewer/显示状态。
- 同一终端只能有一套 PTY 尺寸。两个不同尺寸窗口如何显示、谁取得尺寸控制权，需要协议行为或隔离实验确定。
- 终端自动应答与人的输入目前都走 DATA；应核实多 viewer 时是否需要 `automatic_input` 能力，避免两个模拟器重复应答查询。

这些是实现缺口/风险，不是已经复现的双端显示故障。先做隔离 PoC，再决定：只读 viewer 固定 core 网格并留白/滚动，还是支持可交互的尺寸接管。不能只设置 `observe` 就声称只读渲染已完整支持。

### P3（可选）：显式“在 Herdr 中显示”

用户选择目标 Herdr space/tab 后，才写 `herdr.space` / `herdr.tab` 标签。不要把 Santty workspace UUID 直接当作已有 Herdr ID，也不要覆盖它的 `herdr-app` 文档。

需要明确：这属于让 Herdr 收纳终端，不是只读镜像；Herdr pane close 会 kill。反向取消收纳也需检查 `terminal.park` 对 keep 的影响，不能在另一个客户端仍依赖 keep 时盲目调用。

## 验收与未决项

在专用 `HC_SESSION`、`HC_SOCKET` 和临时 XDG 路径下测试，不操作用户默认 core：

1. 两个独立连接返回同一个 core ID/PID；断开任意连接，另一个与程序继续存活。
2. 同一终端被两个连接 attach，双方获得输出；一个 viewer 不返 credit，不阻塞另一个。
3. 外部 viewer 的 pane/tab/workspace close 只 detach；自己创建终端的显式 close 仍 kill。
4. 两种不同窗口尺寸、切换 active viewer、只读观察、全屏 TUI、Scroll Mode、自动应答，不出现 resize 循环或重复控制输入。
5. 远程代理路径的 capability 降级、断线重连、missed snapshot、core 更新；不重放输入或模糊 run。
6. core ID 改变时拒绝旧绑定；相同本地地址不视为相同终端。
7. Herdr 默认不收纳无标签终端；显式收纳后验证关闭的跨客户端影响。

已有 `HerdrCoreTransportTests` 覆盖同一连接多 stream、背压和 detach；还需补独立连接及多 GUI 场景。初次调查只进行了源码、安装指南、schema 和只读连接检查；后续协议实现与已运行测试见上方“当前实现”。调查和实现均未改动用户默认 core、终端、标签或 App 配置。

## 共享工作区方案：直接复用 Herdr 移动端

### 新证据与边界

[Herdr Mobile 官网](https://herdr.dev/mobile/) 明确说明：

- 移动端通过 SSH 直连每台机器的 herdr-core，不经过 Herdr 云端；可用 Tailscale/VPN。
- 可以搜索任意终端，报告 OSC 7501 的 agent 出现在 Inbox。
- 桌面 spaces 在手机显示，tab 有 pane 小地图，可以观看或启动终端；观看不会 resize 桌面终端。
- FAQ 写的是“spaces show up when the Herdr app runs there too”。尚不能仅凭文档推定 Santty 写入同名文档就完全替代桌面 App；需验证移动端读取路径和是否存在额外的文档维护逻辑。

本机 `docs.json` 中 `herdr-app.value` 的结构实际是 `spaces[] → tabs[] → root`；已观察到 `row` 和 `block` 节点，block 的 `content.terminal` 引用本机终端地址，size 可含 weight。当前样本没有覆盖所有节点类型，不能据此宣称完整 schema。外层 `version` 是 doc.set 的并发修订号，不是布局 schema 版本。

### 推荐架构

```text
Santty 原生 UI ─── 共享工作区适配层 ─┐
                                  ├─ 每台 core 的 herdr-app 文档 + terminal labels
Herdr 桌面 / 移动端 ────────────────┘                  │
                                                既有终端程序
```

对选择共享的工作区，以 Herdr 兼容的文档为共享结构权威来源。Santty 的 v10 本地存储只保留本地 UI 状态、映射和缓存；不再把旧的本地结构快照反复覆盖到共享文档。未共享的 Local Workspace 保持原有语义。

不要另写一个只叫 `santty` 的共享文档作为跨端协议：未经修改的 Herdr 移动端不会自动理解它。也不要把整个 v10 SavedWorkspace 直接上传，因为它混合了共享结构与设备 UI 状态。

### 共享模型映射

| Santty | Herdr / 处理策略 |
| --- | --- |
| Herdr Workspace | 某一永久 core ID 下的 space；保存稳定 ID 映射 |
| Tab | 同 space 下的 tab |
| Herdr terminal pane | block + 原有 terminal address；不得重新 run |
| 水平/垂直 split、顺序、比例 | 映射到 Herdr 已验证的布局节点和 weight |
| workspace/tab 命名与排序 | 共享 |
| selected tab、焦点、zoom、窗口尺寸、Scroll Mode | 设备本地，不反向同步 |
| Browser、Agents、Workspaces pane、sidebar、floating/hidden、auto-resize | 首期不共享；保留在本地 sidecar，不静默删除或伪装成终端 |
| 直接 PTY 的 Local Workspace | 首期不支持；另行显式转换到 Herdr，不能无损搬运正在运行的 PTY |

移动端可以使用自己的布局呈现方式，不要求像素级复刻桌面窗口。“继续工作”首先是同一组程序、同一 space/tab 关系与兼容分屏结构。

每台远程 core 有自己的文档和本地地址空间；不要把 Mac 上的 remote-qualified 地址直接写进远程文档。映射始终绑定永久 core ID，不能只保存 alias 或裸 t 地址。

### 同步与冲突

使用 `doc.get` 读取文档和 revision，用 `doc.set(name, value, version)` 做比较并交换；使用既有 `events.subscribe` 的 doc 事件触发刷新。事件断档/重连重新读取，不将本地缓存当作最新状态。

- 所有编辑先表达为“重命名 tab / 添加 split / 移动 pane”等稳定 ID 操作，而非上传整个旧 SavedWorkspace。
- 遇到 conflict 重新读取；只对可证明安全的操作重新应用。目标被删除或同一布局发生冲突时明确拒绝/提示，不能最后写入者静默覆盖整份文档。
- 不把未知字段/节点丢掉后重编码。若不能无损保留，应禁止编辑相应范围；移动端不支持的 Santty 功能留在本地。
- 本地 presentation 更新不能触发共享结构回写；远端刷新不能抢 first responder。
- doc.set、terminal.run/kill、labels 之间没有已证明的跨方法事务。创建先持久化 pending intent，再按稳定标签核对 run，然后提交绑定；失败/超时不得自动重跑。
- 删除文档节点、detach viewer、kill 程序是不同动作。远端布局刷新仅更新视图，不因节点消失额外发 kill；用户明确关闭共享终端才执行结束程序的流程。
- 保留 Herdr 其它 spaces 和非 Santty 节点；外部 viewer 不因加入共享布局而自动取得 kill 权限。
- 初期离线只读，拒绝结构修改；不要积累会在重连后复活已删除 tab 或重放 kill 的离线队列。

### 最小验证与实施门槛

1. 在隔离 core 上构造一个兼容 space、一个 tab、两个既有 terminal block，并维护对应 Herdr labels。
2. 手机通过 SSH 连接这个隔离 core，在 herdr-app 未运行时确认能否发现 space、显示两个 pane、进入原程序。
3. 手机启动新终端后，Santty 是否能收到事件并导入新结构；确认哪些结构编辑由移动端提供，不先假定支持全部编辑。
4. 分别验证 Santty / Herdr 桌面的 rename、split、move、close 双向更新，以及同时编辑时的 CAS 冲突。
5. Santty 退出后手机仍可工作；重新打开不重复创建终端、不覆盖手机接受的新结构。
6. 手机预览不抢桌面尺寸；进入交互终端后的尺寸接管与回切单独验收。
7. 从手机访问 Mac 需要 Mac 醒着、网络可达且 SSH 已配置。共享工作区不迁移程序；如果要求 Mac 睡眠后继续运行，程序必须放在常开的远程 core 上。

只有前两步证明移动端互操作后，才值得把 workspace 的结构权威从本地存储迁到兼容文档。完整实现仍需移动端协议/实机证据、未来 schema 版本策略和跨客户端关闭测试；基础层已有 unknown node 保留和 revision/连接范围测试，但还没有完整的同步 UI。不是给现有终端加两个标签即可完成。

