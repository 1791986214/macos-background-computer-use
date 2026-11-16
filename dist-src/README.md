# Third Hand v0.5.1 — 安装说明（先读我）

给 WorkBuddy 的「第三只手」：在**不抢你的鼠标、不切换你的前台**的前提下，让 AI 操作另一个 Mac 应用，
而且每一步都读值验证（不是「命令返回 0 就报成功」）。

---

## 一、这个包适合谁

| 情况 | 用哪个 |
|---|---|
| 只想让技能出现在 WorkBuddy 里，二进制自己会装 | 只解压 `skill/` 那部分 |
| 想直接能用（推荐） | 双击 `install.command` |

**要求**：macOS 14+，**Apple Silicon（arm64）**。Intel 机器这个二进制跑不了，需要自己编译。

> ⚠️ **Windows 完全用不了**，而且不是「重新编译」能解决的：它依赖的 Accessibility /
> ScreenCaptureKit / CGEvent 在 Windows 上不存在。Windows 请用 WorkBuddy 自带的
> Computer Use，或 PowerShell+UIA / pywinauto。详见 `docs/windows-feasibility.md`。

---

## 二、安装（三步，1 分钟）

### 第 1 步：解压并运行安装脚本

双击 `install.command`。

如果系统提示「无法打开，因为来自身份不明的开发者」：

```bash
# 在终端里进入解压后的目录，执行：
xattr -dr com.apple.quarantine .
chmod +x install.command
./install.command
```

脚本做四件事：装二进制到 `~/.local/bin/wbcu`、装覆盖层、装技能、
最后自动跑 `wbcu doctor` 自检。

### 第 2 步：给权限

系统设置 → 隐私与安全性 → 打开这三项，把**你运行 wbcu 的终端 App**（Terminal / iTerm / WorkBuddy）勾上：

- **辅助功能**（Accessibility）—— 读界面、点按钮，必需
- **屏幕录制**（Screen Recording）—— 截图才需要，不截图可以不勾
- **输入监控**（Input Monitoring）—— 一般不需要，报错再开

命令行触发授权弹窗：

```bash
wbcu perm --prompt
```

### 第 3 步：授权要操作的应用

**每个 App 单独授权**（这是有意设计的，不是障碍）：

```bash
wbcu guard --app com.apple.calculator --allow    # 计算器
wbcu guard --app com.apple.finder --allow        # 访达
```

---

## 三、验证装好了

```bash
export PATH="$HOME/.local/bin:$PATH"

wbcu doctor          # 应该看到「结论：一致，可直接用」
wbcu selftest        # 53 项纯逻辑自检
wbcu version         # 0.5.1
```

跑一次真实后台操作（前台不会变）：

```bash
wbcu launch --app com.apple.calculator --json          # 后台启动，不抢前台
wbcu session click --app com.apple.calculator --identifier One \
  --expect 1 --expect-el role:AXStaticText --json      # 点「1」并验证显示为 1
```

---

## 四、在 WorkBuddy 里怎么用

装好技能后，直接说人话：

> 帮我操作 Calculator 算 125 × 8，首次打开后我切到 Safari，你继续在后台完成，别再拉到前台。

Agent 会用 `wbcu launch`（不抢前台）+ `wbcu session click --expect ...`（读值验证）。

触发词：帮我操作另一个 Mac 应用 / 后台完成桌面任务 / 不要影响我正在用的鼠标 /
读一下那个应用里的信息 / 同时在两个应用里干活。

---

## 五、能做什么 / 不能做什么

| 能做 | 不能做 |
|---|---|
| 标准控件点击、输入、读值（NSButton / 输入框 / 菜单） | 页面里没有可访问性元素的游戏、全自绘界面 |
| 目标被别的窗口完全遮挡时仍能点中 | 非激活窗口里模拟键盘打字（改用写 AXValue） |
| 后台操作，前台不动、真实鼠标不动 | 依赖 key window 的快捷键（如 Cmd+W） |
| 网页操作走 `agent-browser`（另一条通道） | 需要人判断/不可逆的高风险操作（会先问你） |

---

## 六、常见问题

**Q：提示「killed」或「无法验证开发者」？**
A：`xattr -dr com.apple.quarantine <目录>`，然后重跑。二进制没有签名，这是正常现象。

**Q：点了没反应？**
A：先 `wbcu occlusion --window <id> --x <x> --y <y>` 看是不是被挡了；
再 `wbcu vis --window <id>` 看窗口是不是最小化了。

**Q：结果说 `inconclusive`？**
A：不是失败也不是成功——是「证据不足」。给个 `--expect <期望值>` 再跑一次。

**Q：怎么确认它没抢我前台？**
A：`wbcu trace start` → 跑任务 → `wbcu trace report`。
报告会按 `user / wbcu / external / harness` 归因，`wbcu=0` 就说明引擎没抢。

**Q：卸载？**
A：
```bash
rm -f ~/.local/bin/wbcu ~/.local/bin/wbcu-mcp
rm -rf ~/.local/share/wbcu ~/.workbuddy/skills/workbuddy-third-hand ~/.wbcu
```

---

## 七、版本

| 项 | 值 |
|---|---|
| 引擎 / 技能 | v0.5.1 |
| 构建日期 | 2026-11-16 |
| 架构 | arm64（Apple Silicon） |
| 仓库 | github.com/1791986214/macos-background-computer-use |

更新记录见技能正文第八节。
