# Windows 安装与验证

## 0. 安装

### 0.0 先看清版本（三个 0.6.x 不是同一个东西）

| 你要的东西 | 版本 | 里面是什么 |
|---|---|---|
| **可下载的预发布包** | `v0.6.2-rc1`（引擎 0.6.2） | 发布页资产，本文件的校验值对应它 |
| **npm 安装包** | `workbuddy-third-hand@0.6.3`（内含引擎 0.6.2） | 0.6.3 只修了下载器（代理/镜像），引擎没变 |
| **源码 / 真机验收版本** | `v0.6.5` | 含 `wbcuf`、帧身份、Worker opt-in；**尚未打包为发布资产** |

`wbcu.exe version` 显示的是**引擎**版本，与 npm 包版本不必然相同。


### 0.1 npm（已装 Node 18+ 时最省事）

```powershell
npm i -g https://github.com/1791986214/macos-background-computer-use/releases/download/v0.6.2-rc1/workbuddy-third-hand-0.6.3.tgz
wbcu doctor
```

npm 包本身只有 7 KB：postinstall 会按当前平台下载对应的原生引擎（Windows 是 `wbcu.exe`），
**校验 sha256 后**才解压，并顺手把 `SKILL.md` 装进 WorkBuddy 技能目录。
失败时不会静默：会打印期望路径、平台与三种处理办法。

离线/内网：

```powershell
$env:WBCU_LOCAL_ZIP = "D:\wbcu-windows-win-x64-0.6.2.zip"
npm i -g https://github.com/1791986214/macos-background-computer-use/releases/download/v0.6.2-rc1/workbuddy-third-hand-0.6.3.tgz
```

> 本包尚未发布到 npm registry（`npm i -g workbuddy-third-hand` 暂时不可用），
> 目前走 GitHub Release 的 tarball URL；registry 发布只需把同一个 tgz 推上去，无需改代码。

### 0.2 PowerShell 引导脚本（没装 Node 时用）

在 Windows 上打开 **PowerShell**（普通用户即可，不需要管理员）：

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://github.com/1791986214/macos-background-computer-use/releases/download/v0.6.2-rc1/install-windows.ps1 | iex"
```

它会依次做：下载发布包 → 校验大小并打印 SHA256 → 解压到 `%TEMP%\wbcu-setup`
→ 调用 `install.ps1`（装引擎 + 装技能 + 冒烟测试）→ 打印下一步命令。

### 0.3 手动安装：下载 → 校验 → 解压 → 安装（顺序不能反）

```powershell
$u      = "https://github.com/1791986214/macos-background-computer-use/releases/download/v0.6.2-rc1/wbcu-windows-win-x64-0.6.2.zip"
$expect = "3ec08e0e5f7f866db873274f421eaa530db2921a0adb07618bb5e1c3aaadffe3"
$zip    = "wbcu.zip"

# 1) 下载
Invoke-WebRequest $u -OutFile $zip -UseBasicParsing

# 2) 校验：不一致就停在这里，绝不继续解压
$actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expect) {
    throw "SHA256 不匹配：期望 $expect，实得 $actual。文件可能不完整或被替换，删掉重下。"
}

# 3) 校验通过后再解压
Expand-Archive $zip -DestinationPath wbcu -Force

