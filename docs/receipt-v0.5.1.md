# Third Hand v0.5.1 交付回执

**版本**：0.5.1（main 主线，未新建分支）
**日期**：2026-11-16
**主题**：真正接入 Browser Use + WorkBuddy Agent 端到端验证 + 引擎/技能版本一致性

---

## 1. Browser Use 当前真实可用能力及调用方式

先认错：**v0.5.0 的「本构建没有浏览器交互接口」是错的。**
当时只搜了 `app.asar` 里的工具名，没查插件缓存、CLI、技能注册表。按你说的五层重查后：

| 层次 | 结论 | 证据 |
|---|---|---|
| 产品支持 | ✅ | 官方文档《右侧边栏》《Agent Browser》；应用内含 `browserControl` / `browserUseEnabled` / `workbuddy-browser-use` |
| 本机具备 | ✅ **CLI 通道已装** | `agent-browser 0.27.0` @ `~/.workbuddy/binaries/node/versions/22.22.2-6/bin/`；插件 `codebuddy-plugins-official/agent-browser/1.3.0`（`.in_use` 今日活跃） |
| 需要启用 | CLI 通道**不需要**；产品「浏览器操控」通道需要 | 本机无 browser 技能、无扩展、`app-config.json` 无开关 |
| Agent 可调用 | ✅ 通过 Bash 调 CLI（**不是 MCP 工具**，所以工具列表看不到） | 下方实测 |
| 权限 | 无额外 TCC 要求；用独立 Chromium，不带用户登录态 | 无弹窗 |

调用方式：

```bash
export PATH="/Users/lang/.workbuddy/binaries/node/versions/22.22.2-6/bin:$PATH"
agent-browser open <url>      # 起/复用 daemon
agent-browser snapshot        # DOM + @ref
agent-browser click "#go"     # 或 @ref
agent-browser fill "#q" "文本"
agent-browser get text "#result"   # 读值验证（别只看 ✓ Done）
agent-browser scroll down 600
agent-browser screenshot /tmp/x.png
agent-browser close           # 结束必须关
```

**实测（2026-11-16）**

| 步骤 | 结果 |
|---|---|
| `open file:///tmp/wb-browser-test/index.html` | ✓ 标题 `Third Hand Browser Test` |
| `fill "#q" ThirdHand-42` | ✓ |
| `click "#go"` | ✓ |
| `get text "#result"` | `结果：已执行 ThirdHand-42 / 1794809788724` ← JS 真跑了 |
| `scroll down 700` → `eval window.scrollY` | **400** |
| `screenshot` | 6.7K PNG |
| `close` | ✓ |
| **前台影响** | open→click→close 全程 `WorkBuddy`，**0 次切换** |

## 2. 是否找到此前未发现的浏览器交互工具

**找到两样，v0.5.0 全漏了**：

1. `agent-browser` CLI 0.27.0（+ 官方插件 1.3.0）—— 已装、已跑通，**这是本机当前可用的通道**
2. 产品级「浏览器操控」`workbuddy-browser-use` —— 产品支持但本机未启用（需 UI 一键开 + 装扩展）

漏查原因：只查主 bundle 字符串，没查 `~/.workbuddy/plugins/cache/`、没查 `binaries/`、没查设置项键名。

## 3. WorkBuddy 自然语言任务端到端测试

**这次不是在 shell 里跑脚本冒充**。执行路径是真实 Agent 循环：先 `Skill` 加载
`workbuddy-third-hand`，然后逐步用工具调用完成——每一步都是独立的工具调用 + 读值验证。

任务：「使用 Third Hand 操作 Calculator，计算 125 × 8。首次初始化后我会切换 Safari，请继续后台完成。」

