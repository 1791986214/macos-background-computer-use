# 参与开发

## 改动前

1. 先跑 `./tests/run-all.sh unit`，确认基线是绿的
2. 读 `docs/architecture.md` 了解分层，避免把逻辑塞错层
3. 涉及投递/坐标/主窗口判据的改动，先读 `docs/compatibility.md` 的风险点章节

## 代码约定

- **不新增私有 API**。目前唯一的例外是 `_AXUIElementGetWindow`（经 dlsym + nil 兜底），
  它被 `tests/unit/run.sh` 检查着。要加新的，必须先在这条检查里显式登记并写明理由与替代方案。
- **不新增「假装成功」的兜底**。命令返回成功 ≠ 操作成功；做不到就返回错误码。
- **语义优先**：能用 AX 动作就不要投坐标，能投坐标就不要动全局 HID。
- **全局 HID 必须显式开关**：`--allow-global`，不允许静默降级。
- 坐标换算只走 `windowLocal` / `windowGlobal`，不要在别处手写减法。
- 新增能力 → 补 `selftest` 断言或 integration 用例，二选一必须做。

## 提交

```
<type>(<scope>): <summary>

type: feat | fix | docs | test | refactor | chore | perf
scope: capture | ax | dispatch | ghost | session | ci | docs
```

例：`fix(dispatch): 只在 AX 失败时降级，避免非幂等按钮重复执行`

提交信息里说清**为什么**，不只是**改了什么**。

## PR

1. 从 `main` 开分支：`feat/xxx`、`fix/xxx`
2. `./tests/run-all.sh unit` 必须绿
3. 有 GUI 环境的话再跑 `./tests/run-all.sh`，把输出贴进 PR
4. 更新 `CHANGELOG.md` 的 `[Unreleased]` 段
5. 涉及能力变化时同步 `docs/capability-matrix.md`（没实测就写 `Not Tested`）
6. 涉及技能行为变化时同步 `skills/workbuddy-third-hand/SKILL.md`

## 版本

- `0.1.x` 修 bug
- `0.2.x` 向后兼容的新能力
- `1.0.0` 正式稳定

**测试没绿不许发版。** 稳定版本不许被自动覆盖。
