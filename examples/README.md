# 示例

| 文件 | 演示什么 |
|---|---|
| `calc-7plus8.sh` | 最小闭环：建会话 → 按文本点击 → 读值验证 → 收尾 |
| `read-window.sh` | 只读：把某个应用窗口里的文本列出来，不执行任何点击 |
| `background-typing.sh` | 后台写文本（AXValue 路径），并解释为什么不能用按键 |

全部假设 `wbcu` 已在 `PATH`；没装的话用 `WBCU_BIN=/path/to/wbcu ./xxx.sh`。

跑之前先授权：

```bash
wbcu perm --prompt
wbcu guard --app com.apple.calculator --allow
```
