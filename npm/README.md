# workbuddy-third-hand (npm 包)

WorkBuddy Third Hand 的 npm 分发通道。装上之后你得到的是 `wbcu` 命令
（Windows 上是 `wbcu.exe` 原生引擎），以及一份装到 WorkBuddy 技能目录里的 `SKILL.md`。

```bash
npm i -g workbuddy-third-hand          # 如果已发布到 npm registry
npm i -g <tarball-url>                 # 或直接从 GitHub Release 装（当前可用）
wbcu doctor
```

## 它到底装了什么

```
<包目录>/
├── bin/wbcu.js          命令入口：找二进制 → 透传参数 → 透传退出码
├── lib/platform.js      平台 → 发布资产映射（含 sha256）
├── lib/download.js      HTTPS 下载 + 重定向跟随 + sha256 校验
├── lib/unzip.js         零依赖 ZIP 解压（store/deflate + zip-slip 防护）
├── scripts/install.js   postinstall：下载 → 校验 → 解压 → 装技能/覆盖层
└── vendor/<platform>/   解压出来的原生引擎（npm 包本身只有 7 KB）
```

## 为什么是「壳 + 下载」而不是把二进制打进包里

| 方案 | 问题 |
|---|---|
| 把各平台二进制都打进 npm 包 | 每个平台几十 MB，装一次拖全部；npm 也不适合分发大二进制 |
| 每个平台一个包（`@wbcu/win-x64` …） | 用户要装对的那个，装错了报错难懂；依赖解析还会引入 optionalDependencies 的坑 |
| **壳 + postinstall 按平台下载** | 包体 7 KB，校验 sha256，失败信息明确；代价是需要网络（可用 `WBCU_LOCAL_ZIP` 离线） |

## 环境变量

| 变量 | 作用 |
|---|---|
| `WBCU_PLATFORM=win32-x64` | 覆盖平台判定（仅用于调试/交叉验证） |
| `WBCU_LOCAL_ZIP=<path>` | 用本地 zip 代替下载（内网/代理环境） |
| `WBCU_SKIP_DOWNLOAD=1` | 只装壳，二进制自己放 |
| `WBCU_SKIP_SKILL=1` | 不往 WorkBuddy 技能目录写 `SKILL.md` |

## 支持的平台

| 平台 | 资产 | 状态 |
|---|---|---|
| `win32-x64` | `wbcu-windows-win-x64-0.6.1.zip` | 可装；**真机 GUI 验收未做** |
| `darwin-arm64` | `wbcu-macos-arm64-0.6.1.zip` | 可装；本机 `selftest 53/53` 已验证 |
| `win32-arm64` / `darwin-x64` | — | 未发布，装的时候会明确报不支持 |

## 边界（不要当成已支持）

- Windows 侧：`wbcu capabilities --json` 里 `not_tested` 的项就是没在真机验证过的项。
- 目标以管理员身份运行（UIPI）会被挡住，本工具不提权。
- 最小化窗口无法截图，如实报 `window_minimized`。
