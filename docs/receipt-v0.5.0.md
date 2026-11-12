# Third Hand v0.5.0 交付回执

**版本**：0.5.0（分支 `feat/nonblocking-refinement`，基线 = v0.4.2 + v0.4.3 审计）
**日期**：2026-11-12
**主题**：非阻塞能力优化与 Browser Use 协同
**原则**：不新增任何阻塞 / 审批 / 前台守卫；只做「少抢前台、少重复初始化、点得更准、留下证据」

---

## 1. 实际检查的源码位置

| 文件 | 检查内容 | 结论 |
|---|---|---|
| `src/InputDispatcher/Input.swift:376` | `cmdActivate` —— 全库唯一的 `app.activate()` | 只被显式 `wbcu activate` 调用，`act` / `session click` 路径不碰它 |
| `src/SessionManager/Session.swift:219` | `sessionStart` | **每次新建 id、重算整树指纹、阻塞式拉起 ghost daemon**；不检查已有会话 |
| `src/SessionManager/Session.swift:470` | `sessionClick` 目标解析 | 只有 `--element`（下标）与 `--text`（标签）两条路，没有 `--identifier` |
| `src/InputDispatcher/Targeted.swift:171` | `ensureGhostDaemon` | 会话建立时就同步等待 daemon 就绪（最多 2.5s） |
| `src/InputDispatcher/Targeted.swift:452` | 期望状态读值 | `waitFor(path:)` 死等主元素路径，路径不对时白等满 `maxWaitMs` |
| `src/InputDispatcher/ExpectedState.swift:120` | `locate` | `role:xxx` 只取「第一个有值的」，无下标；无「按值搜索」能力 |
| `src/GhostCursor/Ghost.swift` | 光标窗口 | v0.4.2 的 126×126 小窗 + 可见性抑制，未改动 |
| `src/SessionManager/Guard.swift:57` | `enforceGuard` | 已有的 per-app 白名单（v0.3.x 引入）。**本轮没有新增任何门禁**，保留它 |

检查方法：`grep -rn "activate(\|AXRaise\|orderFront\|makeKeyAndOrderFront"` 全库扫描，
结果只有 `cmdActivate` 一处 + Ghost 自己的 `orderFrontRegardless`（LSUIElement，不参与激活）。

---

## 2. 发现的真实问题

| # | 问题 | 证据 |
|---|---|---|
| P1 | **全库没有「后台启动应用」的能力** | 唯一做法是 `open -a` / `osascript activate`。实测 `open -a Calculator` → 前台从 WorkBuddy 变计算器，**1 次前台变化** |
| P2 | **会话不复用，每次 start 都重新初始化** | 190ms/次；新建 id、重算整树指纹、拉起 daemon |
| P3 | **Agent 必须记住 session id** | 忘了 id → 重新 `session start` → 容易连带重新 `open -a` → 再抢一次前台 |
| P4 | **标签寻址会漂** | 计算器清除键标签在 清除 / 全部清除 / C 之间切换，`--text 清除` 实测直接 `no_pressable_element` |
| P5 | **结果行是「动作后才出现的新元素」** | 按下 `=` 后 AXStaticText 从 1 个变 2 个：主元素是表达式行 `125×8`，结果 `1,000` 在第二个元素上。旧逻辑死等主元素 → 700ms 后判 failure |
| P6 | **没有任何机制能回答「谁抢了前台」** | 只能靠肉眼和猜 |
| P7 | **Browser Use 在本构建里没有可编程接口** | 见第 3 节与 `docs/browser-use.md` |

---

## 3. Browser Use 的实际调用方式（调查结论）

调查方法（全部可复现，详见 `docs/browser-use.md`）：应用包字符串扫描、插件缓存枚举、
连接器市场枚举、扩展产物查找、官方文档检索、运行时工具清单核对。

