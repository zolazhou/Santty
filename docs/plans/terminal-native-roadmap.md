# Native Terminal 后续功能与优化路线图

状态：**候选路线图，尚未实施或完成验收的项目均不视为现有能力。**
本文件记录原生终端切换后的机会、约束和建议顺序，不承诺排期，
不以新功能代替当前日常使用中发现的问题修复。

关联文档：[切换证据与验收门槛](terminal-native-cutover.md)、
[渲染引擎与字体快捷键](../terminal-rendering.md)、
[原始迁移计划](terminal-framework-rendering.md)。

## 1. 架构变化带来的空间

当前链路是原始预编译 Ghostty VT → 拥有数据的有界帧 → SwiftTerm 外部帧绘制
→ AppKit 虚拟 NSScrollView。Ghostty 继续管理解析、模式、编码、选择、历史引用、
图片解析和动画语义；Swift／AppKit 层直接管理呈现、交互和平台 UI。

这些功能并非旧架构下绝对做不到，但现在可以在宿主层独立实现和测试，
不必为每项体验修改完整 terminal surface 封装，也不需要维护第二个模拟器。

### 已有基础，不应重复列作“待实现优化”

- Core Graphics／Metal 两条绘制路径；Settings 可保存选择并更新现有／新建终端。
- 原生虚拟滚动、有界捕获、行转换缓存、历史 tracked refs 和底部跟随。
- 隐藏／遮挡／睡眠时停止呈现与动画唤醒，解析、自动应答和 Herdr credit 独立继续。
- Scroll Mode、VT selection／formatter、程序图片／静态 PNG、只读有界 AX 页面。
- CLI retained-history read/search；主程序图形搜索界面尚未实现。
- 主程序 View 菜单与 Cmd+=／Cmd+-／Cmd+0 字体缩放，渲染引擎切换保留每 pane 缩放。

已有代码和自动化测试不是 GUI、VoiceOver、IME、睡眠／跨屏或能耗认证。

## 2. 功能候选

| 方向 | 用户收益 | 依赖与边界 |
| --- | --- | --- |
| **原生 Cmd+F 搜索** | 历史搜索、结果计数、上下跳转、画面高亮 | 显式建立逻辑文本结果到 VT physical cells／tracked refs 的映射；不能直接把 CLI 行号当画面行号 |
| **命令级导航** | 跳到上／下条命令，选择并单独复制命令输出 | 复用 VT 已暴露的 OSC 133 semantic-prompt 回调、行／单元格分类；需要可靠 shell 标记 |
| **完善 Scroll Mode** | 滚动条直接定位、更自然的滚轮体验、搜索联动 | 当前是有界物理行导航与 fractional banking，不能把像素偏移直接当历史行号 |
| **终端内容操作菜单** | 复制选区／链接、当前画面导出、选择状态提示 | 使用已解析的 VT 数据；用户显式操作，不自动写剪贴板或扩大程序权限 |
| **图片交互** | 用户显式预览、放大、复制图片 | 只使用已解析且受限的拥有像素；不新增协议解析器或读取程序指定的本地文件 |
| **标签页／Pane 预览** | 悬停缩略图、工作区概览 | 优先复用最后发布的画面；明确可能过期，不为预览 attach、resize、发送 focus/input 或持续绘制 |
| **辅助功能体验** | 更清晰的阅读顺序、Scroll Mode 状态提示、更新通知 | 保持 AX 只读且限于已发布页面，完成真实 VoiceOver／AX tree 验收 |

### Cmd+F：优先实现的用户功能

建议先做普通文本搜索、上一项／下一项、结果计数和有界高亮，
再考虑更复杂的匹配选项。复用现有读屏／formatter 和捕获预算，
不长期镜像一份完整历史文本，不把 AX 页面或 renderer overscan 当历史。

搜索应可取消，避免 MainActor 承担大文本匹配；异步返回时校验具体 pane、session、
VT reset epoch 和结果所属快照。跳转还必须验证当前 tracked ref。
历史 pruning、reset、reconnect、alternate screen 或 reflow 后，失效结果应明确刷新／拒绝，
不能按相同数值行号或相似文本偷偷重定位。

验收至少覆盖 Unicode／宽字符／组合字符、软换行、快速输出、历史裁剪、
重连、屏幕切换、用户选择保留、后台 pane 和同 UUID owner 替换。
遵守现有预算；超限明确报告，不返回“成功”的截断结果。

### OSC 133：第二项重点功能

可先实现上下命令跳转、选中一段输出、复制该段输出。
具备明确协议字段和完整事件时，再显示命令状态、耗时或退出信息；
缺失、重连和截断事件必须按 unavailable／不完整处理。

