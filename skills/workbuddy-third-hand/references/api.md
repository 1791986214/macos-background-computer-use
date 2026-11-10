# 引擎接口速查

## 会话（推荐）

```
wbcu session start  --app <bundleId|name|pid> [--window ID] [--no-ghost] [--json]
wbcu session list
wbcu session state  --id SID
wbcu session capture --id SID [--out path] [--max-width N]
wbcu session inspect --id SID [--max N] [--depth N] [--menubar]
wbcu session click  --id SID (--element N | --text T [--exact] | --x X --y Y)
                    [--label 文案] [--no-ghost] [--no-verify] [--force-coords]
wbcu session type   --id SID --text "..." [--element N]
wbcu session key    --id SID --combo "cmd+a"
wbcu session cursor --id SID --x X --y Y [--animate] [--label ...]
wbcu session verify --id SID [--expect "42"]
wbcu session end    --id SID | --all
```

`--x/--y` 是**窗口局部坐标**（左上原点），不是屏幕坐标。

## 一次性命令

```
wbcu apps [--all] [--json]
wbcu windows [--app X|--pid N] [--all] [--json]
wbcu ax-tree [--app X] [--depth 12] [--max 2000] [--json]
wbcu ax-find --text "保存" [--role button] [--exact] [--json]
wbcu ax-act  (--index N | --path 0/1/2 | --window ID) [--action AXPress]
wbcu ax-set  --index N --value "x" [--attr AXValue]
wbcu ax-hit  --x 100 --y 200
wbcu app-state [--app X] [--max-width 1024]      # 截图 + AX 文本
```

## 捕获

```
wbcu shot --app X --out f.png [--analyze]
wbcu stream --app X [--seconds 6] [--dir frames/]
wbcu analyze f.png                 # 紫色共享指示器像素分析
```

## 输入

```
wbcu click --app X (--x --y | --window ID) [--mode auto|ax|targeted|global]
           [--verify] [--ghost] [--allow-global]
wbcu drag  --window ID --x1 --y1 --x2 --y2
wbcu scroll [--dx 0 --dy -5] [--x X --y Y] [--app X]
wbcu key   "cmd+shift+g" [--app X] [--repeat N]
wbcu type  --text "你好" [--app X]
wbcu act   --app X --x X --y Y [--label ...] [--no-ghost] [--no-verify]
```

## 光标

```
wbcu ghost start|status|hide|stop|daemon
wbcu ghost move --x X --y Y [--animate] [--label ...]
```

## 诊断

```
wbcu perm [--prompt]
wbcu capabilities [--json]
wbcu selftest [--json]
wbcu idle [--json]          # 距上次真实用户输入的时间
wbcu guard --list | --app X --allow | --app X --revoke
```

## 环境变量

| 变量 | 作用 |
|---|---|
| `WBCU_NO_HID_MOUSE=1` | 结构性禁用一切真实鼠标注入（碰到即 exit 4） |
| `WBCU_GHOST=1` | 默认开启虚拟光标 |
| `WBCU_BIN` | MCP 启动器用，指向 wbcu 可执行文件 |

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 一般错误（目标不存在、元素找不到等） |
| 2 | 参数错误 |
| 3 | 应用未授权（permission_denied） |
| 4 | 被 `WBCU_NO_HID_MOUSE` 拦下 |
| 5 | 找不到目标窗口 |
| 6 | 需要 `--allow-global` 但没给 |
