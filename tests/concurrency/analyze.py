#!/usr/bin/env python3
# analyze.py — 并发活动归因分析
#
# 输入：
#   activity.jsonl   ActivityProbe 记录的用户输入时间线 + 前台采样
#   actions.jsonl    每次 Agent 动作一行（开始/结束时间、结果、硬约束字段）
#   meta.json        测试元信息（fixture 计数前后、目标窗口、期望值）
#
# 输出：一份可审计的 JSON 报告 + 人读摘要。
#
# 归因规则（写死在代码里，避免事后解释）：
#   · 前台变化发生在 t：若 [t-0.4, t+0.05] 内有用户输入事件 → user
#   · 否则 → agent（这就是「抢前台」）
#   · 按下表判断「事件有没有被注入到会话事件流」：
#       sourcePid != 0 的事件 = 合成/注入事件
#     坐标投递走 postToPid，不进会话流；若出现注入事件，说明退化成了 HID 全局注入。
import json, sys, os
from collections import defaultdict

act_path, meta_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(l) for l in open(act_path) if l.strip()] if os.path.exists(act_path) else []
meta = json.load(open(meta_path))

inputs = [r for r in rows if r.get("kind") == "input"]
samples = [r for r in rows if r.get("kind") == "sample"]
begin = next((r for r in rows if r.get("kind") == "begin"), {})
end = next((r for r in rows if r.get("kind") == "end"), {})

USER_TRIGGERS = {"leftMouseDown", "rightMouseDown", "keyDown", "scroll"}
LOOKBACK = 0.40
LOOKAHEAD = 0.05

# ---- 前台变化检测 ----
changes = []
prev = None
for s in samples:
    b = s.get("frontBundle", "")
    if prev is not None and b != prev:
        changes.append({"ts": s["ts"], "from": prev, "to": b,
                        "toName": s.get("frontName", "")})
    prev = b

def user_input_near(ts):
    for e in inputs:
        if e.get("type") in USER_TRIGGERS and ts - LOOKBACK <= e["ts"] <= ts + LOOKAHEAD:
            return e
    return None

harness = [float(t) for t in meta.get("harness_activations", [])]

def harness_near(ts):
    for t in harness:
        if abs(ts - t) <= 1.5:
            return t
    return None

user_changes, agent_changes, harness_changes = [], [], []
for c in changes:
    h = harness_near(c["ts"])
    e = user_input_near(c["ts"])
    if h is not None:
        # 脚本自己发起的切前台：既不是用户手点，也不该算 Agent 的锅
        c["attributed"] = "harness"
        harness_changes.append(c)
    elif e:
        c["attributed"] = "user"
        c["trigger"] = e.get("type")
        user_changes.append(c)
    else:
        c["attributed"] = "agent"
        agent_changes.append(c)

injected = [e for e in inputs if e.get("sourcePid", 0) not in (0, None)]
injected_from_agent = [e for e in injected if "wbcu" in (e.get("frontBundle") or "").lower()
                       or (e.get("sourcePid") or 0) > 0]

# ---- Agent 动作 ----
actions = [json.loads(l) for l in open(meta["actions_raw"]).read().splitlines() if l.strip()] \
    if meta.get("actions_raw") and os.path.exists(meta["actions_raw"]) else []

def a(k, d=None):
    return [x.get(k, d) for x in actions]