# 4) 安装（装引擎 + 装技能 + 冒烟测试）
powershell -ExecutionPolicy Bypass -File wbcu\install.ps1 -Source wbcu
```

`$expect` 必须与 `npm/lib/platform.js` 里登记的 `sha256` 一致。
两者若不一致，以发布页和 `platform.js` 为准，并跑 `./scripts/check-release-hashes.sh` 定位漂移。

> ⚠️ `v0.6.2-rc1` 是**预发布**，已验证与未验证要分清：
>
> - 已验证：编译、单测 65/65、契约一致性；**捕获与遮挡矩阵已在 Windows 10 19045 真机验收**
>   （完全可见 / 部分遮挡 / 四周外扩完全遮挡 / 切前台 / 移动 / 缩放 / 最小化，夹具在 `tests/fixtures/win/`）。
> - 未验证：自带的 `wbcu-guitests.exe` 尚未跑绿，因此 `capabilities` 中相关项仍是 `not_tested`。
>
> 装完先跑第 4 节自检；要宣称「全部能力可用」必须跑第 5 节。

## 1. 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 系统 | Windows 10 22H2 (build 19045+) 或 Windows 11 | 最低 1903（18362）才具备 Windows.Graphics.Capture；低于此只能用 PrintWindow |
| 架构 | x64（`win-x64`），ARM64 目标已配置但未实测 | 不为 Win7/8 做兼容层 |
| 运行时 | .NET 8 Desktop **不需要**；引擎只依赖 .NET 8 基础运行时 | 自带 `--self-contained` 可完全免安装运行时 |
| 权限 | 普通用户（asInvoker） | 不请求管理员；目标以管理员运行时会被 UIPI 挡住，**不绕过** |

## 2. 从源码构建

### 2.1 在 Windows 上

```powershell
git clone <repo>
cd <repo>
powershell -ExecutionPolicy Bypass -File src-windows\build.ps1
```

产物：`dist\win-x64\`（含 `wbcu.exe`、测试应用、`skill\SKILL.md`、安装脚本）。
自包含版本：`build.ps1 -SelfContained`。

### 2.2 在 macOS / Linux 上交叉编译（本仓库的验证方式）

.NET SDK 8+ 支持 `EnableWindowsTargeting=true`，因此**没有 Windows 机器也能产出真实 PE32+ 可执行文件**：

```bash
./scripts/pack-windows.sh win-x64
# → dist/wbcu-windows-win-x64-0.6.2.zip
```

实测（2026-11-16，macOS 26.6 arm64，SDK 8.0.428）：

```
file dist/win-x64/wbcu.exe
# PE32+ executable (console) x86-64, for MS Windows
```

> 交叉编译证明的是**能编译通过**，不是**在 Windows 上能正确运行**。
> 功能可用性必须由真机验证（见第 5 节）。

## 3. 安装

```powershell
powershell -ExecutionPolicy Bypass -File dist\win-x64\install.ps1 -Source dist\win-x64
```

安装脚本做四件事，每件都必须可核查：

1. 复制二进制到 `%LOCALAPPDATA%\Programs\wbcu`；
2. 安装技能文件到探测到的 WorkBuddy 技能目录（**不假设** macOS 的 `~/.workbuddy` 在 Windows 上等价）；
3. 可选把安装目录加进用户 `PATH`（`-AddToPath`）；
4. 跑冒烟测试：`wbcu version` / `selftest --json` / `doctor`。

技能目录探测顺序（找到第一个存在的就用）：

```
%USERPROFILE%\.workbuddy\skills\workbuddy-third-hand
%APPDATA%\workbuddy\skills\workbuddy-third-hand
%LOCALAPPDATA%\workbuddy\skills\workbuddy-third-hand
%USERPROFILE%\Documents\WorkBuddy\skills\workbuddy-third-hand
```

都不存在时：创建第一个并**打印实际路径**；也可用 `-SkillDir <path>` 指定。
`-NoSkill` 只装引擎不装技能（不推荐：没有技能的引擎对 WorkBuddy 不可见）。

## 4. 安装后自检

```powershell
wbcu.exe version            # 应输出 0.6.2（该发布包的程序集版本）
wbcu.exe doctor             # 逐项体检：版本一致性 / 状态目录 / UIA / 捕获 / trace / GUI 验收状态
wbcu.exe selftest --json    # 纯逻辑自检（不需要桌面）
wbcu.exe capabilities --json # 能力矩阵（未实机验证项会显示 not_tested）
wbcu.exe contract --json    # 跨平台契约
```

> 若这里显示 `0.6.0`，说明程序集版本读取失败、落到了兜底值（`Capabilities.Version` 的默认值），
> 不代表这个包真的是 0.6.0 —— 先跑 `wbcu.exe doctor` 看 `engine_version` 与 `engine_path` 是否正常。

`doctor` 里两项值得注意：

- `version_match`：引擎与 `SKILL.md` 的 `version:` 必须一致，不一致说明装了一半；
- `gui_verified`：是否在本机跑过 GUI 测试套件。**没跑过就只能是 not_tested。**

## 5. 真机 GUI 验收（必须做，且不能由 CI 代劳）

```powershell
# 建议先启动引擎的追踪器，好在报告里看到「谁抢了前台」
wbcu.exe trace start

