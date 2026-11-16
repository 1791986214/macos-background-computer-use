# WorkBuddy Browser Use 调查报告（v0.5.1 修订）

> **这份文件推翻了自己 v0.5.0 的结论。**
>
> v0.5.0 我写的是「本构建没有浏览器交互接口」。**那是错的** ——
> 我只在 `app.asar` 里搜工具名，没查插件缓存、没查 CLI、没查技能注册表。
> 事实是：Browser Use 在本机可用，而且是**已安装、已能跑通**的状态。
>
> 下面按「产品支持 / 本机是否具备 / 是否需要启用 / Agent 能否调用 / 权限状态」五层重写。

---

## 一、五层核实（WorkBuddy 5.11.3，构建于 2026-11-13）

| 层次 | 结论 | 证据 |
|---|---|---|
| ① 产品是否支持 | ✅ 支持。两条通道：CLI 插件 `agent-browser` + 产品的「浏览器操控」`workbuddy-browser-use` | 官方文档《右侧边栏》《Agent Browser》；应用内字符串含 `browserControl` / `browserUseEnabled` / `workbuddy-browser-use` |
| ② 本机是否具备 | ✅ **CLI 通道已装且可用**：`agent-browser 0.27.0` | `~/.workbuddy/binaries/node/versions/22.22.2-6/bin/agent-browser`；插件 `~/.workbuddy/plugins/cache/codebuddy-plugins-official/agent-browser/1.3.0/`（`.in_use` 今日活跃） |
| ③ 是否需要额外启用 | CLI 通道：**不需要**，已就绪。产品「浏览器操控」通道：需要（设置 → 智能体 → 浏览器操控 → 安装） | 本机 `~/.workbuddy/skills/` 无 browser 技能；`app-config.json` 无 browser 开关；Chrome 无 WorkBuddy 扩展 |
| ④ Agent 能否调用 | ✅ 能（通过 Bash 调 CLI）。**不是 MCP 工具**，所以工具列表里看不到 | 实测下方四步全部成功 |
| ⑤ 权限/连接状态 | 无额外授权要求；不依赖浏览器登录态（用的是独立 Chromium） | 实测无 TCC 弹窗 |

### 为什么 v0.5.0 会误判

| 我查过的 | 结果 | 为什么不够 |
|---|---|---|
| `strings app.asar \| grep browser_*` | 0 命中 | 浏览器能力走的是**技能 + 外部 CLI**，不是内置工具名 |
| `~/.workbuddy/skills/` | 无 browser | 技能在**插件缓存**里，不在 skills 目录 |
| 连接器市场 | 无 | 它不是连接器 |
| 官方 Overview 文档 | 未提及 | 该页只讲产品总览，没进到具体功能页 |

**教训**：判断「有没有某个能力」，要查**能力注册表**（插件缓存 / 技能 / CLI / 设置项），
不能只查主 bundle 的字符串。

---

## 二、实际调用方式（可直接照抄）

```bash
# PATH 里默认没有它（在 WorkBuddy 托管的 node 目录下）
export PATH="/Users/lang/.workbuddy/binaries/node/versions/22.22.2-6/bin:$PATH"

agent-browser open https://example.com    # 启动/连接 daemon（同一任务复用同一个）
agent-browser snapshot                    # 读页面结构、拿可点元素（@ref）
agent-browser click "#go"                 # CSS selector 或 @ref
agent-browser fill "#q" "关键词"
agent-browser get text "#result"          # 读值验证 —— 不要只看 ✓ Done
agent-browser scroll down 600
agent-browser screenshot /tmp/x.png
agent-browser close                       # 任务结束必须关，防残留 Chromium
```

也支持：`type` / `press` / `hover` / `focus` / `check` / `select` / `drag` / `upload` /
`download` / `wait` / `eval` / `dblclick` / `keyboard type`。

### 实测记录（2026-11-16，本机）

测试页：本地 HTML，含输入框 + 按钮（点击后把输入值写进 `#result`）+ 长页面。

| 步骤 | 命令 | 结果 |
|---|---|---|
| 打开 | `open file:///tmp/wb-browser-test/index.html` | ✓ 标题 `Third Hand Browser Test` |
| 填表 | `fill "#q" ThirdHand-42` | ✓ Done |
| 点击 | `click "#go"` | ✓ Done |
| **读值验证** | `get text "#result"` | `结果：已执行 ThirdHand-42 / 1794809788724` ← JS 真的执行了 |
| 滚动 | `scroll down 700` | ✓，`eval window.scrollY` = **400** |
| 截图 | `screenshot` | ✓ 6.7K PNG |
| 关闭 | `close` | ✓ |

**前台影响**：open → click → close 全过程前台始终是 `WorkBuddy`，
零次前台切换（`wbcu trace report` 归因 0）。

