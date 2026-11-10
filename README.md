# macOS Background Computer Use

让 AI Agent 在**不抢用户鼠标和键盘**的前提下，操作 macOS 上的其他应用：
窗口级捕获 → Accessibility 语义识别 → 进程级定向投递 → 独立虚拟光标 → 读值验证。

这套能力由 WorkBuddy 的 Agent 驱动，同时也是一个独立的命令行工具（`wbcu`），
可以脱离任何 Agent 单独使用。

```
用户正在某个应用里干活
        │
        ├── Agent 光标（紫箭头，独立坐标）      ← 只负责「让人看见在点哪」
        ├── 后台输入引擎（postToPid + 窗口上下文）← 只负责「让目标真的响应」
        └── 观察层（AX 树 / ScreenCaptureKit）   ← 只负责「确认到底变没变」
```

三者互相独立：关掉光标不影响操作，观察层失败不影响投递，投递失败要如实报错。

---

## 它解决什么问题

传统 GUI 自动化（cliclick、pyautogui、AppleScript 的 `click at`）靠移动真实指针 + 全局事件，
所以：用户鼠标被抢、窗口必须置顶、被遮挡就点不到。

这里换一条路：

| 传统做法 | 本引擎 |
|---|---|
| 移动真实鼠标到 (x,y) 再点击 | 把事件**直接塞进目标进程队列**，带窗口号与窗口局部坐标 |
| 必须把目标窗口置顶 | 目标被完全遮挡也能点（实测指针距目标 553px 仍然成功） |
| 全局键盘事件 | `postToPid` 定向投递，不进系统事件流 |
| 「命令返回 0 就算成功」 | 操作前后对比 AX 树指纹，必须看到实际变化 |

---

## 快速开始

```bash
# 1. 构建（需要 Xcode Command Line Tools）
./scripts/build.sh

# 2. 装到 PATH
./scripts/install.sh

# 3. 授权检查（会告诉你缺哪一项）
wbcu perm --prompt

# 4. 授权一个应用
wbcu guard --app com.apple.calculator --allow

# 5. 建会话 → 看界面 → 点 → 验证 → 收尾
SID=$(wbcu session start --app com.apple.calculator --json | python3 -c "import sys,json;print(json.load(sys.stdin)['session']['id'])")
wbcu session inspect --id "$SID" --max 40
wbcu session click --id "$SID" --text "全部清除" --exact
wbcu session click --id "$SID" --text "7" --exact
wbcu session click --id "$SID" --text "加" --exact
wbcu session click --id "$SID" --text "8" --exact
wbcu session click --id "$SID" --text "等于" --exact
wbcu session verify --id "$SID" --expect "15"
wbcu session end --id "$SID"
```

全程鼠标不动、前台不切、目标应用不激活。

---

## 会话 API

`wbcu session` 是推荐入口：一次解析目标应用/窗口，后续动作复用。

| 命令 | 作用 | 关键参数 |
|---|---|---|
| `session start` | 建立会话，解析主窗口，检查授权 | `--app` `--window` `--no-ghost` |
| `session list` / `state` | 查看会话与目标存活状态 | `--id` |
| `session capture` | 捕获目标窗口画面 | `--out` `--max-width` |
| `session inspect` | 读 AX 树（返回带 index 的扁平表） | `--max` `--depth` |
| `session click` | 点击：语义 / 文本 / 坐标 | `--element` `--text` `--x/--y` `--exact` `--no-verify` |
| `session type` | 写文本（AXValue 优先） | `--text` `--element` |
| `session key` | 定向按键 | `--combo "cmd+a"` |
| `session cursor` | 移动虚拟光标 | `--x --y`（窗口局部）`--label` |
| `session verify` | 断言界面文本 | `--expect "42"` |
| `session end` | 释放会话（最后一个会隐藏光标） | `--id` / `--all` |

底层单次命令（`apps` `windows` `ax-tree` `ax-find` `ax-act` `click` `key` `type` `shot` `stream` `ghost` `act`）
仍然可用，适合调试与一次性操作。完整列表见 `wbcu --help`。

