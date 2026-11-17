# 真机回执：Windows 10 19045 部署与能力验证（v0.6.0）

> 本文件记录**第三方真机回执**与随后的处置结论。回执原文由部署方提供（企业微信文件），
> 这里保留其结论与证据，并逐条对应到修复提交。**这是他人实测，不是本仓库自测**。

- 回执时间：2026-11-17 09:47–10:18
- 环境：Windows 10 19045 / x64 / Node 22.22.2 / npm 10.9.7
- 被测版本：`workbuddy-third-hand@0.6.0`（npm 全局） + `vendor/win32-x64/wbcu.exe`
- 回执结论：**可用** —— 真实 GUI 后台操控验证通过，读值验证 `success`，未抢前台、未移动真实鼠标

## 一、回执里成立的能力（我方未改动）

| 能力 | 结果 | 证据 |
|---|---|---|
| `inspect` | 通过 | 记事本读到 23 个 UIA 元素，`Document` aid=15，patterns: value/scroll/text |
| `type` 写入（英文） | `success` | method=`uia_setvalue`，confidence 0.95，读回一致 |
| `type` 写入（中文） | `success` | 写入并读回「小乐后台操控验证成功 2026-11-17」 |
| `capture` | 通过 | 992×624，PrintWindow 兜底，21.5ms |
| 不抢前台 | 通过 | `frontAppPreserved=true` |
| 不动鼠标 | 通过 | `physicalCursorPreserved=true` |
| 会话清理 | 通过 | `session end --all`，无 wbcu/notepad 残留 |
| 视觉复核 | 通过 | `cap.png` 正文与标题栏内容一致 —— 写入真实生效，非「命令返回成功」判定 |

这一条最值钱：**它证明了「UIA 语义写值 + 读值验证 + 零干扰」这条主链路在真机上成立**，
而不仅仅是「能编译」。

## 二、回执暴露的缺陷与处置（0.6.1 全部修复）

| # | 现象 | 根因 | 修复位置 |
|---|---|---|---|
| 1 | 不带 `--no-ghost` 就永久挂起（PowerShell 管道、GUI 套件都中招） | ghost 守护进程继承调用方 stdout 句柄，调用方等不到 EOF | `Win32/DetachedProcess.cs`（三重定向 + 后台读空 + 关 stdin），`GhostClient.Start` / `TraceCmd` 改用它 |
| 2 | `launch --app <绝对路径>` 异常退出（exit -1） | 启动异常未捕获，被 .NET 转成 `-1` | `Launch/Launcher.cs`：全路径 try/catch，异常转结构化 `LaunchResult` |
| 3 | `--app notepad` 被解析到 Git 的 `usr/bin/notepad`（Win32 193） | 候选顺序 PATH 早于 App Paths，且不校验 PE | 顺序改为 用户路径 → System32/SysWOW64 → App Paths → PATH，每候选过 `MZ` 校验 |
| 4 | 输出是 GBK，解析 JSON 报 `UnicodeDecodeError` | 控制台代码页 936 + JSON 保留原始中文 | `Program.Main` 固定 UTF-8（无 BOM）；`Json.Options` 改 `JavaScriptEncoder.Default`，JSON 纯 ASCII |
| 5 | `wbcu-guitests.exe` 空转 335s CPU 零产出 | #1 的挂起 + 同步读管道（先 stdout 后 stderr）的死锁点 | `Wbcu.GuiTests`：异步读双流 + 单命令 90s / 单用例 300s 看门狗 + 超时杀进程树 + 每例耗时 |
| 6 | `testapps/wbcu-testapp-win32.exe` 启动即崩 | `GetStockObject` 声明在 `user32.dll`，实际在 `gdi32.dll` | `Wbcu.TestApp.Win32/Program.cs` |

> 说明：第 5、6 条直接影响「能不能自证」。测试靶子自己起不来、套件自己卡死，
> 就等于没有验收工具 —— 所以这两条按 P0 处理，而不是「环境问题」。

## 三、回执里提到的环境问题（不是 bug，但要写进文档）

1. **GitHub Release 直连不通**（`20.6.7.17:443` 超时）→ 回执改用镜像取包 + `WBCU_LOCAL_ZIP` 注入，
   sha256 校验未被跳过。这是正确的处理方式，0.6.1 文档已把它写成标准离线路径。
2. **.NET 运行时**：安装方补装了 8.0.34 Core + WindowsDesktop 到用户级 `C:\Users\pc\.dotnet`。
   实测引擎本身只依赖 `Microsoft.NETCore.App`（发布出的 `wbcu.runtimeconfig.json` 里没有 WindowsDesktop），
   Desktop 是 `testapps`（WPF 靶子）需要的。0.6.1 文档已分开写清。

## 四、下一步（解锁 `gui_verified` 的唯一路径）

回执里 `gui_verified=warn` 是**正确状态**：套件没跑完就不该解锁。修复后的重跑顺序：

```powershell
wbcu session end --all                      # 清掉 0.6.0 残留会话与覆盖层
npm i -g https://github.com/1791986214/macos-background-computer-use/releases/download/v0.6.1-rc1/workbuddy-third-hand-0.6.1.tgz
wbcu version                                # 期望 0.6.1

# 1) 先确认不带 --no-ghost 也不挂起（本次修的核心）
wbcu attach --app calc --json
wbcu click --id <sid> --name 7 --json

# 2) 再跑验收套件（现在有看门狗，卡住会报 TIMEOUT 而不是空转）
cd testapps
.\wbcu-guitests.exe --wbcu (split-path (Get-Command wbcu).Source) --verbose --json gui-report.json
```

只有 `fail=0 且 skip=0` 时，套件才会写 `%LOCALAPPDATA%\wbcu\gui-verified.json`，
`wbcu capabilities --json` 才会把对应能力从 `not_tested` 升级为 `supported`。
在此之前，对外只能说「主链路已真机验证（记事本写入/截图/零干扰）」，不能说「全部能力已验证」。