| 能力 | 本构建是否可用 | 实际接口 |
|---|---|---|
| 网页内容读取 / 搜索 | ✅ | `WebFetch` / `WebSearch` |
| 页面展示（内置右侧面板） | ✅ | `present_files(url)` / `present_files(html)` |
| 网页内点击 / 输入 / 滚动 / DOM 查询 / 标签页 | ❌ **无接口** | — |
| 外部浏览器扩展通道 | ❌ | 未找到扩展产物或连接器 |

**结论：不存在「能让 Agent 点击网页按钮」的 Browser Use 工具。**
所以本轮的协同方式是**如实划界**，而不是造一个假接口，也不是用坐标点击去冒充。

---

## 4. 协同方案

```
WorkBuddy Agent
  ├─ 网页内容读取 / 搜索  → WebFetch / WebSearch
  ├─ 页面展示给用户       → present_files（内置右侧面板，只渲染）
  ├─ macOS 原生应用       → Third Hand（wbcu）
  └─ 混合任务             → 各做各的，Agent 负责串结果
```

三条硬规则（已写进 Skill）：

1. **不得用坐标点击冒充网页交互**
2. **Browser Use 的调用不经过 Third Hand**（Third Hand 没有全局钩子，也不打算有）
3. 网页交互无接口时**如实报告能力缺失**，不假装成功

---

## 5. 最小代码修改

| 文件 | 改动 |
|---|---|
| `src/SessionManager/Trace.swift`（新增，约 300 行） | 被动激活追踪：`NSWorkspace.didActivateApplicationNotification` 事件驱动 + 命令开始/结束时间戳（`atexit` 补 t1）+ 四类归因 + `trace mark` 脚手架标记 |
| `src/InputDispatcher/Input.swift` | 新增 `cmdLaunch`：`NSWorkspace.OpenConfiguration.activates = false`；已在运行则直接返回 |
| `src/SessionManager/Session.swift` | `liveSession(forBundleId:)` + `sessionStart` 复用（`--new` 可强制新建）+ `needSession` 支持 `--app` + `--identifier` 寻址 + `createSession` 抽出 |
| `src/InputDispatcher/Targeted.swift` | `ensureGhostDaemon(waitForReady:)` 非阻塞预热；期望读值改三段式（快读 → 120ms 等变化 → 按值搜索 → 才用 maxWaitMs） |
| `src/InputDispatcher/ExpectedState.swift` | `searchValue(pid:expected:mode:)`；选择器支持 `role:AXStaticText[1]` 下标；`evaluate(... elsewhere:)` |
| `src/main.swift` | 注册 `trace` / `launch`；命令启动时写追踪标记（仅追踪器在跑时） |
| `skills/workbuddy-third-hand/SKILL.md` | 新增「网页 vs 原生」路由表、`wbcu launch` 用法、`--identifier`、`trace` 诊断 |
| `tests/regression/no-reactivation.sh`（新增） | 13 项断言，见第 6 节 |

**没有做的事**：没有新增审批、没有提前台守卫、没有改 Browser Use、没有动 Ghost Cursor 的视觉。

---

## 6. 运行过的测试

### 6.1 测试 A：原生应用（自然语言任务）

指令：「使用 Third Hand 操作 Calculator，计算 125 × 8。首次打开后我切到 Safari，继续在后台完成。」

`tests/regression/no-reactivation.sh` **13/13 通过**：

```
✅ 追踪器已启动
✅ 后台启动成功且未激活（activated=false）
✅ 启动后前台未变（WorkBuddy）
✅ 已在运行时 launch 不重复启动、不激活（alreadyRunning=true）
✅ 重复 launch 后前台仍未变
✅ 同一 App 复用同一会话（s48416），没有重复初始化
✅ harness 切换确实改变了前台（WorkBuddy → Safari浏览器）
✅ 7/7 步验证通过（含结果行与表达式行分离的那一步）
✅ 最终读数为 1,000
✅ 计算全程前台停在用户的应用（Safari浏览器）
✅ 0 次前台变化归因于 wbcu 命令
✅ 0 次未登记的外部 activate
✅ ghost 进程已清理
```

逐步耗时（前台始终是 Safari）：

