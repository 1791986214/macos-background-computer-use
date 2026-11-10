# 架构

## 分层

```
┌─ Agent（WorkBuddy / 任何调用方）──────────────────────────┐
│  MCP: cu_session / cu_click / ...                        │
│  CLI: wbcu session ...                                   │
└───────────────────────────┬──────────────────────────────┘
                            │  JSON（一次调用 = 一个进程）
┌───────────────────────────▼──────────────────────────────┐
│ SessionManager   会话状态、授权闸门、错误码               │
│   Session.swift      start/capture/inspect/click/verify   │
│   Guard.swift        per-app 白名单（副作用前置拦截）      │
│   Perms.swift        TCC 三态 + 责任进程归因              │
│   SelfTest.swift     纯逻辑自检（CI 用）                  │
└───────┬──────────────────┬───────────────────┬───────────┘
        │                  │                   │
┌───────▼────────┐ ┌───────▼─────────┐ ┌───────▼──────────┐
│ Accessibility  │ │ InputDispatcher │ │ WindowCapture    │
│  AX.swift      │ │  Targeted.swift │ │  Capture.swift   │
│  Apps.swift    │ │  Input.swift    │ │  Indicator.swift │
│  读树/按点找元素│ │  定向投递/全局   │ │  单帧/持续/像素   │
└───────┬────────┘ └───────┬─────────┘ └───────┬──────────┘
        │                  │                   │
        │           ┌──────▼───────┐           │
        │           │ GhostCursor  │           │
        │           │  Ghost.swift │           │
        │           │ 独立 daemon  │           │
        │           └──────────────┘           │
┌───────▼──────────────────▼───────────────────▼──────────┐
│ macOS: Accessibility API / CGEvent / ScreenCaptureKit   │
└─────────────────────────────────────────────────────────┘
```

### 为什么会话状态落盘而不是常驻 daemon

- **错误隔离**：每条命令一个进程，一条命令崩了不影响会话。
- **无生命周期陷阱**：不会出现「daemon 半死、socket 还在、后续全部超时」。
- **可审计**：`~/.wbcu/sessions/<id>.json` 是纯文本，出问题直接看。

代价：每次命令多一次进程启动（约 60–80ms）。相对 AX 往返与动画时长，可以忽略。

唯一的常驻进程是 Ghost Cursor daemon —— 因为它必须持有窗口并持续动画。
它被设计成**可以随时死掉**：死了只是看不见光标，操作照常。

---

## 一次后台点击的完整路径

```
session click --id s1 --x 388 --y 557
  │
  ├─ ① 加载会话，刷新窗口 frame（窗口可能被移动过）
  │
  ├─ ② Ghost Cursor：屏幕坐标 → 窗口局部坐标 → 动画移动（easeOutCubic 0.24s）
  │       失败？继续。可视化层不可用不影响操作。
  │
  ├─ ③ 输入：先 AX
  │       findPressableElement(pid, point)
  │         └─ 在**目标应用自己的树里**按矩形包含 + 面积最小找可 AXPress 元素
  │            （不能用 AXUIElementCopyElementAtPosition：被遮挡时它返回遮挡者的元素）
  │       AXPress 成功 → mode=ax，结束
  │       AXPress 失败 → ④
  │
  ├─ ④ 定向投递 targetedClick
  │       mouseMoved 预热（带窗口号）      ← 规避「非激活窗口首击被吞」
  │       mouseDown ×N + mouseUp ×N
  │       每个事件：字段51=窗口号, 字段58=1, CGEventSetWindowLocation(窗口局部坐标)
  │       postToPid(pid)
  │
  ├─ ⑤ 观察：AX 指纹前后对比
  │       changed / no_observable_change / not_requested
  │
  └─ ⑥ 回写：光标绿环=变了，红环=没变；状态存盘
```

**只在 ③ 失败时进入 ④**，不在「③ 成功但没看到变化」时升级。
`AXPress` 返回 `.success` 表示应用接受了这个语义动作；此时再补一次坐标点击，
对幂等按钮无害，对**非幂等按钮（复制、发送、+）就是重复执行**。宁可如实报
`no_observable_change` 让上层决定。

---

## 事件投递的三条路径

| 路径 | API | 进系统事件流 | 移动真实指针 | 后台可用 |
|---|---|---|---|---|
| 全局 HID | `CGEvent.post(tap:)` | ✅ | ✅ | ❌ 需要目标在最上层 |
| 进程定向 | `CGEvent.postToPid(_:)` | ❌ | ❌ | ✅（需窗口上下文） |
| AX 语义 | `AXUIElementPerformAction` | ❌ | ❌ | ✅ |

定向投递的实测结论（目标窗口被完全遮挡，指针距目标 553px）：

| 附加字段 | 结果 |
|---|---|
| 无（裸 postToPid） | 0/3 |
| + 字段 51（窗口号） | 0/3 |
| + 51 + 58 | **3/3** |
| + 51 + `CGEventSetWindowLocation`（局部坐标） | **3/3** |

字段 51/58 未文档化。`CGEventSetWindowLocation` 是导出符号但不在公开头文件。
因此实现里**两条路径同时保留**（58 与 SetWindowLocation 都用），系统升级后若一条失效另一条仍在；
并且每次都靠观察层兜底，不把「返回成功」当结论。

---

## 虚拟光标为什么是独立进程

- 它要持续动画 → 需要 runloop → 不能跟着 CLI 进程生灭。
- 它必须**不接收鼠标事件**（`ignoresMouseEvents = true`）、**不进 Dock**（`.accessory`）、
  **层级 102**（能盖普通窗口和菜单，但不盖系统 HUD / 通知中心）。
- 坐标锚定在 `windowId + 窗口局部坐标` 上，窗口移动时按 100ms 周期重算，
  所以「绑窗口」而不是「绑屏幕」。
- 它从不读写真实指针位置 —— 读一次就变成耦合了。

---

## 主窗口判据（安全相关）

macOS 26 起，窗口级持续捕获会让系统在目标 App 的 AX 窗口列表**第 0 位**插入：

```
AXWindow (subrole=AXDialog, title="Window", ~66×20)
  └─ AXButton (title="WindowSharingSessionButton")
```

如果代码写 `kAXWindows[0]` 当主窗口，后续所有点击都会落在这个胶囊上。
本引擎的判据（`pickMainWindowRecord`，纯函数、有单测）：

```
pid 匹配 && layer==0 && 宽≥120 && 高≥60 && 名称不含 WindowSharingSessionButton
  → 取面积最大
```

三重冗余（尺寸 / layer / 名称），任一失效仍能正确排除。

---

## 错误模型

| 错误码 | 含义 | 调用方应该做什么 |
|---|---|---|
| `permission_denied` | TCC 未授权 | 引导用户开权限，不要重试 |
| `window_not_found` | 应用/窗口不存在 | 启动应用后重建会话 |
| `target_gone` | 目标中途退出 | 重建会话，不复用旧 id |
| `no_pressable_element` | index 过期或文本未匹配 | 重新 inspect |
| `unsupported_background_click` | 该界面不支持后台坐标点击 | 换 AX，或请用户配合 |
| `no_observable_change` | 动作被接受但界面无差异 | 读值确认，不要直接宣称完成 |
| `session_not_found` | 会话 id 无效 | 重新 start |
| `bad_request` | 参数缺失/矛盾 | 修参数 |

「没有可观察变化」和「操作失败」是两件事，代码里严格分开，
避免上层把「没报错」当成「做成了」。
