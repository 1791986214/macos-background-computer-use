# 变更记录

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循语义化版本。

## [Unreleased]

### 文档
- README 重写：补齐真实克隆地址、可执行的安装/首次验证命令、实测兼容性表格与分层测试说明；
  修正「许可证待定」为 MIT、修正光标实现描述（NSView + Timer，非 Core Animation）；
  Roadmap 按实际完成情况勾选，架构图改为反映「捕获不喂输入、光标独立进程、验证独立成环」的真实分层
- 技能补齐 `examples/quickstart.md`（六步最小流程 + 错误码对照 + idle 判据），
  修复安装后 `examples/` 为空目录的问题（git 不跟踪空目录）

## [0.2.0] — 2026-11-10

首个可复用版本。把此前分散的验证脚本收敛成引擎 + 会话层 + 技能。

### 新增
- `session` 会话层：`start / list / state / capture / inspect / click / type / key / cursor / verify / end`
  - 会话状态落盘 `~/.wbcu/sessions/<id>.json`，命令间复用，不常驻 daemon
  - 窗口 frame 每次操作前刷新，窗口被移动后仍然点得准
- `capabilities` 能力探测：一次性返回权限、可用能力、默认策略、错误码表
- `selftest` 纯逻辑自检：27 项断言，无 GUI / 无 TCC 依赖，可直接在 CI 跑
- `idle` 探针：距上次真实用户输入的时间，用于区分「引擎抢焦点」与「用户自己在动」
- 结构化错误码：`permission_denied` / `window_not_found` / `target_gone` /
  `no_pressable_element` / `no_observable_change` / `session_not_found` / `bad_request`
- MCP `cu_session` 工具（16 个工具总计）
- 三层测试：`tests/unit`（CI）、`tests/integration`（需授权）、`tests/regression`（历史矩阵）

### 变更
- 自动升级策略收紧：**只在 AX 失败时**降级到定向投递，不再在「AX 成功但界面没变化」时补一次坐标点击
  - 原因：`AXPress` 成功意味着应用已接受动作；再补一次会让非幂等按钮（复制、发送、+）重复执行。
    检测不到变化改为如实报告 `no_observable_change`
- 主窗口判据抽成纯函数 `pickMainWindowRecord`，成为可单测的安全规则
- 坐标换算统一为 `windowLocal / windowGlobal` 两个函数，投递/光标/截图共用一份实现
- 修复 `processName` 解析 `KERN_PROCARGS2` 时把 argc 二进制当字符串读，导致 `responsibleName` 出现控制字符
- 源码按职责分目录：`WindowCapture / Accessibility / InputDispatcher / GhostCursor / SessionManager`

### 保留（此前已验证，未改动行为）
- 窗口级 `SCStream` 持续捕获与紫色共享指示器生命周期观测
- `postToPid` + 字段 51/58 + `CGEventSetWindowLocation` 的定向投递
- Ghost Cursor 独立 daemon（层级 102、事件穿透、坐标锚定窗口）
- per-app 授权白名单
- `WBCU_NO_HID_MOUSE=1` 结构性禁用鼠标注入

## [0.1.0] — 2026-11-10

内部实验版本，未公开发布。包含紫胶囊机制验证、AX 树读取、
后台定向点击实验、虚拟光标原型。
