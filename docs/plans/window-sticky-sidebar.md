# 窗口固定侧栏

侧栏属于窗口，独立于主区域的工作区和 Tab。当前实现支持 Browser 和 Workspaces 两类工具 Pane，默认隐藏；首次打开时在左侧显示 Workspaces 列表。

## 状态与布局

- `WindowSidebarState` 保存左右位置、首选宽度、可见性和一个内部 Tab。
- 首选宽度以 pt 保存，默认 280，最小 240。窗口临时变窄时只限制显示宽度，不改写首选值。
- `WindowContentView` 负责主区域与侧栏的左右布局及外层分隔线；主区域继续由 `WorkspaceRootView` 管理。
- 外层宽度拖动与侧栏内部布局都复用 `WorkspaceTilingView`。侧栏跨整个窗口内容高度，主工具栏只占主区域宽度。
- 侧栏 Tab 不进入工作区选择器、主 Tab 条或 CLI 的主区域 Tab 列表。
- 切换主 Tab／工作区、隐藏再显示侧栏均保留现有 Pane 对象、Browser 状态和布局。
- 关闭最后一个侧栏 Pane 会隐藏侧栏；再次打开空侧栏时恢复 Workspaces 列表。
- 启动时窗口尚无尺寸、窗口暂时缩小或调整高度，均不得改写保存的标准分屏比例。

## 入口与命令作用域

**Pane → Toggle Sidebar**、命令面板及可配置快捷键控制显示／隐藏。**Pane → Sidebar** 提供左右换位及添加 Browser、Workspaces。侧栏开关没有默认快捷键。

| 操作 | 作用范围 |
| --- | --- |
| Focus Left／Right／Above／Below | 在窗口内跨主区域和可见侧栏移动；排除隐藏侧栏、后台 Tab 与不参与平铺的 Pane |
| Next／Previous Pane | 当前区域内部 |
| 添加 Browser、关闭或命名 Pane、编辑分屏比例、Pane 重排 | 当前 Pane 所属容器；重排不跨区域交换内容 |
| Tab 与 Workspace 操作 | 主区域 |
| Terminal 分屏、转换为 Terminal、浮动、隐藏、自动调整大小 | 主区域；侧栏聚焦时禁用不适用的入口 |

实际聚焦区域独立于主 Tab 选择。两侧共享窗口焦点历史和统一坐标系，只显示一个活动 Pane 边框。方向聚焦支持左右两种侧栏位置；没有有效目标或存在 modal sheet 时保持焦点。

菜单、命令面板、快捷键和鼠标回调使用同一 Pane 所有权解析。失效 Pane／Tab 目标不得抢走当前侧栏焦点。命令面板关闭后恢复正确 responder；后台标题和目录更新不得抢焦点。

## 内容与导航

- Browser 直接复用现有 Pane controller，不另建浏览器状态。
- `SidebarListPaneController` 呈现 `workspaceEntries` 中的本地工作区，以 UUID 保持条目身份；主区域当前工作区有选中标记。
- 列表支持键盘上下选择、确认、滚动以及 Escape 返回主区域。重命名和刷新保留仍然存在的选中条目。
- 选择有效工作区后切换主区域并聚焦它；目标已删除或窗口关闭保存流程正在进行时保留原区域和内容。
- 创建、重命名、关闭工作区继续使用现有菜单，不在列表中复制管理逻辑。

## 保存与生命周期

`SavedWorkspace` 的 v10 格式保存独立侧栏记录：位置、首选宽度、可见性、内部 Tab 与实际聚焦区域。侧栏内容复用现有 Tab／Pane 序列化，Browser 保存 URL。

- 侧栏 Pane 和 Tab 的 ID 不得与任何主工作区冲突；侧栏内容计入总数量与文件大小限制。
- 校验布局深度、Pane 引用、比例、宽度及数量。仅接受两类工具 Pane，不接受 Terminal、floating、detached 或 auto resize 状态。
- 只有可见且存在有效聚焦 Pane 时才恢复侧栏焦点。
- 所有写入通过 `WorkspaceStore`，保留私有目录和文件权限、单写入者锁、备份和原子保存；不可读或不支持的格式不得被覆盖。
- 不将侧栏布局另存到全局 UserDefaults。侧栏随窗口释放，关闭主工作区不会释放侧栏内容。
- 外观、Pane 名称、窗口关闭及应用退出均覆盖侧栏。
- 工作区保存失败时保留原文件；取消关闭时保持窗口和侧栏状态。

## 验证范围

自动化测试覆盖左右布局、隐藏、宽度约束、拖动回调、跨区域方向聚焦、稳定焦点历史、命令作用域、对象身份、列表键盘导航、失效目标、快照恢复、跨区域 ID 冲突、非法状态和工作区保存失败。

```sh
rtk proxy flowdeck config get --json
rtk proxy flowdeck test --only SanttyTests/WorkspaceViewControllerTests
rtk proxy flowdeck test --only SanttyTests/WorkspaceRestorationTests
rtk proxy flowdeck test --only SanttyTests/WorkspaceStoreTests
```

后台冒烟验证使用独立 Debug 进程和临时工作区文件：打开侧栏、左右换位、跨区域聚焦、创建与切换主工作区、添加 Browser、隐藏再显示并验证恢复。连续拖动涉及前台指针时，遵循 FlowDeck 的单次授权要求。

当前范围不包括侧栏 Terminal、多 Tab、跨区域 Pane 搬移或侧栏浮动；不新增依赖或后台服务。