report = {
    "ok": True,
    "probe": {
        "tapOK": begin.get("tapOK"),
        "durationSec": round((end.get("elapsed") or 0), 2),
        "userInputEvents": len(inputs),
        "frontSamples": len(samples),
        "userActivities": sorted({e["type"] for e in inputs if e.get("type") in USER_TRIGGERS}),
    },
    "frontChanges": {
        "total": len(changes),
        "attributedToUser": len(user_changes),
        "attributedToAgent": len(agent_changes),
        "attributedToHarness": len(harness_changes),
        "harnessEvents": harness_changes,
        "agentEvents": agent_changes,
        "userEvents": user_changes[:10],
    },
    "injection": {
        "injectedEventsInSessionStream": len(injected),
        "note": "坐标投递走 postToPid，不进入会话事件流；出现注入事件说明退化成了全局 HID",
    },
    "agentActions": {
        "count": len(actions),
        "results": dict((r, sum(1 for x in actions if x.get("result") == r))
                        for r in set(a("result")) if r),
        "anyPhysicalCursorViolation": any(x.get("physicalCursorPreserved") is False for x in actions),
        "unverifiablePhysicalCursor": sum(1 for x in actions if x.get("physicalCursorPreserved") is None),
        "anyFrontViolation": any(x.get("frontAppPreserved") is False for x in actions),
        "unverifiableFront": sum(1 for x in actions if x.get("frontAppPreserved") is None),
        "userInputDuringActionCount": sum(1 for x in actions if x.get("userInputDuringAction")),
        "allTargetFocusPreserved": all(x.get("targetFocusPreserved") is True for x in actions),
        "targetWindowIds": sorted({x.get("targetWindowId") for x in actions if x.get("targetWindowId")}),
        "methods": sorted({x.get("method") for x in actions if x.get("method")}),
        "failureReasons": [x.get("failureReason") for x in actions if x.get("failureReason")],
    },
    "fixture": meta.get("fixture", {}),
}

# ---- 判定 ----
checks = []
def chk(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)})

fi = report["fixture"]
chk("没有归因于 Agent 的前台变化", len(agent_changes) == 0,
    f"{len(agent_changes)} 次：{[c['from'] + '→' + c['to'] for c in agent_changes][:3]}")
chk("Agent 动作数符合预期", len(actions) == fi.get("expected_actions", len(actions)),
    f"{len(actions)}/{fi.get('expected_actions')}")
chk("目标计数按预期增长（每次动作都落到目标）",
    fi.get("count_after", -1) - fi.get("count_before", 0) == fi.get("expected_actions", -1),
    f"{fi.get('count_before')}→{fi.get('count_after')}")
# 注意：null 表示「动作期间用户在动，归属不明」——不当作失败，也不当作通过。
chk("没有观察到物理鼠标被 Agent 移动", not report["agentActions"]["anyPhysicalCursorViolation"],
    f"归属不明 {report['agentActions']['unverifiablePhysicalCursor']} 次")
chk("没有观察到前台被 Agent 改变", not report["agentActions"]["anyFrontViolation"],
    f"归属不明 {report['agentActions']['unverifiableFront']} 次")
chk("全部动作未改变目标 keyWindow/第一响应者", report["agentActions"]["allTargetFocusPreserved"])
chk("目标窗口 ID 始终绑定同一个", len(report["agentActions"]["targetWindowIds"]) <= 1,
    report["agentActions"]["targetWindowIds"])
chk("没有合成事件进入会话事件流", len(injected) == 0, f"{len(injected)} 条")
chk("测试期间确有真实用户输入（否则并发结论无意义）",
    len(inputs) >= 3, f"{len(inputs)} 条输入事件")
chk("全部动作结果为 success",
    report["agentActions"]["results"].get("success", 0) == len(actions),
    report["agentActions"]["results"])

report["checks"] = checks
report["ok"] = all(c["ok"] for c in checks)
json.dump(report, open(out_path, "w"), ensure_ascii=False, indent=2)

print(f"  探针: 运行 {report['probe']['durationSec']}s，用户输入 {len(inputs)} 条，前台采样 {len(samples)} 次")
print(f"  前台变化 {len(changes)} 次：用户 {len(user_changes)} / 脚本 {len(harness_changes)} / Agent {len(agent_changes)}")
for c in user_changes[:5]:
    print(f"    · 用户({c['trigger']}) {c['from']} → {c['to']}")
print(f"  Agent 动作 {len(actions)} 次：{report['agentActions']['results']}，方法 {report['agentActions']['methods']}")
print(f"  会话流中的注入事件: {len(injected)}")
print()
for c in checks:
    print(f"  {'✅' if c['ok'] else '❌'} {c['name']}" + (f"（{c['detail']}）" if c['detail'] and not c['ok'] else ""))
print()
print(f"报告: {out_path}")
sys.exit(0 if report["ok"] else 1)
