# 排错

## 先跑这三条

```bash
wbcu perm --json          # 权限到底有没有
wbcu capabilities --json  # 哪项能力可用
wbcu session list         # 有没有残留会话
```

---

## 症状表

### 权限类

| 症状 | 原因 | 处理 |
|---|---|---|
| `permission_denied` | TCC 未授权 | 看 `perm` 输出，去系统设置开对应项；`--prompt` 只在首次有效 |
| 权限显示已开但仍失败 | 授权开给了错误对象（TCC 归因到责任进程） | 看 `responsibleName`，给**那个 App** 开权限，见 `permissions.md` |
| 修改权限后仍不生效 | 进程缓存了旧的 TCC 状态 | 重启终端 / 重启宿主 App |
| 屏幕能截但 AX 读不到 | 只授了屏幕录制 | 再授辅助功能 |

### 会话类

| 症状 | 原因 | 处理 |
|---|---|---|
| `session_not_found` | id 打错，或会话已 end | `wbcu session list` 看现存会话 |
| `window_not_found` | 应用没运行 / 只有 AXDialog 附属窗 | `wbcu apps` 确认在运行；`open -g -a <app>` 后台启动 |
| `target_gone` | 目标中途退出或窗口关闭 | 重新 `session start`，不要复用旧 id |
| 会话一堆残留 | 上次没 `end` | `wbcu session end --all` |
| 状态里的 frame 是旧的 | 窗口被移动过 | `session state` 会刷新；操作命令本身也会刷新 |

### 操作类

| 症状 | 原因 | 处理 |
|---|---|---|
| `no_pressable_element` | index 过期（只对最近一次快照有效） | 重新 `session inspect` |
| 文本匹配到错误的元素 | 模糊匹配撞车（"9" 撞 "99"） | 加 `--exact` |
| 点击返回 ok 但界面没动 | ① 首击被吞（用于激活）② 该控件不响应 AX ③ 投递到了错误窗口 | 依次试：再点一次 → 改 `--element` → 确认 `windowId` |
| `no_observable_change` | 动作被接受但界面无差异（如本来就是清零状态） | 读值确认，别直接宣称完成 |
| 坐标点击落在别的应用 | 没带 `--app` / `--window`，引擎不知道目标是谁 | 显式指定窗口 id |
| 非激活窗口打字无效 | 没有 field editor | 用 `session type`（写 AXValue），不要用按键 |
| `cmd+w` 类快捷键无效 | `performClose:` 需要 key window | 改用 AX 点关闭按钮 |
| WKWebView 里点不动 | 坐标事件对 WebContents 无效 | 走 AX：`AXWebArea → AXButton` |
| 自绘 Canvas 点不动 | 目标视图 `acceptsFirstMouse=false` | 无法从外部改；请用户把窗口露出来，或用 AX |

### 捕获类

| 症状 | 原因 | 处理 |
|---|---|---|
| 截图为空 / 全黑 | 屏幕录制未授权，或窗口已关闭 | `wbcu perm`；确认窗口还在 |
| 截图里尺寸是 2 倍 | Retina，正常 | 像素尺寸 = 逻辑尺寸 × scale |
| 截图左上角有紫胶囊 | 有窗口级持续捕获在进行 | 正常；停掉 `stream` 后消失 |
| 捕获返回 `capture_failed` | 窗口 id 失效 | 重新解析窗口 |

### 虚拟光标类

| 症状 | 原因 | 处理 |
|---|---|---|
| 看不到光标 | ghost daemon 没起 | `wbcu ghost start` |
| 光标位置偏了 | 用错坐标系（传了屏幕坐标给 `--x/--y`） | `session cursor` 的 x/y 是**窗口局部坐标** |
| 光标不跟着窗口移动 | daemon 挂了或窗口 id 变了 | 重启 `ghost start` |
| 残留多个光标 | 之前异常退出 | `wbcu ghost stop`，然后 `ghost start` |
| 关掉光标后操作失败 | 不应该发生 —— 两层是解耦的 | 若真发生，说明是巧合（把操作问题误认为光标问题），单独查操作链路 |

### 零干扰相关

| 症状 | 原因 | 处理 |
|---|---|---|
| 用户说鼠标被抢了 | 某处用了 `--allow-global` | `grep allow-global` 检查调用方；默认路径不该有 |
| 前台被切换 | 调了 `activate`，或目标 App 自己抢焦点 | 去掉 activate；某些 App 在 AXPress 后自激活，属目标行为 |
| 测试断言「前台被切换」但引擎无辜 | 测试期间用户自己在操作 | 用 `wbcu idle` 判断：若 `idle < 测试耗时`，说明有用户输入，结论不可靠 |

---

## 调试手段

```bash
# 看事件是否真的到达目标（fixture 自带事件日志）
tail -f /tmp/wbcu-lab/events.jsonl

# 看 AX 指纹变没变
wbcu session inspect --id s1 --max 400 --json | python3 -m json.tool | head -40

# 确认投递用了哪个模式
wbcu session click --id s1 --x 100 --y 100 --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['mode'], d['verification'], d.get('axError'))"

# 结构性禁用鼠标注入，验证「没碰真实鼠标」
WBCU_NO_HID_MOUSE=1 wbcu session click --id s1 --x 100 --y 100   # 应直接报错退出
```

## 收集问题报告

遇到新问题，请记录：

1. `wbcu capabilities --json` 输出
2. `wbcu --version` 与 `sw_vers`
3. 目标应用名 + 版本 + 框架（AppKit / Electron / Catalyst）
4. 完整命令与完整输出（含 `--json`）
5. 现象：命令返回什么 vs 界面实际发生了什么
6. `wbcu idle --json`（判断当时有没有人在操作）

有这六项基本能定位。缺「界面实际发生了什么」，问题就变成猜。
