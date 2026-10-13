# Herdr Agents 接入与旧监控移除

日期：2026-10-12。只连接用户已启动的本机 Herdr，不启动、安装或修改服务端。

## 已实现

- 独立、inactive ClientShell 连接接收所有 workspace 的 `shell.snapshot.v1`、`endpoint.agent-completions.v1` 和语义通知。无需 terminal runtime 映射；不申请 surface、不发送终端输入或 focus/resize，Default 下保持连接。
- 按 endpoint、服务进程身份、boot、pane 建立全局 agent 目录。保留未知 agent 类型和未知状态；失联显示 unavailable；自动重连；元数据未改变时不重绘面板。
- 以初始快照为基线，completion 证据必须匹配 boot/revision；按状态序列去重。通知早于元数据时短暂等待匹配；本地已读状态不影响其他客户端。
- Agents / Messages 面板显示 workspace、tab、pane 上下文。点击行与系统通知复用 command palette 的导航事务，重新验证 endpoint/服务身份/目标，等待真实 ClientShell 布局后聚焦。
- Claude、Codex、其他 agent 的开关只控制系统通知。消息目录仍更新；当前可见 tab 抑制注意/完成系统横幅。
- 移除 hook 安装器、agent 事件 socket/解析器、pane 注册表、PID/前台进程 agent 判定和 liveness monitor；不再注入 `SANTTY_AGENT_SOCKET` / `SANTTY_RUNTIME_OWNER`。CLI 的普通进程列表仍保留。
- 启动迁移仅清理当前 bundle 精确安装的 hooks 和对应 Codex trust 项；原文件备份、原权限保留。不改其他 hooks、其他 owner 或全局 feature 设置；无引用时才移除旧辅助脚本。

## 验证

- FlowDeck Debug build 成功。
- 相关 Herdr capabilities、ClientShell session/state、Agent 配置测试：67 项通过、0 失败、1 项跳过（环境依赖测试）；输出 `/tmp/santty-herdr-agents-final-tests.jsonl`。
- 隔离 socket fixture 验证 inactive 连接不激活 surface、不输入/resize；双份语义通知仅产生一条未读；Default 下目录发现其他 workspace，点击 agent 跳转后返回保留本地 tabs。
- 覆盖初始基线、乱序元数据、completion boot/revision 匹配、未知 agent、可见目标抑制横幅、旧场景不能清除新消息、256 条历史上限、Agents/Messages 分段切换与面板尺寸更新。
- 配置 fixture 验证自定义/其他 owner hooks 和 trust/global feature 保留、备份、幂等以及非法 JSON 时不写入。
- 开发版真实启动后：当前开发 bundle 的旧 Claude hooks 剩余 0 项。后台 AX 验证 Settings → Agents 仅三类通知开关，无 hook 安装/monitor 控件。证据 `/tmp/santty-herdr-agents-ui-notifications-tree.json`。

## 限制

消息仅保存在内存，最多 256 条；Herdr 语义通知为实时广播，不提供历史补发或完整 assistant 回复。当前真实连接没有可显示的 agents，因此真实 Agents 面板、macOS 通知横幅及通知中心点击未端到端验证；消息接收、面板与跨 workspace 导航已由隔离测试覆盖。SSH 暂未实现。
