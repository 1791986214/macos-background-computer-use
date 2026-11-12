---
name: workbuddy-third-hand
description: WorkBuddy Third Hand —— 给 WorkBuddy 的第三只手。用 macOS 原生技术（ScreenCaptureKit + Accessibility + 进程级事件投递 + 独立虚拟光标）在后台操作指定应用，优先不抢占用户真实鼠标、不切换前台、不抢键盘焦点，并且每次操作都读值验证。当用户要求「帮我操作另一个 Mac 应用」「在后台完成桌面任务」「不要影响我正在用的鼠标」「读一下另一个应用里的信息」「点一下那个按钮」「同时在两个应用里干活」「用虚拟鼠标操作某个窗口」，或需要在 Finder / 计算器 / 文本编辑 / Safari / Electron 应用里做自动化时使用。
agent_created: true
---

# WorkBuddy Third Hand

给 WorkBuddy 的第三只手：让它在后台操作**别的** macOS 应用，而用户可以继续用鼠标和键盘。

核心承诺（也是验收标准）：**真实鼠标零位移、前台应用不切换、键盘焦点不被抢**，
同时目标应用里的 UI 真的发生了变化 —— 而且这个变化是被**读值验证**过的，不是「命令返回 0 就算成功」。

---

## 一、先判断该不该用

按这个顺序想，**不要跳步**：

| 顺序 | 手段 | 什么时候用 |
|---|---|---|
| 1 | CLI / API / 连接器 | 目标系统有接口（git、curl、企业微信、云盘…）→ 直接调，不用 GUI |
| 2 | AppleScript / `open` / 快捷键 | 系统级、语义明确、无需看界面 |
| 3 | **本技能（后台 Computer Use）** | 只有 GUI 能完成，且用户不想被打扰 |
| 4 | 请用户自己点 | 需要人的判断、涉及不可逆高风险操作 |

本技能是**第 3 档**，不是万能替代品。能在终端里干的事不要动 GUI。

### 网页 vs 原生：先选对工具（v0.5.0）

| 目标 | 用什么 | 说明 |
|---|---|---|
| 网页内容读取 / 搜索 | `WebFetch` / `WebSearch` | 只读抓取，不碰用户浏览器 |
| 页面展示给用户 | `present_files`（内置右侧面板） | 用户自己的 WorkBuddy 窗口，不影响目标应用 |
| 网页内点击 / 输入 / 滚动 | **本构建没有该接口** | 不要用坐标点击冒充浏览器自动化，见下 |
| macOS 原生应用 | 本技能（`wbcu`） | 本技能的强项 |
| 混合任务 | 各自做自己那段 | WorkBuddy 负责串，两边互不代理 |

**红线：不要用 `wbcu` 的坐标点击去点网页元素。**
坐标点击落在「屏幕上那个位置」，页面一滚动/改布局就点错，而且读不到页面状态来验证结果。
需要网页交互但没有接口时，**如实说能力缺失**，不要假装成功。

完整调查见 `docs/browser-use.md`。

---

## 二、开工前必做的三件事

```bash
wbcu capabilities --json     # ① 能力与权限：AX / 屏幕录制 / 输入注入各自是否可用
wbcu guard --list            # ② 已授权应用白名单
wbcu launch --app <bundleId> --json          # ③ 需要时才启动；**别用 open -a**
wbcu session start --app <bundleId> --json   # ④ 建会话（会做授权检查，未授权直接拒绝）
```

`wbcu launch` 与 `open -a` 的区别是硬区别：前者 `activates=false`，应用在后台起来，
用户的前台窗口不动；后者必然把目标顶到最前。**已经在跑就什么都不做**（重复 `open -a`
正是「每步都抢前台」的常见来源）。

- 权限不足 → 明确告诉用户缺哪一项、去「系统设置 → 隐私与安全性」开哪个，**不要试图绕过**。
- 应用不在白名单 → 用 `wbcu guard --app <bundleId> --allow`，且必须**先得到用户对该应用的明确同意**。
- 会话 id 形如 `s12345`，后续所有动作都带 `--id`，不要每步重新解析窗口。

> 中文系统里应用名和 bundle id 不一致：`TextEdit` 叫「文本编辑」，`Calculator` 叫「计算器」。
> 名字匹配不上就立刻换 bundle id。

---

## 三、标准工作流（照这个顺序做）

