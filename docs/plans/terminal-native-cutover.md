# 5C 原子主程序切换记录

## 当前范围

当前工作树已用 **原始预编译 Ghostty VT 1.0.0 → SwiftTerm 外部帧／平台组件
→ AppKit 虚拟 NSScrollView** 替换生产旧 surface 后端。
不包含运行时开关、旧 backend fallback、旧输入重放或符号隔离层；
没有重新编译 C core。回退使用切换前构建／Git，不在进程内混用两个核心。
本轮尚未提交，切换前包含未跟踪文件的工作树已留私有备份。

**这是 5C 代码与自动化证据，不是 5D GUI／设备验收或发布批准。**

实验项目随后已清理：共用代码只在生产 app 中编译，正式 `SanttyTerminalTests`、私有 test support、资源、探针和兼容性记录的现位置见 [终端开发与验证](../terminal/README.md)。下面的切换阶段计数及 lab 名称为历史记录。

后续功能、性能优化及建议顺序见 [Native Terminal 路线图](terminal-native-roadmap.md)；
路线图中的候选项不计为本次切换已经实现或验收的能力。

## 主程序接线

- 共用实现从 lab 移到 `Santty/Sources/Terminal/Native/`；lab 只保留私有启动包装
  和入口。生产与 lab 编译同一 driver／host／owner／read／Scroll Mode 实现。
- `TerminalPaneController` 绑定永久 pane UUID、具体 session/driver/output 和
  checked frontend；覆盖 tiled、floating、sidebar、后台 tabs/workspaces。
- 原生 renderer 是实际 responder。loading host 的显式焦点只在首次可输入边沿，
  仍是当前 pane 且 responder 仍是该 host 时交接；metadata 不恢复其他 responder。
- 字体／主题／透明度、菜单和 host paste、命名键、IME、Prompt Editor lease、
  Local scoped foreground/cwd、Herdr authoritative foreground、input-source port 接通。
  远端 PID／路径从不进入本地进程／文件系统查询。
- CLI read/search 使用 retained logical history 的异步 read service，在 await 前后
  校验具体 pane/session。list 保留同步只读；router 的 grants／retry journal 不变。
- Local 用真实账户 login shell、HOME 和用户环境；私有测试包装才创建／删除隔离 HOME。
  生产历史仍为 **8 MiB**。CLI capture／response、AX 和复制限额是不同契约。
- Local／Herdr 关闭共用 `PaneCloseTransaction`：先全部 preflight/fence，再独立等待所有
  owner，最后精确核对 controller/container 并同步提交。Local 是实际 awaitedOwner，
  不再依赖 view deinit。失败／取消保留布局；不承诺回滚已结束程序。
- 窗口／app 关闭的前后原子保存、Herdr viewer detach、pending-run 最终状态和最后 CLI
  socket reply-before-destruction 顺序保留。显式 cleanup 不通过 onExit 提前移除布局。

## 依赖与产物

- `Project.swift` 仅使用 pinned SwiftTerm 与原始 VT xcframework；普通生成无需 lab flag。
- `mise run terminal:prepare` 是唯一 terminal 准备任务，常规 install/generate/regen
  与 lab generation 都依赖它。
- 删除旧 Herdr Ghostty adapter、旧 ScrollModeView、旧 prepare 脚本和七个旧 surface /
  mailbox / display-link / wake 桥接补丁；原生八个补丁保留。
- `audit-terminal-dependencies.py --check` 与 `--require-removed` 均检查当前移除契约，
  结果 **0 production / 0 test legacy imports**。历史基线及负向审计 fixture 保留。
- `verify-native-terminal-linkage.py` 读取实际 link 命令、resolved package state，
  逐 Mach-O architecture 检查 VT 定义与旧 app/surface/config 定义缺席，
  并 demangle 确认 SwiftTerm renderer 定义。Debug 检查 companion dylib，不把
  launcher stub 当实现；Release 检查 arm64 与 x86_64。两种配置均通过。
  增量构建不会重录 cached xcframework prepare；可重复传入 \`--build-log\` 同时提供
  clean provenance 和随后实际增量 link 记录，不放宽 archive／符号检查。
- 原 ignored 旧 vendor 目录可以作为主题／locale 来源研究，不是 manifest 依赖，
  不参与链接，也不是 fallback。485 条主题 JSON 与许可仍可重现。

复现命令（不改写 FlowDeck 已保存的 Santty / My Mac / Debug）：

```sh
mise run tuist:generate
flowdeck build -s Santty -C Debug -d /tmp/<private-build>
flowdeck build -s Santty -C Release -d /tmp/<private-build>
flowdeck test -s Santty -d /tmp/<private-build> --test-targets SanttyTests --json
python3 -B Scripts/audit-terminal-dependencies.py --require-removed
python3 -B Scripts/verify-native-terminal-linkage.py \
  --app /tmp/<private-build>/Build/Products/Release/Santty.app \
  --build-log /tmp/<saved-flowdeck-raw-build.log> \
  --workspace-state /tmp/<private-build>/SourcePackages/workspace-state.json
