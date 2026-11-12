# PR：v0.5.0 非阻塞能力优化

> 由于 GitHub 连接器的令牌没有 PR 写权限（`403 Resource not accessible by integration`），
> 这个文件就是 PR 描述，直接复制到 GitHub 的「New pull request」即可。
> 分支已推送：`feat/nonblocking-refinement`

**基线**：v0.4.2 全部能力 + v0.4.3 审计改动（本分支包含两者）
**变更**：见 `docs/receipt-v0.5.0.md` 与 `CHANGELOG.md` 第 0.5.0 节

## 一句话

只做四件事：少抢前台、少重复初始化、点得更准、把证据留下来。
**不新增任何审批 / 前台守卫 / 同步锁。**

## 四个改动

1. `wbcu trace` —— 被动激活追踪，四类归因（user / wbcu / external / harness），
   归因窗口是命令真实的 `[t0, t1]`
2. `wbcu launch` —— `activates=false` 后台启动；已在运行则不做任何事（实测前台变化 1 → 0）
3. 会话复用 + `--app` 直接寻址 —— `session start` 190ms → 94ms，且不再重复初始化
4. 按值搜索兜底 —— 结果落在「新出现的元素」上时不再死等超时（`=` 那步 739.9ms+failure → 282.6ms+success）

## 测试

- 新增 `tests/regression/no-reactivation.sh`：**13/13**
- 7 套 GUI 回归 + `selftest 53/53` 全部保持通过
- Browser Use 调查结论：本构建无浏览器交互接口，因此**不冒充**（`docs/browser-use.md`）

## 风险与未测

- 网页内交互：不可用（无接口）
- 外部浏览器 / 多显示器真机 / Electron：Not Tested，原因见回执第 7 节