cd dist\win-x64\testapps
.\wbcu-guitests.exe --wbcu ..\wbcu.exe --json gui-report.json
```

套件覆盖：

| 用例 | 断言 |
|---|---|
| `preflight` | 引擎自检通过 |
| `launch_testapp` | 后台启动 + attach 成功 |
| `click_uia` | UIA 语义点击后 **结果文本真的变了** |
| `click_background` | 目标不在前台时点击仍生效；前台不变；引擎自报与实测一致 |
| `click_occluded` | 用真实窗口盖住目标后点击仍生效（语义路径对遮挡免疫） |
| `click_wm_message` | 无 UIA 语义的自绘画布能通过窗口消息点中 |
| `type_background` | 文本写入并被读回验证 |
| `user_concurrency` | 用户持续移动真实鼠标期间，引擎点击仍然成功；无用户输入时鼠标零位移、前台不变 |
| `ghost_cursor` | 覆盖层起、动、点、停；**停止后 status 必须失败**（真的停了才算过） |
| `minimized_capture` | 最小化时如实报 `window_minimized`，不假装截到黑图 |
| `multi_monitor_dpi` | 单屏时 skip 并写明原因；多屏仅记录几何（自动化断言需人工确认落点） |

结论只有三种：`pass` / `fail` / `skip`。**skip 必须带原因**，不许吞掉。
只有全部 `pass` 且零 `skip`，脚本才写入 `%LOCALAPPDATA%\wbcu\gui-verified.json`，
`capabilities` 才会把对应能力从 `not_tested` 升级为 `supported`。

## 6. 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1            # 移除二进制
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveSkill
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeState  # 连经验库一起删
```

`%LOCALAPPDATA%\wbcu`（会话 / 经验 / 性能日志）默认**保留**：它不是缓存，是积累下来的经验。

## 6.5 真机回执（2026-11-17，Windows 10 19045）

第一次真机部署的结论与暴露的问题都在 [`receipt-v0.6.0-windows-real-machine.md`](receipt-v0.6.0-windows-real-machine.md)。
要点：

- 主链路成立：记事本 `inspect` 23 元素、`type` 中英文写入 `success`（`uia_setvalue`，0.95）、
  `capture` 992×624、`frontAppPreserved=true`、`physicalCursorPreserved=true`。
- **0.6.0 有个坑：不带 `--no-ghost` 会挂起**（守护进程继承 stdout）。0.6.1 已修，不再需要该参数。
- **GitHub Release 直连不通时的正确做法**：镜像取包 + `WBCU_LOCAL_ZIP` 注入，sha256 不被跳过。
  ```powershell
  $env:WBCU_LOCAL_ZIP = "D:\wbcu-windows-win-x64-0.6.2.zip"
  npm i -g https://github.com/1791986214/macos-background-computer-use/releases/download/v0.6.2-rc1/workbuddy-third-hand-0.6.3.tgz
  ```
- **运行时依赖分两层**：引擎只要 `Microsoft.NETCore.App` 8；`testapps\`（WPF 靶子 + 验收套件）
  还需要 `Microsoft.WindowsDesktop.App` 8。只想跑引擎可以不装 Desktop。

## 7. 常见问题

| 症状 | 原因 | 处理 |
|---|---|---|
| `uia_unavailable` | COM 初始化失败 / 会话非交互 | 换到交互式桌面；`wbcu.exe doctor` 看详情 |
| `element_not_found` | 选择器不匹配 / 界面还没刷新 | `wbcu.exe inspect --id <sid>` 看真实 automationId |
| `delivered=true` 但 `verified=false` | 目标框架忽略窗口消息 | 换语义选择器；或用 `--state` 给一个可读的状态元素 |
| `window_minimized` | 最小化窗口无合成表面 | 先还原窗口 |
| `permission_denied` | 目标是管理员进程（UIPI） | **不提权**；请用户以同权限运行或改用手动操作 |
| 截图全黑 | DRM 保护内容 | 不支持，如实报 `capture_failed` |
| 安装后技能版本不匹配 | 只装了引擎没装技能 | 重跑 `install.ps1`（默认会装技能） |

## 8. 版本与发布

- 引擎版本：`wbcu.exe version`；技能版本：`SKILL.md` 的 `version:` 字段；两者必须一致。
- v0.6.0 是**跨平台首个开发版本**：macOS 侧保持 v0.5.x 的成熟行为（仅新增 `contract` 命令），
  Windows 侧为新实现。
- 正式 tag 只在本文件第 5 节的真机验收跑通、且报告归档之后才打。
