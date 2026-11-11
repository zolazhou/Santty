# Native Terminal Lab

隔离的 AppKit 渲染原型：官方预编译 Ghostty VT → SwiftTerm 外部网格渲染 → NSScrollView 虚拟化历史视口。**不是正式终端后端，不创建 shell、不连接 Herdr、不读取或保存工作区。**

## 构建、测试、运行

需要项目支持的 Xcode / Swift 6.2+、mise 和 FlowDeck。沿用 FlowDeck 已保存的 My Mac target，不改写其配置：

```sh
mise run terminal-lab:generate
flowdeck build -s SanttyTerminalLab
flowdeck test -s SanttyTerminalLab
flowdeck run -s SanttyTerminalLab
```

窗口显示 2000 行固定 ANSI / Unicode fixture，可以追加 100 行、重置，以及在 Core Graphics 和 Metal 之间切换。切换的只是同一个外部帧源的绘制方式，不会产生第二个终端模拟器或会话。

普通生成不包含实验 target，也不添加 SwiftTerm 或独立 VT 依赖：

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

现有完整 Ghostty C archive 不导出独立 `ghostty_terminal_*` / `ghostty_render_state_*` 接口。对 arm64 archive 进行 `nm -gU` 检查发现两库有 859 个重合的全局定义，包括 SIMD 和第三方 C++ 符号。因此本阶段单独链接成实验 app，**尚未证明两库可安全共存于 Santty 主进程**；生产集成前需解决符号隔离并做共存测试。

SwiftTerm 只增加一处本地补丁：`Patches/SwiftTerm+ExternalFramePresentation.patch` 暴露同步 `presentExternalFrame()`。虚拟视口跨行时先准备新快照，再合成移动后的有界 surface，避免新文档位置显示旧快照；行内分数像素移动不生成新帧。补丁没有修改模拟器、字形逻辑或 Metal shader。

两项目的顶层许可位于 `Licenses/` 并随实验 app 打包；完整第三方依赖许可证清单仍是正式分发前的检查项。

## 实现边界

- `GhosttyVTDriver`：主线程上的 fixture 解析和有界 render-state 采样；完整复制 cell 的 grapheme、宽度、颜色、样式与软换行 continuation，不保留借用的 C 指针。
- `NativeTerminalFrame`：拥有数据的快照；行标识使用 Ghostty 的两个 opaque word。只缓存当前视口和 overscan，不复制全部 scrollback。
- `SwiftTermFrameSource`：增量构建 BufferLine，不创建 SwiftTerm.Terminal；复用未改变的行，保留调色板索引，接近 arena 容量时重建 store。
- `NativeViewport`：纯几何计算，把连续偏移拆为整数行和行内像素；输入坐标同时考虑弹性区域。
- `NativeTerminalScrollView`：非 layer-backed 的高文档只表达历史范围；一个带少量预取行的 renderer 随视口复用。保留 AppKit 原生滚动，不叠加 easing 或另造动量。
- 输出追加在原本位于底部时跟随；阅读历史时保持当前偏移。尚未实现历史淘汰／reflow 时的稳定内容锚点。

## 验证范围与缺口

本轮 FlowDeck 验证：实验 scheme 构建成功，21 项测试通过、无跳过（包含 Metal 像素回读）；普通生成后 Santty 构建成功，原有测试 343 项通过、2 项跳过。测试没有打开前台实验窗口或操作用户终端。

自动测试覆盖 Unicode / 字节分片、宽字符尾格、样式、调色板与擦除背景、行复用、6000 行输出保留、overscan、alternate screen、reset / resize、分数像素几何、输出跟随和有界 surface。Core Graphics 截图和 Metal 离屏纹理回读验证实际字形／背景绘制与调色板变化；只“有像素”不算通过。

尚未实现或验证：

- Herdr transport、credit、身份绑定、关闭／重连和本地 exec。
- 键盘输入、IME、鼠标报告、选择复制、链接、CLI、Scroll Mode 和辅助功能。
- 图片、overline、精确 hollow cursor 策略以及其他尚未映射的完整终端能力。
- 跨输出批次的 synchronized-output hold 与超时调度；当前 fixture 一次性喂入，不得把本 driver 直接接到 live stream。
- 稳定历史锚点、输入事件路由、睡眠唤醒、跨显示器 scale 切换。
- 物理触控板惯性／弹性体验、真实呈现帧率、延迟、多 Pane 和能耗基准。

这些缺口是生产／真实会话集成门槛，不是默认回退为“看起来支持”。当前测试和实现不能用于宣称已完成计划、终端功能对等或性能优于 Ghostty。
