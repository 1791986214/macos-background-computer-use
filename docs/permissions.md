# 权限（TCC）

macOS 的隐私授权（TCC）是不可绕过的。本引擎**只使用系统允许的方式**请求与检查权限，
不写 TCC 数据库、不伪造签名、不借助任何提权技巧。

## 需要的三项

| 权限 | 用途 | 缺失后果 |
|---|---|---|
| 辅助功能 Accessibility | 读 AX 树、执行 AX 动作、写 AXValue | 无法做任何 UI 操作，只剩截图 |
| 屏幕录制 Screen Recording | ScreenCaptureKit 窗口捕获 | 无法 `capture` / `stream`，AX 操作照常可用 |
| 输入监控 / 输入注入 PostEvent | 全局 HID 事件（仅在 `--allow-global` 时用） | 全局点击不可用，定向投递不受影响 |

检查：

```bash
wbcu perm
```

```
accessibility : ✅ 已授权
screenRecord  : ✅ 已授权
postEvent     : ✅ 已授权
listenEvent   : ✅ 已授权
授权归属 App   : WorkBuddy (pid 1234)
```

## TCC 归因：授权给的是「App」，不是「二进制」

这是最容易踩的坑。TCC 记录的是**责任进程（responsible process）**的身份：

```
终端里跑 wbcu
   └── 责任进程 = 终端或 WorkBuddy → 授权归到它们名下
        → 看起来「wbcu 有权限了」，其实是宿主 App 有权限

以独立 App Bundle 经 LaunchServices 启动（open -a）
   └── 责任进程 = 它自己 → 需要它自己的 TCC 记录
        → 全新 bundle 三项权限默认全 false，要单独授权
```

所以：

- **命令行方式**：只要宿主（WorkBuddy / 终端）已授权，`wbcu` 自动继承，无需单独授权。
- **独立 bundle 方式**（`scripts/bundle.sh` 产出的 `.app`）：需要在系统设置里为它单独开权限。

`wbcu perm --json` 里的 `responsibleName` / `responsiblePid` 就是用来确认这件事的。
如果 `responsibleName` 显示的是你的终端，而你在系统设置里给 `wbcu` 开了权限 —— 那是开错了对象。

## 按应用授权（第二道闸门）

TCC 是系统级授权，粒度是「这个 App 能不能控制别的 App」。
本引擎在此之上加了**应用级白名单**，副作用操作必须先授权目标应用：

```bash
wbcu guard --list                    # 看当前白名单
wbcu guard --app com.apple.finder --allow
wbcu guard --app com.apple.finder --revoke
```

- 未授权的应用：`ax-act` / `ax-set` / `click` / `key` / `type` / `stream` / `session` 全部**直接拒绝**（exit 3）。
- 只读操作（`apps` / `windows` / `ax-tree` / `ax-find` / `shot`）不受限制。
- 白名单在 `~/.wbcu/allowlist.json`，纯文本，可审计、可手工删。

设计意图：TCC 只能表达「允许它控制所有 App」，而实际任务往往只需要一两个 App。
白名单把「能控制一切」收窄成「能控制这两个」，就算 Agent 判断失误，损失也有边界。

## 授权弹窗只弹一次

`wbcu perm --prompt` 触发系统弹窗。用户点了「不允许」之后，系统**不会再弹**，
必须手动去「系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制」勾选。
此时再调 `--prompt` 也只会静默返回 false。

所以当权限缺失时，正确做法是**明确告诉用户去哪个面板开哪一项**，而不是反复重试。

## 撤销

```bash
# 撤销 TCC（把 bundle id 换成实际宿主）
tccutil reset Accessibility com.tencent.workbuddy.mac
tccutil reset ScreenCapture com.tencent.workbuddy.mac
tccutil reset PostEvent   com.tencent.workbuddy.mac

# 撤销应用级白名单
wbcu guard --app com.apple.calculator --revoke
# 或整个删掉
rm ~/.wbcu/allowlist.json
```

`tccutil reset` 会立即生效，正在进行的捕获会中断。**这是不可逆操作**（需要重新授权），
不要在不告知用户的情况下执行。

## 最小权限建议

| 场景 | 需要开 |
|---|---|
| 只读界面信息 | 辅助功能 |
| 后台点击 / 填表 | 辅助功能 |
| 需要看画面（视觉定位） | 辅助功能 + 屏幕录制 |
| 必须动真实鼠标（最后手段） | 再加 PostEvent |

**默认不要开 PostEvent。** 定向投递与 AX 覆盖了绝大多数场景，
全局 HID 只在目标既无 AX 又需要对真实指针位置敏感时才用得上。
