# 安装、升级与恢复

## 前置条件

- macOS 14 或更高（实测在 26.6 上）
- Xcode Command Line Tools：`xcode-select --install`
- 无需 Homebrew，无第三方依赖（MCP 服务器也是零依赖的纯 Node 脚本）

## 从源码构建

```bash
git clone <repo> macos-background-computer-use
cd macos-background-computer-use
./scripts/build.sh
./bin/wbcu version      # 应输出版本号
```

构建脚本会优先使用 `MacOSX26.5.sdk`。原因：本机 macOS 27.0 SDK 与
CommandLineTools 的 Swift 6.3.3 版本不匹配，用默认 SDK 会编译失败。
如果你的机器上不存在该 SDK，脚本会自动回落到 `xcrun --show-sdk-path`。

## 安装到 PATH

```bash
./scripts/install.sh
```

装完之后：

| 路径 | 内容 |
|---|---|
| `~/.local/bin/wbcu` | 原生引擎 |
| `~/.local/bin/wbcu-mcp` | MCP 启动器（动态解析 node，不硬编码版本号） |
| `~/.local/share/wbcu/wbcu-mcp.mjs` | MCP 服务器脚本 |
| `~/.wbcu/` | 运行时状态：授权白名单、会话、快照 |

确认 `~/.local/bin` 在 `PATH` 里（且**在 `/usr/bin` 之前**）。

## 接入 WorkBuddy（MCP）

`~/.workbuddy/mcp.json` 增加：

```json
{
  "mcpServers": {
    "wbcu": {
      "command": "<HOME>/.local/bin/wbcu-mcp",
      "args": [],
      "env": { "WBCU_BIN": "<HOME>/.local/bin/wbcu" }
    }
  }
}
```

MCP **不会自动生效**：需要在 WorkBuddy 连接器管理页右上角「自定义连接器」里点「信任」。

不用 MCP 也可以，直接命令行 `wbcu session ...` 一样能干活。

## 接入 WorkBuddy（技能）

```bash
mkdir -p ~/.workbuddy/skills
cp -R skills/macos-background-computer-use ~/.workbuddy/skills/
```

技能放在用户级目录（`~/.workbuddy/skills/`）才对**所有项目**可见；
放到项目的 `.workbuddy/skills/` 只对该项目生效。

## 首次授权

```bash
wbcu perm --prompt     # 触发系统授权弹窗
wbcu perm              # 复查
wbcu guard --app com.apple.calculator --allow   # 按应用授权
```

详见 [`permissions.md`](permissions.md)。

## 升级

```bash
git pull
./scripts/build.sh && ./scripts/install.sh
./tests/run-all.sh unit        # 先确认没编译坏
```

**升级不会影响**已建立的授权白名单（`~/.wbcu/allowlist.json`）与 TCC 授权
（归因到宿主 App，不是二进制路径）。但若你把 `wbcu` 换成了独立签名的 App Bundle，
TCC 身份会变，需要重新授权 —— 见 `permissions.md` 的「TCC 归因」。

## 卸载

```bash
rm -f ~/.local/bin/wbcu ~/.local/bin/wbcu-mcp
rm -rf ~/.local/share/wbcu
rm -rf ~/.wbcu                       # 含授权白名单，删了就全没了
# 技能
rm -rf ~/.workbuddy/skills/macos-background-computer-use
# MCP 配置：手动从 ~/.workbuddy/mcp.json 删掉 "wbcu" 段
```

TCC 授权需要单独撤销（`tccutil reset ...`），见 `permissions.md`。

## 恢复（换机 / 重装）

1. 装 Command Line Tools
2. 克隆仓库 → `./scripts/build.sh && ./scripts/install.sh`
3. `cp -R skills/macos-background-computer-use ~/.workbuddy/skills/`
4. 恢复 MCP 配置段（或重新加一遍）
5. `wbcu perm --prompt` → 系统设置里勾选 → 重启终端
6. `wbcu guard --app <bundleId> --allow` 逐个恢复白名单
7. `./tests/run-all.sh unit` 自检

**不要**跨机拷贝 `~/.wbcu/sessions/`（里面存的是 pid 与窗口号，换了机器全是废的）。
