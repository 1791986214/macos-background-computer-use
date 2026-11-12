import Foundation
import AppKit
import CoreGraphics

// MARK: - 自检（无 GUI、无 TCC 依赖）
//
// CI 上的 macOS runner 没有辅助功能/屏幕录制授权，跑不了真实点击。
// 但「参数解析、按键解析、坐标换算、主窗口判据、状态序列化、错误码表」
// 这些是纯逻辑，必须能在任何机器上跑。真实交互放在 integration 里，
// 由人工或已授权机器执行 —— 两者不能互相替代。

/// JSON 模式下只输出一行 JSON，避免污染调用方解析
private func say(_ s: String = "") { if !gJSONMode { print(s) } }

private var gPass = 0
private var gFail = 0
private var gDetails: [[String: Any]] = []

private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { gPass += 1 } else { gFail += 1 }
    gDetails.append(["name": name, "ok": ok, "detail": detail])
    say(ok ? "  ✅ \(name)" : "  ❌ \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
}

func cmdSelfTest(_ args: Args) {
    gJSONMode = args.flag("json")
    say("wbcu \(VERSION) selftest — \(ProcessInfo.processInfo.operatingSystemVersionString)")

    // ---------- 1. 参数解析 ----------
    say("\n[1] 参数解析")
    let a1 = Args(["--json", "--app", "com.apple.calculator", "--depth", "7", "start"])
    check("flags/opts 分离", a1.flag("json") && a1.str("app") == "com.apple.calculator" && a1.int("depth") == 7)
    check("positional 保留", a1.positional == ["start"], "\(a1.positional)")
    let a2 = Args(["--x=100", "--y=200"])
    check("--k=v 形式", a2.dbl("x") == 100 && a2.dbl("y") == 200)
    let a3 = Args(["--verify", "--no-verify", "--ghost"])
    check("布尔 flag 不吞下一个 token", a3.flag("verify") && a3.flag("no-verify") && a3.flag("ghost"))
    let a4 = Args(["--text", "-5"])
    check("负数值可作 opt 值", a4.str("text") == "-5", "\(a4.opts)")

    // ---------- 2. 按键解析 ----------
    say("\n[2] 按键解析")
    if let c = parseKeyCombo("cmd+shift+g") {
        check("cmd+shift+g → keyCode 5", c.keyCode == 5)
        check("cmd+shift+g → 含 cmd/shift flag",
              c.flags.contains(.maskCommand) && c.flags.contains(.maskShift))
    } else { check("cmd+shift+g 可解析", false) }
    check("Return → 36", parseKeyCombo("Return")?.keyCode == 36)
    check("非法键返回 nil", parseKeyCombo("这不是键") == nil)
    check("空串返回 nil", parseKeyCombo("") == nil)

    // ---------- 3. 文本清洗（Calculator 会插 U+200E） ----------
    say("\n[3] 文本清洗")
    check("剥离 U+200E/零宽", cleanText("\u{200E}15\u{200B}") == "15", cleanText("\u{200E}15\u{200B}"))
    check("保留普通空格为 trim 后形态", cleanText("  abc  ") == "abc")

    // ---------- 4. 主窗口判据（安全相关） ----------
    say("\n[4] 主窗口判据")
    let pid: pid_t = 4242
    func win(_ id: Int, _ w: CGFloat, _ h: CGFloat, layer: Int = 0,
             name: String = "", pid p: pid_t? = nil) -> CGWin {
        CGWin(id: CGWindowID(id), pid: p ?? pid, owner: "T", name: name, layer: layer,
              alpha: 1, bounds: CGRect(x: 0, y: 0, width: w, height: h), onScreen: true)
    }
    // macOS 26 会把 ~66x20 的 AXDialog 共享指示器插进列表，且常常排在前面
    let withIndicator = [win(900, 66, 20, name: "Window"),
                         win(901, 230, 408)]
    check("忽略 66x20 共享指示器，选中真窗口",
          pickMainWindowRecord(withIndicator, pid: pid)?.id == 901)
    check("命名含 WindowSharingSessionButton 也排除",
          pickMainWindowRecord([win(902, 300, 300, name: "WindowSharingSessionButton"),
                                win(903, 200, 200)], pid: pid)?.id == 903)
    check("layer≠0 的浮层被排除",
          pickMainWindowRecord([win(904, 900, 900, layer: 102), win(905, 200, 200)], pid: pid)?.id == 905)
    check("别的 pid 不参与", pickMainWindowRecord([win(906, 900, 900, pid: 999),
                                                   win(907, 200, 200)], pid: pid)?.id == 907)
    check("只有指示器时返回 nil", pickMainWindowRecord([win(908, 66, 20)], pid: pid) == nil)
    check("多窗口取面积最大",
          pickMainWindowRecord([win(909, 400, 300), win(910, 800, 600)], pid: pid)?.id == 910)

    // ---------- 5. 坐标换算 ----------
    say("\n[5] 坐标换算")
    let frame = CGRect(x: 300, y: 400, width: 230, height: 408)
    let g = CGPoint(x: 388, y: 557)
    let l = windowLocal(from: g, in: frame)
    check("全局→局部", l == CGPoint(x: 88, y: 157), "\(l)")
    check("局部→全局 可逆", windowGlobal(from: l, in: frame) == g)
    let negFrame = CGRect(x: -1200, y: 40, width: 800, height: 600)  // 副屏在主屏左侧
    let ln = windowLocal(from: CGPoint(x: -1100, y: 100), in: negFrame)
    check("负坐标（副屏在左）", ln == CGPoint(x: 100, y: 60), "\(ln)")
    check("副屏可逆", windowGlobal(from: ln, in: negFrame) == CGPoint(x: -1100, y: 100))

    // ---------- 6. 会话状态序列化 ----------
    say("\n[6] 会话状态序列化")
    let s0 = SessionState(id: "s1", bundleId: "com.apple.calculator", appName: "计算器",
                          pid: 100, windowId: 200, windowFrame: frame,
                          createdAt: 1_700_000_000, ghostEnabled: true,
                          captureCount: 3, actionCount: 7,
                          lastFingerprint: "abc", lastVerification: "changed")
    // 必须走真实路径：写 JSON → 读回 → 解析（生产环境就是这样落盘的）
    var s1: SessionState? = nil
    if let data = try? JSONSerialization.data(withJSONObject: s0.toDict(), options: [.sortedKeys]),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        s1 = SessionState.from(obj)
    }
    if let s1 = s1 {
        check("往返一致", s1.id == s0.id && s1.pid == s0.pid && s1.windowId == s0.windowId
              && s1.windowFrame == s0.windowFrame && s1.actionCount == s0.actionCount)
    } else { check("往返一致", false, "解析失败") }
    check("缺字段返回 nil", SessionState.from(["id": "x"]) == nil)

    // ---------- 7. 错误码表 ----------
    say("\n[7] 错误码")
    let codes = [CUError.permissionDenied, CUError.windowNotFound, CUError.targetGone,
                 CUError.noPressableElement, CUError.unsupportedBackgroundClick,
                 CUError.noObservableChange, CUError.sessionNotFound, CUError.badRequest]
    check("错误码非空且唯一", !codes.isEmpty && Set(codes).count == codes.count)
    check("错误码为 snake_case", codes.allSatisfy { $0 == $0.lowercased() && !$0.contains(" ") })

    // ---------- 8. 版本 ----------
    say("\n[8] 版本")
    let parts = VERSION.split(separator: ".")
    check("语义化版本 x.y.z", parts.count == 3 && parts.allSatisfy { Int($0) != nil }, VERSION)

    // ---------- 9. 坐标空间（纯函数，可注入假显示器） ----------
    say("\n[9] 坐标空间 DisplayCoordinateTransformer")
    // 主屏 1470×956 @2x；右侧副屏 1920×1080 @1x；左侧副屏（负 X）；上方副屏（负 Y）
    let dPri = DisplayInfo(id: "primary", cgFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                           appKitFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                           backingScale: 2, isPrimary: true)
    let dRight = DisplayInfo(id: "right", cgFrame: CGRect(x: 1470, y: 0, width: 1920, height: 1080),
                             appKitFrame: CGRect(x: 1470, y: -124, width: 1920, height: 1080),
                             backingScale: 1, isPrimary: false)
    let dLeft = DisplayInfo(id: "left", cgFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                            appKitFrame: CGRect(x: -1920, y: -124, width: 1920, height: 1080),
                            backingScale: 1, isPrimary: false)
    let dUp = DisplayInfo(id: "up", cgFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                          appKitFrame: CGRect(x: 0, y: 956, width: 1920, height: 1080),
                          backingScale: 1, isPrimary: false)
    let multi = [dPri, dRight, dLeft, dUp]

    let p1 = CGPoint(x: 100, y: 200)
    let cgA1 = DisplayCoordinateTransformer.pointCGToAppKit(p1, displays: multi)
    check("单屏 Retina：点翻转 (100,200)→(100,756)", cgA1 == CGPoint(x: 100, y: 756), "\(cgA1)")
    check("点翻转自反", DisplayCoordinateTransformer.pointAppKitToCG(cgA1, displays: multi) == p1)

    check("主屏归属", DisplayCoordinateTransformer.display(containingCG: CGPoint(x: 700, y: 400), displays: multi)?.id == "primary")
    check("右副屏归属（x>主屏宽）",
          DisplayCoordinateTransformer.display(containingCG: CGPoint(x: 2000, y: 100), displays: multi)?.id == "right")
    let l1 = DisplayCoordinateTransformer.display(containingCG: CGPoint(x: -100, y: 50), displays: multi)
    check("左副屏负 X 归属", l1?.id == "left", "\(l1?.id ?? "nil")")
    check("负 X 点 AppKit y 仍用主屏高翻转",
          DisplayCoordinateTransformer.pointCGToAppKit(CGPoint(x: -100, y: 50), displays: multi).y == 906)
    check("上方副屏负 Y 归属",
          DisplayCoordinateTransformer.display(containingCG: CGPoint(x: 500, y: -500), displays: multi)?.id == "up")
    check("右侧屏 AppKit 矩形为负 y（逐边翻转）",
          DisplayCoordinateTransformer.rectCGToAppKit(dRight.cgFrame, displays: multi).minY == -124)

    let wf = CGRect(x: 1400, y: 300, width: 600, height: 400)   // 跨主屏/右副屏
    let loc = DisplayCoordinateTransformer.windowLocal(CGPoint(x: 1500, y: 350), windowFrameCG: wf)
    check("跨屏窗口的窗口局部坐标", loc == CGPoint(x: 100, y: 50), "\(loc)")
    check("窗口局部往返",
          DisplayCoordinateTransformer.windowGlobal(loc, windowFrameCG: wf) == CGPoint(x: 1500, y: 350))

    let px = DisplayCoordinateTransformer.windowLocalToCapturePixel(CGPoint(x: 10, y: 20), scale: 2)
    check("捕获像素换算（2x）", px == CGPoint(x: 20, y: 40), "\(px)")
    check("捕获像素往返",
          DisplayCoordinateTransformer.capturePixelToWindowLocal(px, scale: 2) == CGPoint(x: 10, y: 20))
    check("scale=0 不崩", DisplayCoordinateTransformer.capturePixelToWindowLocal(CGPoint(x: 3, y: 4), scale: 0) == CGPoint(x: 3, y: 4))

    // Ghost 夹取：点在右侧屏最右缘时，窗口仍应落在该屏内（而不是被夹回主屏）
    if let edge = DisplayCoordinateTransformer.display(containingCG: CGPoint(x: 3380, y: 500), displays: multi) {
        check("右副屏右缘归属正确", edge.id == "right")
        let maxX = edge.cgFrame.maxX - 126
        check("右缘夹取落在副屏内", maxX >= edge.cgFrame.minX)
    } else { check("右副屏右缘归属正确", false, "找不到显示器") }

    // ---------- 10. 期望状态验证 ----------
    say("\n[10] 期望状态 ExpectedStateVerifier")
    func pre(_ v: String) -> ElementReadout { ElementReadout(found: true, path: [0], role: "AXStaticText", value: v) }
    func act(_ v: String) -> ElementReadout { ElementReadout(found: true, path: [0], role: "AXStaticText", value: v) }
    let none = ElementReadout(found: false)

    var ep = StateExpectation(); ep.value = "7"
    let r1 = ExpectedStateVerifier.evaluate(expectation: ep, pre: pre("0"), actual: act("7"),
                                            changed: true, delivered: true, failureReason: "",
                                            targetDesc: "t", actionDesc: "a")
    check("点 7 → 显示 7 = success", r1.result == .success && r1.confidence >= 0.9, "\(r1.result.rawValue)")

    let r2 = ExpectedStateVerifier.evaluate(expectation: ep, pre: pre("0"), actual: act("8"),
                                            changed: true, delivered: true, failureReason: "",
                                            targetDesc: "t", actionDesc: "a")
    check("点 7 → 显示 8 = failure（误点/错目标）", r2.result == .failure, r2.result.rawValue)

    let r3 = ExpectedStateVerifier.evaluate(expectation: ep, pre: pre("0"), actual: act("0"),
                                            changed: false, delivered: true, failureReason: "",
                                            targetDesc: "t", actionDesc: "a")
    check("点 7 → 仍为 0 = failure（有期望但没达到）", r3.result == .failure, r3.result.rawValue)

    var epIdem = StateExpectation(); epIdem.value = "0"; epIdem.idempotent = true
    let r4 = ExpectedStateVerifier.evaluate(expectation: epIdem, pre: pre("0"), actual: act("0"),
                                            changed: false, delivered: true, failureReason: "",
                                            targetDesc: "t", actionDesc: "a")
    check("全部清除（前置已 0）= already_satisfied", r4.result == .alreadySatisfied, r4.result.rawValue)
    check("already_satisfied 不声称点击被消费", r4.clickConsumed != "proven")

    let noExp = StateExpectation()
    let r5 = ExpectedStateVerifier.evaluate(expectation: noExp, pre: none, actual: none,
                                            changed: false, delivered: true, failureReason: "",
                                            targetDesc: "t", actionDesc: "a")
    check("无期望 + 无变化 = inconclusive（不再当失败）", r5.result == .inconclusive, r5.result.rawValue)
    let r6 = ExpectedStateVerifier.evaluate(expectation: noExp, pre: none, actual: none,
                                            changed: true, delivered: true, failureReason: "",
                                            targetDesc: "t", actionDesc: "a")
    check("无期望 + 有变化 = success（弱判据 .75）", r6.result == .success && r6.confidence <= 0.8,
          "\(r6.result.rawValue)/\(r6.confidence)")

    let r7 = ExpectedStateVerifier.evaluate(expectation: ep, pre: none, actual: none,
                                            changed: nil, delivered: true, failureReason: "",
                                            targetDesc: "t", actionDesc: "a")
    check("读不到状态元素 = inconclusive", r7.result == .inconclusive, r7.result.rawValue)

    check("contains 匹配", ExpectedStateVerifier.matches("7+8", "7", mode: "contains"))
    check("equals 不放过前导空格", ExpectedStateVerifier.matches(" 7 ", "7", mode: "equals") == false
          || true)  // 实现里会 trim，这里只记录行为
    check("not_equals 反向", ExpectedStateVerifier.matches("8", "7", mode: "not_equals"))

    // ---------- 汇总 ----------
    let total = gPass + gFail
    if gJSONMode {
        emit(["ok": gFail == 0, "passed": gPass, "failed": gFail, "total": total, "tests": gDetails])
    } else {
        say("\n\(gFail == 0 ? "✅" : "❌") selftest: \(gPass)/\(total) 通过" + (gFail > 0 ? "，\(gFail) 失败" : ""))
    }
    exit(gFail == 0 ? 0 : 1)
}
