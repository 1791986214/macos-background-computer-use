# 部署回执 · WorkBuddy Third Hand v0.4.1

**出具时间**：2026-11-11 10:3x（GMT+8）
**执行人**：小乐
**变更类型**：缺陷修复（hotfix）
**原因**：用户报告「启动后前台被抢」

---

## 一、结论

| 项 | 内容 |
|---|---|
| 版本 | **0.4.1**（原 0.4.0） |
| 提交 | `b60e9eb` `fix: 虚拟光标 daemon 不再抢用户前台（v0.4.1） (#5)` |
| 标签 | `v0.4.1`（已推远端） |
| 分支 | `main`，与 `origin/main` 同步（0 个未推送提交） |
| Release | https://github.com/1791986214/macos-background-computer-use/releases/tag/v0.4.1 |
| PR | [#5](https://github.com/1791986214/macos-background-computer-use/pull/5)（squash 合并，CI 通过） |
| 本机安装 | 已完成，`wbcu version` → 0.4.1 |

---

## 二、问题与根因

**你反馈的是对的**：「怎么我前台会还抢你」。这不是感觉，是能复现的缺陷。

```
起点前台: WorkBuddy
wbcu ghost start 之后 → 前台: wbcu      ← 复现
```

**根因**：虚拟光标 daemon 是个 `NSApplication`，被当普通可激活进程拉起。
它调 `app.run()` 完成启动流程时，系统会把它激活成前台应用。

排查中排除的三条路（都实测过，不是没试）：

| 尝试 | 结果 |
|---|---|
| `setActivationPolicy(.prohibited)` | 不抢前台，但**窗口画不出来**（紫色像素恒为 0，光标不可见） |
| `NSApp.deactivate()` | 抢到的激活不会还回去 |
| CLI 侧记前台，启动后 `activate` 还原 | 时机太早被 daemon 覆盖；还原偏差还会把焦点还给**错误**的应用（实测还给过 ChatGPT） |

**修法**：把 daemon 打进 `LSUIElement` 的 helper bundle（`ThirdHandOverlay.app`）。
代理型 App 能渲染窗口，但**不参与应用激活** —— 不是「抢了再还」，是从根上没有可抢的焦点。

---

## 三、本机安装清单

| 部件 | 路径 | 校验 |
|---|---|---|
| 原生引擎 | `~/.local/bin/wbcu` | 0.4.1，SHA256 `10e5c200…65262f4` |
| 覆盖层 bundle | `~/.local/share/wbcu/ThirdHandOverlay.app` | `LSUIElement = true`，已签名 |
| MCP 服务器 | `~/.local/share/wbcu/wbcu-mcp.mjs` + `~/.local/bin/wbcu-mcp` | 16 个 `cu_*` 工具 |
| 技能 | `~/.workbuddy/skills/workbuddy-third-hand/` | 含 `SKILL.md` / `examples/` / `references/` |
| 经验库 | `~/.wbcu/experience.json` | 8 条（stable 5 / candidate 3），中位 33ms |
| 运行中 daemon | pid 13447，从 `ThirdHandOverlay.app` 启动 | 已确认路径 |

---

## 四、验证结果

### 单点验证（已通过，可复现）

```
基线:                WorkBuddy
wbcu ghost start 后: WorkBuddy      ✅ 未被抢
daemon 实际路径:     ~/.local/share/wbcu/ThirdHandOverlay.app/Contents/MacOS/wbcu ghost daemon
wbcu ghost move 后:  WorkBuddy      ✅ 仍未被抢
光标可见性:          白填充 + 紫描边箭头 + 「验证」标签（截图已确认）
```

### 回归测试（新增，已入库）

`tests/regression/no-focus-steal.sh` 覆盖三个阶段：daemon 启动 / 5 次连续点击 / 收尾，
并带 `idle` 干扰判定。

**⚠️ 待复验**：最后一次完整跑时你正在用电脑（`idle 0s < 耗时 4s`），
脚本按设计**拒绝下结论**而不是硬判。请在屏幕空闲时跑一次拿正式结论：

```bash
cd /Users/lang/WorkBuddy/macos-background-computer-use
./tests/regression/no-focus-steal.sh
```

---

## 五、本次其他改动

| 项 | 说明 |
|---|---|
| 单元测试新增 lint | shell 脚本里 `$VAR` 紧贴中文必须写 `${VAR}` —— 这个坑连续踩两次，一次让整段测试挂掉 |
| `scripts/build.sh` | 自动产出 `ThirdHandOverlay.app` 并 ad-hoc 签名 |
| `scripts/install.sh` | 一并安装覆盖层 bundle；缺失时提示先构建 |
| `CHANGELOG.md` | 补齐 0.4.1 段落，含根因与三条被排除的思路 |

---

## 六、已知限制（不粉饰）

1. **窗口级截图中看不到虚拟光标**。它是独立 overlay 窗口（layer 102），
   只出现在**屏幕区域截图**里；用 `SCContentFilter(desktopIndependentWindow:)` 抓单个窗口时不含它。
   这不是 bug，是分层设计的必然结果。
2. 完整「0 次抢前台」结论需要空闲屏幕复验（见上）。
3. Electron / 多显示器 / macOS 27 仍未实测。

---

## 七、回滚

```bash
cd /Users/lang/WorkBuddy/macos-background-computer-use
git checkout v0.4.0 && ./scripts/build.sh && ./scripts/install.sh --skill
```

注意：回滚到 0.4.0 会**恢复抢前台的行为**。只在你怀疑 0.4.1 引入新问题时才回滚。

覆盖层可单独停用（不影响后台点击，只是不显示光标）：

```bash
wbcu ghost stop
```

---

## 八、升级方法（其他机器）

```bash
git pull && ./scripts/build.sh && ./scripts/install.sh --skill
wbcu selftest        # 27/27，无需任何系统授权
```