flowdeck test -s Santty -d /tmp/<private-build> --test-targets SanttyTerminalTests --json
```

## 自动化证据

- 干净私有目录 `/tmp/santty-native-cutover.ajjz3Q`，普通（不含 lab）生成：
  Debug／Release build 成功，resolved/link/Mach-O 核验成功。
- 主程序 **387 passed / 0 failed / 1 existing system-capability skip / 388 total**。
  唯一跳过仍是系统不提供 private effective corner-radius getter。
- lab **458 passed / 0 failed / 0 skipped**，继续包含原始真实 Local PTY、
  两私有 Herdr core/proxy、nvim／tmux、6000 行 wide output、parse-credit、
  图像／PNG／动画、CG／Metal 实际像素和只读 AX 回归。
- 新增 4 项 production integration：真实私有 Local awaited close 后才移除 pane；
  loading host 焦点交接；其他 responder／stale prompt 拒绝；未发布页面的隐藏
  Scroll Mode entry 只建立 VT refs，不发布 pixels/AX，不授权输入。
- 旧 surface 专用测试移到实际 VT／native controller API，原始协议 bytes、
  wide-output／6000 行首行复制、Unicode／空白／词移动、CLI permission／关闭顺序
  保持；新增 CLI retained-history 的 wrap／conceal 契约，不用 AX 页面代替历史。
- 审计八项正／负回归与主题 catalog 检查通过。没有新增 skip、延长原 consumer
  deadline、修改 wire bytes、改小 history、加生产输入 delay 或更换消费者程序。

## 本轮失败与根因（原始日志保留）

1. 第一次 full main 是 **324 passed / 59 failed / 1 skip**，包括模型测试 crash。
   首要根因是 factory 设置 exact-membership predicate 后、注册前更新设置，
   被 frontend 正确拒绝为 stale；适配器把该拒绝误存为永久初始化错误。
   注册前仅更新宿主外观，设置更新检查真实 current owner 后，原测试大批恢复。
2. 新 backend 的真实 headless PTY 不应由模型的 tab selection 偷跑：
   pane-start helper 现在只在 workspace hasAppeared 后启动；私有 owner 显式 headless
   start 仍由真实 metrics 决定。LocalProcess 延迟到 launch 才创建，未启动 owner 无 IO runtime。
3. 初始隐藏 Scroll Mode 没有已发布 page，原实现无法 entry；显式 entry 现在可用一次
   有界、无动画推进的 VT presentation 建立 reading refs，但不发布 page／AX／像素。
   overlay 的纯几何亦建立，不把空 rect inset 成 infinite frame。
4. 旧 TerminalView 是 responder 且直接挂 host；新 renderer 才是 responder，
   scroll view 位于保留 outer padding／2pt inner padding 的包装中。测试改查真实
   responder／祖先 owner；实际 Cmd-click 和原始输入／历史断言仍执行。
5. Link verifier 初稿错误假设 SwiftPM 必有直接 `-lSwiftTerm` 和朴素 mangled 名；
   实际是 filelist/autolink、局部定义和压缩 mangling。独立 nm + swift-demangle 确认后
   改为真实符号证据。旧 cached build 还留 DisplayLink；用全新私有目录验证，不删共享缓存。
   fresh 中的 `h` 是新 SwiftTerm → swift-png → CRC 的合法依赖，
   由其 Package.swift 独立确认，不能误当旧 wrapper 证据。
6. 历史上的 raw transport 压力、6000-row 首行、remote metadata／nvim-ready 偶发观察
   仍按先前记录保留，未宣称统一根因或已修复。

日志：`/tmp/santty-cutover-*`，包括 first-full-main、registration-full-main、
new-integration2、clean-main、clean-debug/release raw logs 和最终 linkage JSON。
切换前和失败版本的记录均未覆盖为“已通过”。

## 仍然开放的验收／限制

- 用户操作的完整 GUI：焦点、所有 pane 位置、菜单／Prompt Editor、drop、链接、
  unsafe paste／Copy Once、IME/preedit、TIS、实际账户 shell/profile/terminfo。
- 实际 VoiceOver／AX tree traversal；不安装 AX input/select/scroll/focus/execute setter。
- 睡眠唤醒、遮挡／最小化／隐藏、跨屏／Retina／输入设备、多 pane、
  renderer 性能、内存／能耗和真实网络设备；不能用 offscreen pixels 代替。
- Scroll Mode wheel 是 bounded physical-row navigation，有 fractional banking；
  不宣称平滑 subpixel 或 scroller direct-seek 支持。
- 固定 VT 的零 crop、同 ID 图像替换、同步 clipboard 拒绝边界、GIF／APNG、
  完整 shell integration／Ghostty config import 等差异仍见各 compatibility 表。
- 没有重试 GUI automation、变更 TCC、激活用户窗口／VoiceOver、重启共享 core
  或操作用户终端。更早有限人工“正常”只覆盖当时项目，不继承为本轮完整验收。
