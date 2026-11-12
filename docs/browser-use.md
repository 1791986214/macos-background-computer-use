# WorkBuddy Browser Use 调查报告（v0.5.0）

> 目的：在把 Third Hand 和 Browser Use 做成互补能力之前，先把「Browser Use 到底有什么接口」查清楚。
> **不猜接口**——凡是查不到的，这里就写「查不到」，不用推测填补。

## 一、调查方法（可复现）

| 步骤 | 命令 | 结果 |
|---|---|---|
| 1. 本会话可见工具清单 | 运行时工具表（含 `mcp__*` 全部连接器） | 无 `browser_*` / `playwright` / `cdp` 类工具 |
| 2. 应用包内工具名 | `strings -a app.asar \| grep -oE '"[a-zA-Z_]*[Bb]rowser[a-zA-Z_]*"'` | 只有 `"browser"` / `"browsers"` / `"browserslist"`（后者是 npm 依赖），无工具名常量 |
| 3. 内置插件 | `ls ~/.workbuddy/plugins/cache/workbuddy-builtin/` | 50+ 个插件，无浏览器插件 |
| 4. 连接器市场 | `ls ~/.workbuddy/connectors/marketplace-meta/` | 无浏览器类连接器 |
| 5. 扩展包 | `find /Applications/WorkBuddy.app -maxdepth 4 -iname "*browser*"` | 无 Chrome/Edge 扩展产物 |
| 6. 官方文档 | `workbuddy.cn/docs/workbuddy/Overview` 及目录 | 文档未描述 Browser Use 工具接口 |

## 二、结论：本构建暴露给 Agent 的「浏览器能力」是什么

| 能力 | 是否存在 | 实际接口 | 能做什么 | 不能做什么 |
|---|---|---|---|---|
| 内置浏览器预览面板 | ✅ | `present_files(url)` / `present_files(html 路径)` | 在右侧结果区打开页面、渲染 HTML、localhost 服务预览 | **没有** DOM 读写、点击、输入、滚动、截图接口 |
| 网页内容抓取 | ✅ | `WebFetch` | 抓取 URL → HTML 转 Markdown → 按 prompt 提取 | 只读、无会话、无交互、不能执行页面 JS |
| 网页搜索 | ✅ | `WebSearch` | 关键词搜索、域名过滤、时间过滤 | 同上 |
| 浏览器自动化（点击/输入/滚动/标签页/DOM 查询） | ❌ | 无 | — | 本构建未向 Agent 暴露 |
| 外部浏览器扩展通道 | ❌ | 无 | — | 未找到扩展产物或连接器 |

**所以：本阶段不存在「可以让我点击网页按钮」的 Browser Use 工具。**
任何声称「用 Browser Use 点了网页元素」的输出都是编造的。

## 三、这对 Third Hand 意味着什么

### 3.1 分工（写进 Skill 的路由规则）

```
网页内容读取 / 搜索            → WebFetch / WebSearch
页面展示给用户看（含本地 HTML）  → present_files（内置右侧面板）
网页内 DOM 级交互（点击/输入）   → 本构建不可用；不得用坐标点击冒充
macOS 原生应用                 → Third Hand（wbcu）
混合任务                       → 各自做自己那段，WorkBuddy 负责串
```

### 3.2 一条明确的红线

**不要用 Third Hand 的坐标点击去模拟「浏览器自动化」。**
原因不是技术做不到，而是：
- 坐标点击不受 DOM 约束，点中的是「屏幕上那个位置」，页面滚动/布局变化就点错；
- 无法读取页面状态来验证结果，只能靠截图猜；
- 一旦浏览器在前台，还会和用户的真实鼠标抢位置。

需要网页交互时，正确做法是**如实报告能力缺失**，而不是用坐标点击假装成功。

### 3.3 如果将来 Browser Use 工具可用

不需要改 Third Hand 的引擎。协成本为零：
- 两者都在 WorkBuddy Agent 的工具层被调用，互不经过对方；
- Third Hand 不拦截、不代理、不"守护"其它工具的调用（它没有全局钩子，也不打算有）；
- 共享的只有「任务上下文」和「经验/性能记录」，且是文件级只读共享，不构成耦合。

## 四、与「内置浏览器面板」相关的行为说明

`present_files(url)` 打开页面时，WorkBuddy 自己的窗口会到前台。这一点需要说清楚：

- 那是**用户自己的应用窗口**（WorkBuddy），不是「Third Hand 抢了目标应用的前台」；
- 它不改变被操作目标（Calculator / 其它 App）的窗口状态；
- 如果用户希望完全不切换，可以不调用它，直接读 `WebFetch` 的结果。

## 五、未验证 / Not Tested

| 项目 | 状态 | 原因 |
|---|---|---|
| 外部浏览器（Chrome / Edge）自动化 | Not Tested | 未找到扩展通道；无法确认是否存在未暴露的私有通道 |
| 页面内截图与视觉定位 | Not Tested | 无接口 |
| 标签页绑定 / 会话复用 | Not Tested | 无接口 |
| 内置面板的 DOM 可访问性 | Not Tested | 面板是 Electron webview，未提供对外自动化接口；不尝试注入 |

## 六、这一节的结论一句话

**Browser Use 在本构建里是「能读、能展示，不能交互」。**
Third Hand 因此不需要为浏览器做任何特殊适配，只需要把「网页交互」这条路**如实标为不可用**，
不越界用坐标点击去冒充。