| 步骤 | result | 耗时 | 读到的值 |
|---|---|---|---|
| AllClear | success | 89.0 ms | `0` |
| One | success | 66.9 ms | `1` |
| Two | success | 69.8 ms | `12` |
| Five | success | 87.8 ms | `125` |
| Multiply | success | 84.6 ms | — |
| Eight | success | 70.2 ms | `125×8` |
| Equals | success | **280.0 ms** | `1,000` |

### 6.2 测试 B / C：Browser Use

| 项目 | 结果 | 说明 |
|---|---|---|
| 调用内置 Browser Use 完成网页交互 | **Not Tested / 不可用** | 本构建未暴露浏览器交互接口（第 3 节）。**不用坐标点击替代** |
| 网页内容读取 | ✅ | `WebFetch https://example.com` → 标题 `Example Domain` + 正文首句 |
| 页面在右侧面板展示 | ✅（能力存在） | `present_files(url)`；这是用户自己的 WorkBuddy 窗口，不改变目标应用状态 |
| 外部浏览器（Chrome / Edge） | Not Tested | 未找到扩展通道；不尝试破解 |

### 6.3 测试 D：混合任务

同一时段内：`WebFetch` 读 `example.com`（标题 `Example Domain`）+ Third Hand 在后台算 `7 × 6`。

| 部分 | 执行者 | 结果 |
|---|---|---|
| 网页读取 | `WebFetch` | 标题与正文首句取回 |
| 原生计算 | Third Hand | `Seven → 7`、`Multiply`、`Six → 7×6`、`Equals → 42（success）` |
| 前台 | — | 全程 WorkBuddy，未变 |
| 互相干扰 | — | 无（两者不共享执行通道，也没有门禁） |

### 6.4 全量回归（保持通过）

| 测试 | 结果 |
|---|---|
| `cursor-window-bounds` | 全部通过 |
| `background-targeted-click` | 全部通过 |
| `window-switch-isolation` | 全部通过 |
| `occlusion-behavior` | 全部通过 |
| `occlusion-layers` | 全部通过 |
| `ghost-cleanup` | 全部通过 |
| `no-reactivation`（新增） | 13/13 |
| `selftest` | **53/53** |

---

## 7. 未通过 / 未测试

| 项目 | 状态 | 原因 / 风险 |
|---|---|---|
| 网页内交互（点击/输入/滚动） | **不可用** | 构建未暴露接口。风险：用户若要求「帮我点网页上的按钮」，只能如实说做不到 |
| 外部浏览器自动化 | Not Tested | 无扩展通道 |
| 多显示器真机 | Not Tested | 本机只有一块内建屏（数学逻辑已有 15 项纯函数自检） |
| 跨 Space 窗口 | Not Tested | 未构造真机场景 |
| Electron 应用 | Not Tested | 本机无安全可驱动实例 |
| 计算器 `Six` 那一步判 failure | **预期行为** | 期望写 `6`、实际显示 `7×6`；引擎判 failure 是对的（是我的期望值写错） |

---

## 8. 优化前后速度

| 指标 | 修前 | 修后 | 变化 |
|---|---|---|---|
| `open -a` 启动造成的前台变化 | 1 次 | — | — |
| `wbcu launch` 启动造成的前台变化 | — | **0 次** | 消除 |
| `session start`（首次） | 190 ms | 190 ms | — |
| `session start`（复用） | 每次 190 ms | **94 ms** | −50% |
| 数字键点击（含验证） | 60–80 ms | 60–80 ms | 持平 |
| 结果落在另一个元素的那一步（`=`） | **739.9 ms + 判 failure** | **282.6 ms + success** | −62%，且结论正确 |
| 全程前台变化（后台任务） | 1+ 次（每次 `open -a`） | **0 次** | 消除 |
| 追踪器开销 | — | 命令路径 1 次 `stat`（约 0.02 ms），daemon 纯事件驱动 | 可忽略 |

---

## 9. 是否增加了额外阻塞

**没有。** 具体核对：

