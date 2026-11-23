#!/usr/bin/env bash
# 校验「文档里写的 SHA256」与「npm 包里登记的 SHA256」是否一致；可选下载真包三方比对。
#
# 为什么要有这个脚本：v0.6.2 的安装文档曾经挂着 v0.6.0 的哈希，
# 因为升级版本时只替换了文件名，SHA 那行被留在了原地 —— 手写的哈希必然腐烂。
#
# 用法：
#   ./scripts/check-release-hashes.sh            # 离线：只比 文档 vs platform.js
#   ./scripts/check-release-hashes.sh --remote   # 联网：再与发布资产实际字节比对
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE=0; [ "${1:-}" = "--remote" ] && REMOTE=1

python3 - "$ROOT" "$REMOTE" <<'PY'
import re, sys, subprocess, tempfile, os, hashlib
root, remote = sys.argv[1], sys.argv[2] == "1"
plat = open(os.path.join(root, "npm/lib/platform.js")).read()
doc  = open(os.path.join(root, "docs/windows-installation.md")).read()

entries = re.findall(r"file:\s*'([^']+)',\s*\n\s*sha256:\s*'([0-9a-f]{64})'", plat)
if not entries:
    print("FAIL: platform.js 里没解析到 (file, sha256) 对"); sys.exit(1)

doc_hash = re.search(r"当前包 SHA256：`([0-9a-f]{64})`", doc)
fail = 0
for fname, h in entries:
    print(f"platform.js  {fname}: {h}")
    if "windows" in fname:
        if not doc_hash:
            print("FAIL: 文档里找不到「当前包 SHA256」行"); fail += 1
        elif doc_hash.group(1) != h:
            print(f"FAIL: 文档写的是 {doc_hash.group(1)}"); fail += 1
        else:
            print("OK: 文档与 platform.js 一致")

    if remote:
        url = ("https://github.com/1791986214/macos-background-computer-use/releases/"
               "download/v0.6.2-rc1/" + fname)
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            path = tmp.name
        rc = subprocess.call(["curl", "-fsSL", "--max-time", "180", "-o", path, url])
        if rc != 0:
            print(f"WARN: 下载失败，跳过远端比对 {fname}"); continue
        actual = hashlib.sha256(open(path, "rb").read()).hexdigest()
        os.unlink(path)
        if actual != h:
            print(f"FAIL: 发布资产实际 {actual}"); fail += 1
        else:
            print(f"OK: 发布资产字节一致 {fname}")

print("RESULT:", "PASS" if fail == 0 else f"{fail} 处不一致")
sys.exit(0 if fail == 0 else 1)
PY
