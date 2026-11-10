import Foundation
import AppKit

let VERSION = "0.2.0"

func usage() {
    print("""
    wbcu \(VERSION) — WorkBuddy macOS Computer Use 原生辅助进程

    会话（推荐入口：一次解析，全程复用同一引擎）
      wbcu session start --app com.apple.calculator [--no-ghost]
      wbcu session list | state --id SID | end --id SID [--all]
      wbcu session capture --id SID [--out f.png] [--max-width 1200]
      wbcu session inspect --id SID [--max 200] [--depth 12]
      wbcu session click   --id SID (--x X --y Y | --element N | --text "保存")
                           [--exact] [--label 文案] [--no-ghost] [--no-verify]
      wbcu session type    --id SID --text "内容" [--element N]
      wbcu session key     --id SID --combo "cmd+a"
      wbcu session cursor  --id SID --x 100 --y 80 [--animate] [--label 点这里]
      wbcu session verify  --id SID [--expect "15"]

    能力
      wbcu capabilities [--json]                   能力矩阵与权限、错误码清单
      wbcu selftest [--json]                       纯逻辑自检（无 GUI / 无 TCC 依赖，CI 用）

    权限
      wbcu perm [--json] [--prompt]                三态权限检查（AX / 屏幕录制 / 输入注入）
      wbcu idle [--json]                           距上次真实用户输入的时间（区分「抢焦点」与「用户自己在动」）

    发现
      wbcu apps [--all] [--json]                   运行中的应用（含窗口数、前台状态）
      wbcu windows [--app X|--pid N] [--all] [--json]   窗口枚举（SCK + CGWindowList）

    Accessibility
      wbcu ax-tree [--app X|--pid N] [--depth 12] [--max 2000] [--json]
      wbcu ax-find --text "保存" [--role button] [--action press] [--pid N]
      wbcu ax-act (--index 42 | --path 0/1/2 | --window ID) [--action AXPress] [--pid N]
      wbcu ax-set --index 42 --value "hello" [--attr AXValue] [--pid N]
      wbcu ax-hit --x 100 --y 200                  屏幕点命中测试
      wbcu app-state [--app X|--pid N] [--max-width 1024]   截图 + AX 文本（Codex 风格）

    捕获
      wbcu shot [--window ID | --app X | --x --y --w --h] --out f.png [--analyze]
      wbcu stream [--window ID | --app X] [--seconds 6] [--dir frames/]
      wbcu analyze <png>                            紫胶囊像素分析

    输入
      wbcu click --app X --x 100 --y 200 [--mode auto|ax|targeted|global] [--verify] [--ghost]
                                                 后台点击：AX 优先 → 进程级定向投递（带窗口上下文）
      wbcu click --x 900 --y 700 --allow-global  全局注入（会移动真实指针，需显式批准）
      wbcu ghost start|move|click|hide|stop|daemon    Agent 虚拟光标（不碰真实鼠标）
      wbcu move --x 100 --y 200
      wbcu drag --x1 10 --y1 10 --x2 200 --y2 200
      wbcu scroll [--dx 0 --dy -5] [--x X --y Y] [--pid N]
      wbcu key "cmd+shift+g" [--pid N] [--repeat N]
      wbcu type --text "你好" [--pid N]
      wbcu activate --app X
      wbcu window-move [--app X] --x 100 --y 100 [--w 800 --h 600]

    指示器研究
      wbcu indicator-scan [--app X|--pid N]         一次性观察紫胶囊 / AX 共享元素
      wbcu indicator-exp  [--app X|--pid N] [--seconds 4]   开/停捕获全生命周期实验
    """)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first, cmd != "-h", cmd != "--help" else { usage(); exit(0) }
let args = Args(Array(argv.dropFirst()))
if args.flag("json") { gJSONMode = true }
if args.flag("pretty") { gPretty = true }

// 关键：先建立 WindowServer/CGS 连接。
// 否则 _AXUIElementGetWindow、SCScreenshotManager 等在冷启动时会踩到
// "Assertion failed: (did_initialize), function CGS_REQUIRE_INIT"。
bootstrapWindowServer()

switch cmd {
case "perm": cmdPerm(args)
case "capabilities": cmdCapabilities(args)
case "selftest": cmdSelfTest(args)
case "session": cmdSession(args)
case "guard": cmdGuard(args)
case "mouse-pos": cmdMousePos(args)
case "idle": cmdIdle(args)
case "apps": cmdApps(args)
case "windows": cmdWindows(args)
case "ax-tree": cmdAXTree(args)
case "ax-find": cmdAXFind(args)
case "ax-act": cmdAXAct(args)
case "ax-set": cmdAXSet(args)
case "ax-hit": cmdAXHit(args)
case "app-state": cmdAppState(args)
case "shot": cmdShot(args)
case "analyze": cmdAnalyze(args)
case "stream": cmdStream(args)
case "click": cmdClick(args)
case "ghost": cmdGhost(args)
case "act": cmdAct(args)
case "move": cmdMove(args)
case "drag": cmdDrag(args)
case "scroll": cmdScroll(args)
case "key": cmdKey(args)
case "type": cmdType(args)
case "activate": cmdActivate(args)
case "window-move": cmdWindowMove(args)
case "indicator-scan": cmdIndicatorScan(args)
case "indicator-oneshot": cmdIndicatorOnce(args)
case "indicator-exp": cmdIndicatorExperiment(args)
case "version": print(VERSION)
default:
    FileHandle.standardError.write("未知命令: \(cmd)\n".data(using: .utf8)!)
    usage()
    exit(2)
}