| 检查项 | 结果 |
|---|---|
| 新增审批 / 确认步骤 | 无 |
| 新增前台状态守卫 | 无（`Visibility` 只判定不拦截，v0.4.2 已如此） |
| 新增同步锁 / 定时等待 | 无。反而去掉两处等待：ghost 预热改为非阻塞、期望读值不再死等满超时 |
| 命令路径新增 I/O | 1 次 `stat`（判断追踪器是否在跑），追踪器没跑时零文件写入 |
| 失败是否会让任务停下 | 不会。`act` / `session click` 语义不变，只是结论更细 |
| 是否破坏既有 Skill 调用 | 否。所有旧参数保留，`--new` / `--identifier` / `--app` 是新增可选 |

---

## 10. Git、版本与维护

### 10.1 当前实际状态（2026-11-12 核验）

> 这里不写死「main = 某个 SHA」——每提交一次它就变，写死必然过期。
> 要取当前值，跑下面两条命令即可。

```bash
git -C /Users/lang/WorkBuddy/macos-background-computer-use log --oneline -1        # 当前 main 顶端
git -C /Users/lang/WorkBuddy/macos-background-computer-use rev-parse --short 'v0.5.0^{}'  # 标签指向
```

| 项 | 值 |
|---|---|
| 代码合并点（稳定锚点） | `17a0d4c` —— PR #6 合入点，含 v0.4.2 → v0.4.3 审计 → v0.5.0 全部代码 |
| 标签 `v0.5.0` | 已推送，指向 main 顶端（轻量标签，与历史 v0.3/v0.4.x 一致） |
| 标签 `v0.4.2` | `5f9081e`（本次补推；之前只存在于本地） |
| 已安装二进制 | `~/.local/bin/wbcu` = **0.5.0**，sha256 前缀 `afd4e5b96366580a` |
| 已安装技能 | `~/.workbuddy/skills/workbuddy-third-hand/SKILL.md` = **231 行**（含 v0.5.0 路由） |
| 覆盖层 | `~/.local/share/wbcu/ThirdHandOverlay.app`（LSUIElement） |

安装命令（本次已执行）：

```bash
cd /Users/lang/WorkBuddy/macos-background-computer-use && bash scripts/install.sh --skill
```

> 坑：`install.sh` 默认只装二进制，**技能要显式带 `--skill`**。
> 第一次漏了这个参数，结果是二进制升到 0.5.0、技能还停在 0.4.2（177 行），
> 技能里会教 `wbcu launch` 这种不存在的命令。已修正。
> 复核方式：`wc -l ~/.workbuddy/skills/workbuddy-third-hand/SKILL.md`（应为 231）。

### 10.2 安装后冒烟

```
~/.local/bin/wbcu version                → 0.5.0
~/.local/bin/wbcu launch --app com.apple.calculator --json
                                        → ok:true, alreadyRunning:true, activated:false
~/.local/bin/wbcu session click --app com.apple.calculator --identifier Two --json
                                        → ok:true, method:ax, result:success
~/.local/bin/wbcu trace status          → · 未追踪
```

### 10.3 回滚

```bash
git checkout v0.4.2 && bash scripts/install.sh --skill   # 回到 v0.4.2 行为
git revert -m 1 17a0d4c                                # 撤掉那次合并
```

### 10.4 后续维护要点

1. **新命令**：`wbcu trace start|report|stop|mark`、`wbcu launch --app <id> [--foreground]`
2. **新参数**：`session start --new`、`session <子命令> --app <bundleId>`、`session click --identifier <id>`、`--expect-el role:X[n]`
3. 遇到「又抢前台」的报告，第一步永远是 `wbcu trace start` → 复现 → `wbcu trace report`，
   看归因是 `wbcu` / `external` / `user`，再决定改哪里
4. `external` 归因出现时，先查是否有人（Agent 自己）在任务里用了 `open -a` / `osascript activate`
5. 发布流程：**直接 commit 到 main 并 push**，不再建 PR（用户 2026-11-12 明确要求）
