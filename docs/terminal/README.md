# 终端开发与验证

实验 app 已移除。生产实现、正式回归测试、私有测试会话、资源和探针均有固定归属；
不再需要 lab scheme 或生成环境开关，也不再重复编译一份终端实现用于测试。

## 目录归属

| 内容 | 位置 |
| --- | --- |
| 共用生产终端实现 | `Santty/Sources/Terminal/Native/` |
| 正式终端回归测试 | `Santty/TerminalTests/`，target 为 `SanttyTerminalTests` |
| 私有 PTY／Herdr 测试辅助代码 | `Santty/TerminalTests/Support/` |
| 生产主题数据 | `Santty/Resources/TerminalThemes.json` |
| 随 app 打包的许可和来源声明 | `Santty/Resources/TerminalLicenses/` |
| 独立探针／向量与主题生成工具 | `Scripts/Terminal/` |
| 契约、限制和历史证据 | 本目录 |

`SanttyTerminalTests` 通过 `@testable import Santty` 使用实际 app 模块，
与主程序集成测试 `SanttyTests` 分开组织，但在普通工程生成中始终可用。
两个私有会话 helper 仅编译进测试 bundle；不启动用户 shell/profile，
不连接／停止共享 core，不创建生产 HOME，不替代生产关闭策略。
测试 fixture 的历史 `TERM_PROGRAM`／私有 domain 字符串可保留原值，
以免目录整理改变原始消费者向量；这些字符串不是可运行的 lab target。

## 常规构建与测试

沿用保存的 Santty / My Mac / Debug 配置；代理任务用显式私有 DerivedData 覆盖，
不要通过改写 FlowDeck 默认配置来切换测试。

```sh
mise run tuist:generate
flowdeck build -s Santty
flowdeck test -s Santty --test-targets SanttyTests,SanttyTerminalTests --json

# 仅运行终端语义、绘制和私有消费者回归
flowdeck test -s Santty --test-targets SanttyTerminalTests --json
```

`mise run terminal:prepare` 准备 pinned SwiftTerm 与原始预编译 VT，并应用八个补丁；
常规 mise 生成任务已依赖该步骤。不得重新编译 C core 或恢复旧 backend。

整理前终端套件有 **458 个测试方法**；全部迁入正式 target，未删除方法、
改变断言／等待期限、修改协议或图片向量、缩减历史预算或添加 skip。
迁移后的首轮正式 target 为 **458 passed / 0 failed / 0 skipped**。
本轮在全新私有 DerivedData 中联合运行两套测试：**857 passed / 0 failed / 1 existing system-capability skip / 858 total**。
Debug／Release 构建与实际 resolved/link/Mach-O 核验通过；两种配置都逐字节核对了
主题 JSON 与十一份随包许可。独立审计十项回归、主题／PNG 向量重现、迁移后的
VT settings/read/scroll/paste/image 与 Local PTY 探针通过。
历史总数不等于当前测试总数；唯一跳过仍是系统不提供 private corner-radius getter。

注意：FlowDeck 的 `--test-targets` 多目标用逗号分隔，`--only` 的多个测试选择则用空格；两者不同。

## 独立探针与生成器

```sh
python3 -B Scripts/Terminal/generate-theme-catalog.py --check
python3 -B Scripts/Terminal/probe-adapter-shell-policy.py
sh Scripts/Terminal/probe-vt-settings.sh
sh Scripts/Terminal/probe-vt-read.sh
sh Scripts/Terminal/probe-vt-scroll-mode.sh
sh Scripts/Terminal/probe-vt-paste.sh
sh Scripts/Terminal/probe-vt-image-api.sh
sh Scripts/Terminal/probe-local-pty-api.sh
sh Scripts/Terminal/probe-appkit-color.sh
```

主题生成器只离线读取固定 revision 的旧主题源码，默认研究源目录为 ignored
`Vendor/libghostty-spm`，也可用 `--source` 指定已验证的来源。这个来源不是 app／测试
依赖，正常构建不需要旧 wrapper。主题与十一份许可文件迁移保持逐字节一致。
PNG 向量生成器 `generate-png-vectors.py` 输出 Swift 测试数据，
对应 `Santty/TerminalTests/NativePNGFixtures.swift`；只使用 Python 标准库构造独立预期。

原 GUI 的 ANSI／Unicode、静态 RGBA／PNG、VT 动画和 AX 手工样例也未丢弃：
`xcrun swift Scripts/Terminal/print-sample.swift --help` 列出可打印样例。
该工具只向 stdout 输出原始字节，不连接 session、不启动 AppKit；只在显式创建的
一次性测试终端中运行，或重定向到自己的临时文件。它不是被保留的实验 app。

`check-nvim-paste-order.py` 和 `check-nvim-writefile-order.py` 保留原消费者
race／正向控制，不能用成功控制组冒充快速 burst 已修复。

## 契约与限制

- [输入](INPUT-COMPATIBILITY.md)
- [图片／PNG／动画](IMAGE-COMPATIBILITY.md)
- [只读 AX](ACCESSIBILITY-COMPATIBILITY.md)
- [本地 PTY](LOCAL-PTY-COMPATIBILITY.md)
- [设置与 metadata](SETTINGS-COMPATIBILITY.md)
- [retained-history read/search](READ-COMPATIBILITY.md)
- [生产 launch／ownership](OWNERSHIP-COMPATIBILITY.md)
- [Scroll Mode VT ports](SCROLL-MODE-COMPATIBILITY.md)
- [Scroll Mode keyboard／overlay](SCROLL-MODE-UI-COMPATIBILITY.md)
- [Scroll Mode pointer／wheel／autoscroll](SCROLL-MODE-POINTER-COMPATIBILITY.md)
- [Host actions／paste／input-source ports](HOST-COMPATIBILITY.md)
- [Pane session／frontend](SESSION-COMPATIBILITY.md)
- [关闭／保存／CLI reply 顺序](CLOSE-COMPATIBILITY.md)

这些文件保留各阶段的里程碑计数、失败诊断和当时的范围，不能把历史陈述当当前接线。
旧 GUI 启动步骤仅存于 [实验历史记录](history.md)，不再是运行指令。
当前功能与后续工作见 [渲染设置](../terminal-rendering.md)、
[切换证据](../plans/terminal-native-cutover.md)、[后续路线图](../plans/terminal-native-roadmap.md)。

协议接受、offscreen pixels、真实 GUI／VoiceOver／IME、跨屏／睡眠／设备／能耗
仍须分别验收。文件归位和测试通过不会自动关闭这些门槛。
