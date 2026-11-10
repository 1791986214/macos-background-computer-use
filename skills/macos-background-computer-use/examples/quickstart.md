# 快速上手（给 Agent 看的版本）

复制这段就能跑通一次完整的后台操作。假设 `wbcu` 在 PATH 里、目标应用已授权。

## 1. 确认能力

```bash
wbcu capabilities --json     # 看 accessibility / screenRecording 是否 true
wbcu guard --list            # 看目标应用是否在白名单
```

`accessibility: false` → 停下来告诉用户去系统设置开「辅助功能」，不要继续试。

## 2. 建立会话

```bash
SID=$(wbcu session start --app com.apple.calculator --json \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['session']['id'])")
```

`session start` 会解析主窗口并做授权检查。**一个任务只建一个会话**，后续命令都带 `--id $SID`。

## 3. 看界面（先便宜的后贵的）

```bash
wbcu session inspect --id "$SID" --max 60      # AX 树：精确、便宜、首选
wbcu session capture --id "$SID" --out /tmp/c.png   # 只在需要视觉定位时截图
```

`inspect` 返回的 `index` **只对本次快照有效**。元素变了就重新 inspect，不要复用。

## 4. 操作（语义优先）

```bash
wbcu session click --id "$SID" --text "7"     --exact
wbcu session click --id "$SID" --text "加"    --exact
wbcu session click --id "$SID" --text "8"     --exact
wbcu session click --id "$SID" --text "等于"  --exact
```

- `--element N` / `--text T` → 走 AX 语义，不激活、不需坐标、对遮挡免疫
- `--x --y` → 走进程级定向投递（窗口局部坐标），遮挡下也能点
- `--allow-global` → **动真实鼠标，必须先得到用户同意**

## 5. 读值验证（不要读 ok）

```bash
wbcu session verify --id "$SID" --expect "15"
```

返回 `matched: true` 才算完成。`no_observable_change` 表示动作被接受但界面没差异——
**不等于失败，也不等于完成**，要如实告诉用户。

## 6. 收尾

```bash
wbcu session end --id "$SID"
```

最后一个会话结束时虚拟光标自动隐藏。忘记 end 会留下状态文件（`wbcu session list` 能看到）。

## 出错时查什么

| 错误码 | 处理 |
|---|---|
| `permission_denied` | 告诉用户开哪个权限，别重试 |
| `window_not_found` | `wbcu apps` 确认应用在运行 |
| `target_gone` | 目标退出了，重新 `session start` |
| `no_pressable_element` | index 过期，重新 `inspect` |
| `no_observable_change` | 读值确认，别宣称完成 |

## 想证明没打扰用户

```bash
wbcu idle --json     # 距上次真实用户输入的时间
```

`idle < 测试耗时` 说明期间有人动过键鼠 → 鼠标/前台的变化归属不明，结论只能标「不确定」。
