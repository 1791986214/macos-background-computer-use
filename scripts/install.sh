#!/bin/bash
# install.sh — 把引擎装到用户目录，并（可选）注册 MCP 与技能
#
#   ./scripts/install.sh              # 装二进制 + MCP 启动器
#   ./scripts/install.sh --skill      # 顺带装技能
#   ./scripts/install.sh --mcp        # 顺带写入 ~/.workbuddy/mcp.json（会先备份）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DST="$HOME/.local/bin"
SHARE="$HOME/.local/share/wbcu"
WITH_SKILL=0
WITH_MCP=0
for a in "$@"; do
  case "$a" in
    --skill) WITH_SKILL=1 ;;
    --mcp)   WITH_MCP=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  esac
done

[ -x "$REPO/bin/wbcu" ] || { echo "先构建：./scripts/build.sh" >&2; exit 1; }

mkdir -p "$BIN_DST" "$SHARE"
install -m 0755 "$REPO/bin/wbcu" "$BIN_DST/wbcu"
install -m 0644 "$REPO/mcp/wbcu-mcp.mjs" "$SHARE/wbcu-mcp.mjs"

# MCP 启动器：动态解析 node，不硬编码版本号路径，WorkBuddy 升级 node 不会断链
cat > "$BIN_DST/wbcu-mcp" <<'LAUNCHER'
#!/bin/bash
DIR="$HOME/.local/share/wbcu"
NODE="${WB_NODE:-}"
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then NODE="$(command -v node 2>/dev/null || true)"; fi
if [ -z "$NODE" ]; then
  NODE="$(ls -d "$HOME"/.workbuddy/binaries/node/versions/*/bin/node 2>/dev/null | head -1)"
fi
if [ -z "$NODE" ]; then
  echo "找不到 node（可设 WB_NODE 指向 node 可执行文件）" >&2
  exit 1
fi
exec "$NODE" "$DIR/wbcu-mcp.mjs" "$@"
LAUNCHER
chmod 0755 "$BIN_DST/wbcu-mcp"

echo "✅ 已安装："
echo "   $BIN_DST/wbcu"
echo "   $BIN_DST/wbcu-mcp"
echo "   $SHARE/wbcu-mcp.mjs"

if [ "$WITH_SKILL" = "1" ]; then
  mkdir -p "$HOME/.workbuddy/skills"
  rm -rf "$HOME/.workbuddy/skills/macos-background-computer-use"
  cp -R "$REPO/skills/macos-background-computer-use" "$HOME/.workbuddy/skills/"
  echo "✅ 技能已装：$HOME/.workbuddy/skills/macos-background-computer-use"
fi

if [ "$WITH_MCP" = "1" ]; then
  CFG="$HOME/.workbuddy/mcp.json"
  [ -f "$CFG" ] && cp "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)" && echo "   已备份原配置"
  python3 - "$CFG" "$BIN_DST/wbcu-mcp" "$BIN_DST/wbcu" <<'PY'
import json, pathlib, sys
cfg_path, mcp, binp = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(cfg_path)
cfg = json.loads(p.read_text()) if p.exists() else {"mcpServers": {}}
cfg.setdefault("mcpServers", {})
cfg["mcpServers"]["wbcu"] = {"command": mcp, "args": [], "env": {"WBCU_BIN": binp}}
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
print("   已写入 mcpServers.wbcu")
PY
  echo "⚠️  MCP 不会自动生效：需在 WorkBuddy 连接器管理页右上角「自定义连接器」点「信任」"
fi

echo
echo "下一步："
echo "  wbcu perm --prompt                              # 授权（按提示去系统设置勾选）"
echo "  wbcu guard --app com.apple.calculator --allow    # 授权一个应用"
echo "  wbcu selftest                                    # 自检"
case ":$PATH:" in
  *":$BIN_DST:"*) ;;
  *) echo
     echo "⚠️  $BIN_DST 不在 PATH 里，请加入（要放在 /usr/bin 之前）："
     echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