---

## 能力与限制

**能做的**

- 标准 AppKit 控件：AX 语义点击、读值、写值，后台完成
- 被其他窗口完全遮挡的窗口：定向投递仍然可点
- WKWebView 内的按钮：走 AX（`AXWebArea → AXButton`）
- 窗口级持续捕获（SCStream），会触发系统的紫色共享指示器（这是系统行为，不是我们画的）
- 独立虚拟光标：可显示、可隐藏、可跨窗口跟随，与真实鼠标完全解耦

**做不到的（实测结论，不是猜测）**

| 项 | 原因 |
|---|---|
| 非激活窗口里用按键打字 | 没有 field editor，按键事件无处落地。改用 `session type` 写 AXValue |
| 依赖 key window 的快捷键（Cmd+W） | `performClose:` 需要 key window。改用 AX 点关闭按钮 |
| 拖拽排序 | `mouseDown` 能送达，但 AppKit 不建立 `NSDraggingSession`，需要真实鼠标跟踪状态 |
| 自绘 Canvas 的首次点击 | 取决于目标视图 `acceptsFirstMouse`，第三方 App 改不了 |

细节与逐项实测数据见 [`docs/capability-matrix.md`](docs/capability-matrix.md)。

---

## 关键机制备忘

1. **紫胶囊不是 UI**：窗口级 `SCStream` 持续捕获时，系统会在目标 App 的 AX 窗口列表**第 0 位**
   插入一个 `AXDialog`（约 66×20）+ `AXButton("WindowSharingSessionButton")`。
   拿 `kAXWindows[0]` 当主窗口会点到一个胶囊上。本引擎的主窗口判据是
   `layer==0 && 宽≥120 && 高≥60 && 面积最大`，并且这条规则是可单测的纯函数。
2. **单帧截图不触发指示器**，只有持续捕获触发。
3. **裸 `postToPid` 无效**，必须带窗口号（事件字段 51）；再加字段 58 或
   `CGEventSetWindowLocation`（窗口局部坐标）才生效。
4. **`_AXUIElementGetWindow` 是唯一使用的未文档化符号**，经 `dlsym` 解析且带 nil 兜底
   （拿不到时回落到 CGWindowList 判据）。除此之外不依赖任何私有 API，SkyLight 完全没用。

---

## 开发

```bash
./scripts/build.sh                 # 编译
./tests/run-all.sh unit            # 单元测试（无 GUI / 无授权，CI 用）
./tests/run-all.sh                 # 单元 + 集成（需要真实桌面与授权）
./tests/run-all.sh all             # 再加回归矩阵与 fixture 对照
```

单元测试覆盖：参数解析、按键映射、坐标换算（含副屏负坐标）、主窗口判据（含共享指示器陷阱）、
会话序列化、错误码表，以及源码卫生（个人路径 / 明文密钥 / 私有 API / 假装成功的兜底）。

CI（`.github/workflows/ci.yml`）在 macOS runner 上只跑单元测试 —— 没有 GUI 会话和 TCC 授权的
机器上跑不了真实交互，**CI 绿不等于功能可用**，这一点在 CI 文件里也写明了。

---

## 文档

| 文件 | 内容 |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | 分层架构、事件投递路径、为什么这样设计 |
| [`docs/installation.md`](docs/installation.md) | 构建、安装、升级、卸载、恢复 |
| [`docs/permissions.md`](docs/permissions.md) | TCC 三态权限、归因规则、撤销方法 |
| [`docs/capability-matrix.md`](docs/capability-matrix.md) | 逐应用 / 逐框架实测矩阵 |
| [`docs/compatibility.md`](docs/compatibility.md) | macOS 版本差异与已知回归 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 症状 → 原因 → 处理 |

---

## 许可证

内部项目，**未附加开源许可证**。在获得明确授权并完成第三方代码/许可证审查之前，
不要将本仓库改为 Public，也不要复制到其他项目。