---

### 2.1 macOS 上为什么「设置 → 智能体」里找不到浏览器操控

查了应用包（5.11.3）的实际注册逻辑，有两个原因，都不是「Mac 不支持」：

```js
// app.asar 里设置项的注册
{ id:`extensions.browserExtension.${browser}`, tab:`extensions`,
  requireFlags: browser === `qq-browser`
    ? [`localEnvironment`, `macOrWindowsPlatform`, `browserUseEnabled`, `domesticProduct`]
    : [`localEnvironment`, `macOrWindowsPlatform`, `browserUseEnabled`] }
```

1. **位置在「设置 → 扩展」，不在「智能体」。** `tab: extensions` 是硬编码的；
   官方文章里的「设置 → 智能体 → 浏览器操控」与这个构建的实际注册不一致。
2. **还要过一道服务端开关 `browserUseEnabled`**（来自远程配置 `browserUseFeatureEnabled`）。
   `requireFlags` 是"全为真才渲染"的语义 —— 开关关着时，这一整组 UI 直接不存在，
   连搜索也搜不到（搜索索引同样走 `matchesSearchFlags`）。

`macOrWindowsPlatform` 说明 Mac 是**支持**的，所以缺这个选项 = 账号/企业策略侧的功能开关没开，
不是平台阉割。本机实测：无 browser 技能、无扩展、`app-config.json` 无对应键 → 确实未开启。

对照：真正驱动运行时的键是 `browserControlEnabled`（`getBrowserControlEnabledFromAppConfig`），
它变化时会触发 `sessionManager.refreshMcpConfig()` —— 也就是说开启后浏览器能力是
**以 MCP 形式**注进来的，这也是为什么"工具列表里看不到 browser 工具"。

## 三、两条通道的区别（别搞混）

| | `agent-browser` CLI（本机已就绪） | 产品「浏览器操控」`workbuddy-browser-use` |
|---|---|---|
| 形态 | 技能 + 外部 CLI（Vercel agent-browser） | WorkBuddy 内置技能 + 浏览器扩展 |
| 用的浏览器 | 独立 Chromium（隔离，无登录态） | 你的 Chrome/Edge/QQ（有登录态） |
| 需要启用 | 不需要 | 需要：设置 → 智能体 → 浏览器操控 → 安装扩展 |
| 适合 | 公开网页、需要 DOM 与 JS 的确定性操作 | 需要已登录账号的站内流程 |
| 现状 | ✅ 可用 | ⚠️ 本机未开启（可在 UI 一键开） |

**当前会话能用的就是第一条。** 第二条在没有开启前不要假装能用。

---

## 四、与 Third Hand 的分工（已写进 Skill）

```
WorkBuddy Agent
  ├─ 网页 DOM 操作（点击/输入/滚动/读值/截图） → agent-browser
  ├─ 网页只读抓取 / 搜索                        → WebFetch / WebSearch
  ├─ 页面展示给用户                              → present_files（右侧面板）
  ├─ macOS 原生应用                              → Third Hand（wbcu）
  └─ 混合任务                                    → 各自跑，Agent 汇总
```

三条硬规则：

1. **网页有 DOM 就用 DOM**，不要用 `wbcu` 坐标点击去点网页（滚动/改布局就点错，且无法读值验证）
2. **两者不互相代理**。`agent-browser` 不经过 `wbcu`；`wbcu` 也没有全局钩子拦截别人
3. **缺少能力时如实说**，不假装成功

实测混合任务（同一时段并行）：

| 执行者 | 任务 | 结果 |
|---|---|---|
| `agent-browser` | 打开测试页 → 填 `mixed-7x6` → 点击 → 读回 | `结果：已执行 mixed-7x6 / 1794809881025` |
| `wbcu` | 后台 Calculator 算 7×6 | `success`，读数 `42` |
| 前台 | — | 全程 `WorkBuddy`，**0 次切换** |

---

## 五、Not Tested

| 项目 | 状态 | 原因 |
|---|---|---|
| 产品「浏览器操控」通道（`workbuddy-browser-use`） | Not Tested | 本机未启用；开启需在设置里操作并装扩展 |
| 已登录态站内流程 | Not Tested | CLI 通道是隔离 Chromium，不带用户登录态 |
| Chrome/Edge 扩展接管现有标签页 | Not Tested | 同上，扩展未装 |
| 文件上传/下载真实场景 | 未测 | CLI 有 `upload`/`download` 命令，未做端到端验证 |

---

## 六、一句话结论

**Browser Use 在本机是可用的：`agent-browser` CLI 已装、能点、能输入、能滚动、能读值、不抢前台。**
v0.5.0 的「没有接口」结论作废，原因是调查范围只覆盖了主 bundle 字符串。