- 先验证固定预编译 VT 的实际回调、字段与 retained-history 行为，再定义 UI 契约。
- shell integration 应另行设计并由用户显式启用；不自动修改启动文件或安装 hooks。
- 不靠 PID、进程名或屏幕文字猜测命令边界／成功失败，不改变 Agents 的 OSC 7501 权威来源。
- 语义事件不得阻塞解析、协议应答或 Herdr credit；不重放输入或不明确的远端 run。
- Remote、Local 与 viewer-only 身份边界不因命令 UI 而改变。

## 3. 优化候选

### P0：先建立可重复的性能基线

分别测量，而不是仅凭“感觉更顺滑”判断：

- VT 解析、锁等待、帧捕获、网格转换、实际提交／绘制耗时。
- 捕获／转换／重绘行数，缓存命中率，分配和图片／纹理占用。
- 主线程阻塞、输入到呈现的延迟、CPU、内存、空闲唤醒与能耗。
- Core Graphics／Metal，在不同 pane 数量、输出频率、字号／窗口尺寸下的差异。
- 可见、后台标签页、隐藏／遮挡／最小化、睡眠恢复和跨屏／Retina 场景。

诊断采样应有界、默认关闭；不记录原始输入、屏幕文本、环境变量或连接命令。
解析完成、提交完成与实际可见呈现必须区分，不能把提交时间冒充屏幕延迟。
性能结论必须附设备与场景；不预设 Metal 一定更快或更省电。

### 用测量结果指导增量优化

已有行复用和隐藏停止绘制的基础上，再查找：

1. 未变化内容是否仍重复捕获、转换或分配，是否有可消除的工作。
2. 显示更新能否合并，而不延迟解析、自动应答或 parse-completion credit。
3. AX 文本／映射是否在页面未变化时仍被不必要地重建。
4. 多 pane 之间是否能安全共享字体、绘制资源或图片缓存。
5. 关闭、切换引擎和 device／scale 变化时，资源是否及时且安全地释放。

共享资源需正确区分 device、字体、尺寸、backing scale、颜色空间和 generation，
不得串用旧图、跨 pane 状态或借用的 C 指针。优化前后运行独立正向控制和原失败向量。

### 平台稳定性也是 P0

继续收敛日常测试发现的快捷键、焦点、IME/preedit、菜单／Prompt Editor、
睡眠唤醒、跨屏、遮挡、缩放和多 pane 生命周期问题。
对自己的宿主层可诊断、可修改，不代表这些场景已经验证稳定。

## 4. 建议实施顺序

1. **稳定性与性能基线**：修复实际使用中的缺陷，建立可重复指标。
2. **原生 Cmd+F 搜索**：完成结果映射、定位、高亮与失效规则。
3. **OSC 133 命令导航／输出复制**：先验证协议接口，再做显式启用的 shell integration。
4. **预览、图片交互与针对性的 GPU 优化**：以真实需求和测量结果排序。
5. Scroll Mode、辅助功能和设备验收持续推进，不把未验收项目标为完成。

## 5. 共同约束与测试归位

- 一套 VT 权威，不引入第二模拟器、历史镜像、选择解释器或动画播放器；不重编 C core。
- 不恢复旧 backend 或增加运行时 backend fallback；CG／Metal 选择只是呈现路径切换。
- 保持生产 **8 MiB history** 及原有捕获／复制／AX／输入预算，不用缩减历史掩盖性能问题。
- 保持 Herdr 永久身份、parse credit、pending-run 保存、viewer-only detach 和无输入重放。
- 新 UI 不绕过 CLI grants／retry journal，不因后台更新改变 workspace、tab 或 first responder。
- 不自动变更 TCC、激活用户窗口、启用 VoiceOver、重启共享 core 或操作用户会话。
- 固定 VT 的零 crop、同 ID 图片替换、同步 clipboard 权限边界、GIF／APNG 等限制
  不会因宿主层可控而自动消失；无限历史／永久定位也不是当前承诺。
- 回归测试已归位为正式 `SanttyTerminalTests`，保留独立私有 PTY／Herdr fixtures、探针和失败记录；
  实验外壳已移除，目录和运行方式见 [终端开发与验证](../terminal/README.md)。后续不得删除这些保障。
- 每个功能覆盖真实入口和 owner 边界：菜单／按键／设置通知／前后台 pane，
  不只直接调用底层方法。字体快捷键漏接主程序的回归见
  `Santty/Tests/TerminalFontShortcutTests.swift`。
- 协议验收、offscreen pixels、真实 GUI／辅助技术、设备／能耗分别记录；
  不新增 skip、延长 deadline、改变 wire bytes 或替换 fixture 来隐藏失败。
