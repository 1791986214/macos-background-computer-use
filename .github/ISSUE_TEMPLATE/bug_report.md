---
name: Bug 报告
about: 某个操作没生效 / 报错 / 抢了焦点
title: "[bug] "
labels: bug
---

## 环境

- macOS 版本（`sw_vers`）：
- wbcu 版本（`wbcu version`）：
- 目标应用名 + 版本：
- 目标框架（AppKit / SwiftUI / Electron / WKWebView / Catalyst / 不清楚）：

## 复现

```bash
# 完整命令
```

## 现象

- 命令返回：
- **界面实际发生了什么**（这条最关键，没有它无法定位）：
- 真实鼠标是否移动：
- 前台应用是否切换：
- 目标应用是否被激活：

## 诊断输出

```bash
wbcu capabilities --json
wbcu idle --json
wbcu session inspect --id <sid> --max 100 --json
```

## 已尝试

-