```bash
# 1. 建会话（同 App 已有活会话 → 自动复用，不重新初始化；要强制新建加 --new）
SID=$(wbcu session start --app com.apple.calculator --json | jq -r .session.id)

# 2. 看界面：先 AX 树（便宜、精确），需要像素再截图
wbcu session inspect --id $SID --max 200
wbcu session capture --id $SID --out /tmp/cap.png

# 3. 操作：优先语义（按 identifier 或文本），其次坐标
#    --app 直接寻址：不用记 session id，也就不会「忘了 id → 重新 start → 重新拉窗口」
wbcu session click --app com.apple.calculator --identifier Multiply --exact
wbcu session click --app com.apple.calculator --text "全部清除" --exact
wbcu session click --id $SID --text "全部清除" --exact
wbcu session click --id $SID --element 12
wbcu session click --id $SID --x 388 --y 557 --label "7"

# 4. 写文本：AXValue 优先，键盘只作兜底
wbcu session type --id $SID --text "要填的内容" --element 18

# 5. 验证：必须读值，不要读 ok
wbcu session verify --id $SID --expect "42"

# 5b. 更硬的写法：把期望直接挂在动作上（v0.4.3）
#     result 四分类：success / already_satisfied / failure / inconclusive
wbcu session click --id $SID --identifier One --exact \
  --expect 7 --expect-el role:AXStaticText
# 幂等操作显式声明，避免把「本来就不该变」当成失败
wbcu session click --id $SID --text "全部清除" --exact \
  --expect 0 --expect-el role:AXStaticText --idempotent

# 6. 收尾：释放会话（最后一个会话结束时自动隐藏虚拟光标）
wbcu session end --id $SID
```

## 性能与经验（2.0）

默认就走快路径，不用额外参数：

| 参数 | 默认 | 什么时候改 |
|---|---|---|
| `--ghost-mode` | `fast`（先投递，动画并行） | 要给用户看操作过程 → `demo` |
| 经验复用 | 开 | 界面刚变过、怕旧路径误导 → `--no-experience` |
| 验证 | 指纹单次扫描 | 想看 AX 通知是否可用 → `--observe-watch` |

熟练后的典型耗时（Calculator，引擎内）：冷启动 ~110ms，命中 ~77ms。

```bash
# 想证明「越用越快」时，跑这个，别口头说
wbcu bench --app com.apple.calculator --iters 5 --cold
wbcu bench --app com.apple.calculator --iters 5
wbcu perf stats
```

