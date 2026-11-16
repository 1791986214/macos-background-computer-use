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
cp -R skills/workbuddy-third-hand ~/.workbuddy/skills/
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
rm -rf ~/.workbuddy/skills/workbuddy-third-hand
# MCP 配置：手动从 ~/.workbuddy/mcp.json 删掉 "wbcu" 段
```

TCC 授权需要单独撤销（`tccutil reset ...`），见 `permissions.md`。

## 恢复（换机 / 重装）

1. 装 Command Line Tools
2. 克隆仓库 → `./scripts/build.sh && ./scripts/install.sh`
3. `cp -R skills/workbuddy-third-hand ~/.workbuddy/skills/`
4. 恢复 MCP 配置段（或重新加一遍）
5. `wbcu perm --prompt` → 系统设置里勾选 → 重启终端
6. `wbcu guard --app <bundleId> --allow` 逐个恢复白名单
7. `./tests/run-all.sh unit` 自检

**不要**跨机拷贝 `~/.wbcu/sessions/`（里面存的是 pid 与窗口号，换了机器全是废的）。

---

## 发布源（三个，改完都要同步）

技能与引擎有三个「源」，任何一次更新都要一起走，否则会出现「某处还是旧版」：

| 源 | 位置 | 更新方式 |
|---|---|---|
| 本地 | `~/.workbuddy/skills/workbuddy-third-hand/` | `bash scripts/install.sh`（默认含技能） |
| GitHub | `github.com/1791986214/macos-background-computer-use`（`skills/workbuddy-third-hand/`） | `git add -A && git commit && git push origin main` |
| 乐享知识库 | 空间「AI 与 机器人」→ 文件夹「桌面自动化与 Computer Use」→《Skill｜Third Hand（workbuddy-third-hand）》 | 见下 |

### 乐享落点（固定 ID，别再翻）

- space_id：`6357101d8b7a45eb85677b7e58dca393`（AI 与 机器人）
- 分类文件夹：`3491fe41113649549ec20383abd9136a`（桌面自动化与 Computer Use）
- 技能条目：`f169fecaf82f48f3ab8a8005aaf6efcf`（kb_file，md）

更新乐享时用 `file_import_markdown`：**传 `entry_id` 覆盖**（保留标题与节点身份），
不要新建——新建会多出一份旧的，反而更乱。首次创建才用 `parent_entry_id`。

### 一致性自检

```bash
wbcu doctor                      # 本地二进制 vs 技能版本
diff -r skills/workbuddy-third-hand ~/.workbuddy/skills/workbuddy-third-hand
git hash-object skills/workbuddy-third-hand/SKILL.md \
  && git rev-parse origin/main:skills/workbuddy-third-hand/SKILL.md
```

乐享那边的正文比 SKILL.md 精简（去掉 CLI 细节，保留用法、能力边界、版本记录），
所以不能用 hash 比对，只能按「版本号 + 更新日期」核对。