| 检查项 | 实测 |
|---|---|
| Agent 如何选择 Skill | `Skill(workbuddy-third-hand)` 显式加载，技能里先读「该不该用」路由表 |
| 实际用了哪些工具 | `Bash`（调 wbcu）、`Skill`；**没有**用 `open -a`、没有 `osascript activate` 做任务动作 |
| 是否用 `wbcu launch` | ✅ `launch --app com.apple.calculator` → `activated:false, launched:true` |
| 是否复用 Session | ✅ 全程 1 个会话 `s34494`，7 次动作；后续用 `--app` 寻址，无重建 |
| 是否意外调用 `activate` | ❌ 无（`session list` 单会话；trace 归因 0 次 wbcu） |
| 是否重新启动应用 | ❌ 无（只在开头 launch 一次） |
| 外部工具抢前台 | 仅 harness 登记的 1 次「用户切 Safari」，归因 `harness` |
| 最终结果 | ✅ **1000**（`Equals` → `success`，读数 `1,000`） |

逐步耗时（前台始终是 Safari）：

| 步骤 | result | 耗时 | 读数 |
|---|---|---|---|
| AllClear | success | 126 ms | `0` |
| One | success | 86 ms | `1` |
| Two | success | 80 ms | `12` |
| Five | success | 99 ms | `125` |
| Multiply | success | — | — |
| Eight | success | 103 ms | `125×8` |
| Equals | success | 323 ms | `1,000` |

`wbcu trace report`：**1 次前台切换，归因 harness=2（含登记），wbcu=0。**

## 4. 混合任务结果

同一时段并行跑两个执行器：

| 执行者 | 任务 | 结果 |
|---|---|---|
| `agent-browser` | 打开测试页 → `fill mixed-7x6` → `click` → 读回 | `结果：已执行 mixed-7x6 / 1794809881025` |
| `wbcu` | 后台 Calculator 算 7×6 | `success`，读数 **42** |
| 前台 | — | 全程 `WorkBuddy`，**0 次切换** |

两者没有互相经过对方：浏览器走 CLI，桌面走 wbcu，Agent 汇总。

## 5. 前台应用变化及调用来源

| 场景 | 前台变化 | 归因 |
|---|---|---|
| 自然语言任务（Calculator 125×8） | 1 次（WorkBuddy → Safari） | `harness`（我用 osascript 模拟用户切换并登记） |
| Browser Use 全链路（open/click/close） | 0 次 | — |
| 混合任务并行 | 0 次 | — |
| `wbcu launch` 启动 Calculator | 0 次 | — |

`wbcu` 命令自身在三次场景中**零次**导致前台变化。

## 6. Skill 与 Engine 版本一致性测试

新增 `wbcu doctor`（10 项）+ `tests/regression/version-consistency.sh`（7 项断言）。

安装后实测输出：

```
Third Hand 安装自检  engine=0.5.1  skill=0.5.1
✅ engine_version / skill_file / version_match / skill_commands
✅ installed_binary / overlay / smoke
✅ git（已安装副本，不在仓库内 → 跳过）
✅ skill_lines（254 行） / session_gc（2 个会话文件）
结论：一致，可直接用
```

漂移检测测试（真实改坏再还原）：

```
✅ 漂移时 doctor 退出码非 0（1）
✅ 漂移被 version_match 明确点名
✅ 还原后 doctor 恢复正常
```

另外加了单元 lint：`doctor` 的命令白名单必须与 `main.swift` 的 switch 完全一致（42 条），
防止以后加命令忘了登记。

## 7. 实际修改的文件