经验库只能加速**找目标**，不能替代验证。任务结束后可以 `wbcu experience stats`
看学到了多少条；怀疑学到脏数据时 `wbcu experience clear --app <bundleId>`。
```

**一次任务只建一个会话，结束必须 `end`。** 忘掉 `end` 会留下状态文件，下次 `session list` 会脏。

---

## 四、操作优先级（硬规则）

```
AX 语义动作  →  进程级定向投递  →  坐标点击  →  全局 HID（需批准）
```

1. **`--element` / `--text` 走 AXPress**：不激活、不需要坐标、对遮挡完全免疫。首选。
2. **`--x --y` 走定向投递**：`postToPid` + 窗口号(字段 51) + 窗口局部坐标。目标被遮挡也能点中。
3. **`--allow-global` 才动真实鼠标**：会移动用户的指针。**没有用户明确同意，绝不加这个参数。**
   也不许用「先移过去点一下再移回来」伪装无干扰——那是欺骗。

`--verify` 默认开启：操作后对比 AX 树指纹，返回三态之一：
- `changed` —— UI 真的变了，可以继续
- `no_observable_change` —— 动作被接受了但界面没差异（例如本来就是清零状态）。**不等于失败**，往下走但别声称"已完成"
- `not_requested` —— 没验证。**不要在这种情况下对用户说"已完成"**

---

## 五、必须遵守的约束

- **鼠标分离**：Agent 光标（紫箭头）是独立可视化层，与系统鼠标无任何关系。永远不要读/写真实指针位置来"同步"。
- **不切换前台**：除非用户要求，不调 `wbcu activate`，也不要在任务中途跑
  `open -a` / `osascript ... activate`。这两条是「每步都抢前台」最常见的原因，
  用 `wbcu trace` 能直接看到归因。
- **不抢键盘焦点**：`key` 命令走 `postToPid`，不进全局事件流。
- **只碰授权应用**：每个 app 单独授权，白名单外的操作会被引擎直接拒绝（exit 3）。
- **失败就说失败**：返回 `ok:false` 或 `no_observable_change` 时如实报告，禁止编造"已完成"。
- **高风险先问**：删除、提交、发送、支付、覆盖文件——先描述将要发生什么，等用户确认。
- **结束要清理**：`session end`；长任务中断也要 end（或 `wbcu ghost hide` + `session end --all`）。

---

## 五点五、诊断命令（v0.4.3）

```bash
wbcu occlusion --window <id> --x <x> --y <y>   # 谁压在目标上面？完整 z 序
wbcu vis --window <id> --x <x> --y <y>         # 可见性状态（front/background/遮挡/最小化）
wbcu displays                                   # 显示器几何与缩放
wbcu compat                                     # 未文档化字段的版本闸门与逐应用退让
wbcu focus --window <id>                        # keyWindow / 第一响应者
wbcu trace start / report / stop                # 被动记录前台切换并做责任归因
wbcu launch --app <bundleId>                    # 后台启动，不抢前台
```

用法要点：

- 点到没反应时，先 `wbcu occlusion` 看是不是被挡了；再 `wbcu vis` 看状态。
- `result=inconclusive` 不代表成功也不代表失败：给个 `--expect` 再来一次。
- 跨应用稳定性存疑时看 `wbcu compat`：某应用若被降级（`degraded=true`），
  说明它连续 3 次投递后验证失败，引擎会自动改为 AX 优先。

## 六、能力边界（实测，别硬扛）

| 场景 | 结果 | 该怎么绕 |
|---|---|---|
| 标准控件（NSButton / 输入框 / 菜单） | ✅ AX + 定向都成 | 直接用 |
| 被其他窗口完全遮挡 | ✅ 定向投递可点 | 照常操作 |
| 自绘视图（Canvas） | ⚠️ 取决于目标是否 `acceptsFirstMouse` | 先 AX；不行则请用户把窗口露出来 |
| WKWebView 里的按钮 | ✅ 走 AX（`AXWebArea → AXButton`） | 坐标事件对它无效，别浪费次数 |
| 非激活窗口里打字 | ❌ 没有 field editor | 用 `session type`（写 AXValue），不要指望按键 |
| 依赖 key window 的快捷键（Cmd+W） | ❌ 常无效 | 改用 AX 点「关闭按钮」 |
| 拖拽 | ⚠️ mouseDown 能到，但会话不建立 | 需要用户在场或改用 AX 的 `AXShowMenu` 等替代 |
| Chromium / Electron | 未充分验证 | 先试 `inspect`，能读到树就走 AX；读不到就报告限制 |

**遇到新兼容性问题不要绕开就忘**：记录「应用 + 版本 + 症状 + 最小复现」，
写进 `docs/capability-matrix.md`，这次没修也要留下证据。

---

## 七、排错

| 症状 | 原因 | 处理 |
|---|---|---|
| `permission_denied` | TCC 没授权 | 告诉用户开哪一项，`wbcu perm --prompt` 可触发弹窗 |
| `window_not_found` | 应用没运行 / 只有附属窗 | 先 `wbcu apps`，必要时 `open -g -a <app>`（后台启动不抢焦点） |
| `target_gone` | 目标退出或窗口关了 | 重新 `session start`，不要复用旧 id |
| `no_pressable_element` | index 过期或文本没匹配 | 重新 `inspect` —— index 只对最近一次快照有效 |
| 点击返回 ok 但界面没动 | 首次点击被吞（用于激活窗口） | 再点一次；或先用 `--element` 走 AX |
| 屏幕里有紫胶囊 | 有窗口级持续捕获在进行 | 正常现象，是系统的共享提示；`wbcu stream` 结束后会消失 |
| 光标不显示 | ghost daemon 没起 | `wbcu ghost start`；不影响实际操作 |

---

## 八、给用户看的东西

- 动画时长与层级已对齐系统观感（层级 102，能盖普通窗口和菜单，不盖系统 HUD）。
- 虚拟光标可关：`--no-ghost` 或 `wbcu ghost hide`，**关掉不影响操作**。
- 结束报告要包含：做了什么、每步验证结果、真实鼠标是否移动、前台是否变化、有没有残留。

---

## 九、参考

- **可直接照抄的最小流程**：`examples/quickstart.md`（同目录下，六步跑通一次后台操作）
- 命令与退出码速查：`references/api.md`
- 架构与实测数据：仓库 `docs/architecture.md`、`docs/capability-matrix.md`
- 权限细节：`docs/permissions.md`
- 安装与恢复：`docs/installation.md`
- 排错手册：`docs/troubleshooting.md`
