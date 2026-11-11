# 应用经验记忆（App Experience Memory）

Third Hand 第二次操作同一个应用时，不该再从整棵 AX 树里重新找按钮。
这份文档说明经验库存什么、怎么匹配、怎么失效、以及**不存什么**。

## 一句话原理

第一次操作成功后，把「目标元素的 AX 路径 + 身份特征」记下来；
下次先按路径 `O(深度)` 回查（通常 5–6 跳），再用 `role / identifier / label` 校验。
**校验不过就当没命中**，退回完整遍历 —— 宁慢勿错。

## 经验库在哪

```
~/.wbcu/experience.json      # 本机，不上传、不同步、不进仓库
~/.wbcu/perf/perf.jsonl      # 每次动作一行性能记录
```

`wbcu experience list|stats|clear` 可查看与清理。

## 一条经验长什么样

```jsonc
{
  "key": "click|Seven|AXButton",
  "intent": "click",
  "label": "7",
  "role": "AXButton",
  "identifier": "Seven",
  "path": [0,0,0,0,0,5],          // AX 路径，与 walkAX 的子节点顺序一致
  "relRect": [0.23,0.59,0.20,0.11], // 相对窗口的归一化矩形（窗口缩放后仍可参考）
  "windowSize": [230,408],
  "actionMode": "ax",
  "validation": "fingerprint",     // axvalue | fingerprint | axpress-only
  "observePath": [0,0,0,0,0,1,0],  // 可选：验证时盯哪个元素
  "successCount": 7, "failureCount": 0,
  "recentLatencyMs": [62,71,88,65],
  "lastVerifiedAt": 1794300000,
  "status": "stable"               // candidate | verified | stable
}
```

## 生命周期：候选 → 已验证 → 稳定

| 成功次数 | 状态 | 含义 |
|---|---|---|
| 1 | `candidate` | 试过，但只一次，可能撞运气 |
| ≥3 | `verified` | 多次复现，可优先使用 |
| ≥6 | `stable` | 稳定路径，最快通道 |

失败会降级：失败数 ≥3 且失败率 >50% 时**直接删除该条**，
避免「错误经验不断强化自己」。

## 匹配优先级

1. `AXIdentifier`（开发者显式给的锚点，最稳）
2. `role + label/desc` 精确相等
3. 同 key 下按 `confidence` 排序，逐个用路径回查 + 校验

**历史绝对坐标不是最高优先级**，只作为 `relRect` 参考存在。
窗口移动、缩放、换语言、换主题、应用升级都可能让旧坐标失效。

## 失效机制

| 触发 | 处理 |
|---|---|
| 路径回查不到元素 | 视为 miss，走完整遍历 |
| role 变了 | 视为 miss（布局已变） |
| identifier/label 不匹配 | 视为 miss |
| 元素尺寸为 0 | 视为 miss（已折叠/隐藏） |
| 连续观测超时 ≥3 | 摘掉 `observePath`，退回指纹验证 |
| 失败数 ≥3 且失败率 >50% | 删除该条经验 |

实测：把 `path` 手动改成不存在的索引后，引擎判 miss → 完整遍历 → 操作仍然正确，
并把路径**修复回正确值**（见 README 的验收 E）。

## 隐私：什么不进经验库

- ❌ 窗口标题（可能含用户文档名）
- ❌ 截图与任何像素数据
- ❌ 文本内容（输入框里的文字、聊天正文）
- ❌ 密码、验证码
- ✅ 只存：AX 角色、标识符、控件自身标签（如「7」「全部清除」）、路径、归一化位置、统计

经验库文件本身在 `~/.wbcu/`，默认不同步到任何地方。

## 迁移与回滚

文件顶层有 `schemaVersion`。版本不匹配时：

1. 把旧文件复制为 `experience.json.v<旧版本>.bak`
2. 以空库重新开始

这样升级不会崩，也不会静默丢数据（备份还在）。
要回滚，把 `.bak` 改回 `experience.json` 即可。

## 它不做什么

- 不替代验证：经验只加速**找目标**，不改变「操作后必须确认结果」的原则。
- 不做工作流记忆：目前只记单个控件，不记「整个计算流程」。
- 不跨应用泛化：经验按 bundleId 隔离，计算器的路径不会用到别处。