| 文件 | 改动 |
|---|---|
| `src/SessionManager/Doctor.swift`（新增） | 10 项自检；解析技能 frontmatter 版本；扫描技能引用的 `wbcu <cmd>`；已安装副本跳过 git 锚点 |
| `src/SessionManager/Session.swift` | `pruneSessions()` + `session prune` 子命令 + `session start` 时文件 >20 自动清理 |
| `src/main.swift` | 注册 `doctor`；版本 0.5.0 → 0.5.1 |
| `scripts/build.sh` | CFBundle 版本同步 0.5.1 |
| `scripts/install.sh` | **技能改为默认安装**（`--no-skill` 跳过）；装完自动跑 doctor（不阻断） |
| `skills/workbuddy-third-hand/SKILL.md` | 加 `version: 0.5.1`；重写浏览器章节（agent-browser 可用 + 示例 + 实测）；补 doctor/prune 诊断 |
| `docs/browser-use.md` | **整篇重写**，开头标注「本文件推翻 v0.5.0 结论」 |
| `tests/regression/version-consistency.sh`（新增） | 7 项断言，含人为制造漂移 |
| `tests/unit/run.sh` | 新增命令白名单一致性 lint |
| `src/GhostCursor/Ghost.swift` | daemon 写 pid 文件 + 注册 SIGTERM（让 stop 可验证） |
| `src/InputDispatcher/Targeted.swift` | `ghost stop` 改为「quit → 等 → TERM → KILL → 复核」，退出码如实 |
| `CHANGELOG.md` | 0.5.1 条目（含纠错与 ghost stop 修复） |

**只改了 Ghost 的「停止」路径**，视觉与绘制一行没动；AX 引擎、定向投递、Visibility、
Experience 全部未触碰。

### 7.1 顺手修掉的一个真 bug

回归时发现 `ghost stop` 是**假装成功**：打印「已停止」但进程还在（实测 pid 52987 需要
SIGTERM 才退）。旧实现发完 `quit` 就删 socket 并无条件报成功。
现在改成 quit → 等 1.5s → SIGTERM → SIGKILL → `kill(pid,0)` 复核，失败退出码 1。

## 8. 性能变化

| 指标 | v0.5.0 | v0.5.1 |
|---|---|---|
| 数字键点击（含验证） | 60–88 ms | 80–103 ms（波动在噪声范围） |
| `Equals`（结果落在另一个元素） | 280 ms | 323 ms（同一路径，波动） |
| `session start`（复用） | 94 ms | 94 ms（未变） |
| `wbcu launch` 前台变化 | 0 | 0 |
| `doctor` 开销 | — | 仅手动/安装时跑，不进任务路径 |
| 会话文件数 | 15（累积） | 2 |

结论：**没有为了这轮改动增加任何任务路径上的开销**；新增的 doctor 只在安装和显式调用时执行。

## 9. 尚未解决的问题

| 问题 | 状态 | 说明 |
|---|---|---|
| 产品「浏览器操控」通道 | **未启用** | 需在 设置 → 智能体 → 浏览器操控 里开并装扩展；开启前不假装可用 |
| `agent-browser` 不在默认 PATH | 已知 | 在 WorkBuddy 托管 node 目录下；技能里写明 export 语句，未擅自改用户 shell 配置 |
| CLI 通道不带登录态 | 设计如此 | 需要已登录站内流程时，只能走产品「浏览器操控」通道 |
| 真实用户并发操作 | 未重跑 | v0.4.3 测过（968/977 条真实输入、0 次归因 Agent），本轮未重复 |
| 多显示器真机 | Not Tested | 本机单屏 |
| Electron / 游戏类自绘窗口 | Not Tested | 无安全可驱动实例 |

## 10. Git 更新记录

- 主线直接提交并推送（按你要求，不再建 PR）
- 提交内容：代码（doctor + prune）+ 技能 + 文档 + 测试
- 标签：`v0.5.1`
- 回滚：`git revert <merge|commit>` 或 `git checkout v0.5.0` 后 `bash scripts/install.sh`

```bash
cd /Users/lang/WorkBuddy/macos-background-computer-use
git log --oneline -3
git tag --points-at HEAD
```

---

## 附：这轮最该记住的两件事

1. **判断「有没有某个能力」，要查能力注册表**（插件缓存 / CLI / 技能 / 设置键），
   不能只搜主 bundle 字符串。v0.5.0 就是栽在这里。
2. **安装脚本的默认值就是可靠性边界**。默认不装技能 = 默认允许版本漂移。
   现在技能默认装 + 装完自检，漂移在安装那一刻就会暴露。
