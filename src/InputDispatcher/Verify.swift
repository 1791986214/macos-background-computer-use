import Foundation
import ApplicationServices

// MARK: - ThirdHandEventDrivenVerifier
//
// 旧做法：操作后固定 usleep(240ms)，再整棵树算指纹 → 又慢又浪费。
// 新做法：先盯住「那个会变的元素」，等它变（AXObserver 通知 + 轻量轮询兜底），
// 变了立刻返回；超时才退回整树指纹。
//
// 注意：收到通知 ≠ 操作成功。通知只说明该元素的属性变了，
// 到底是不是预期结果，仍由调用方比对具体值决定。

private final class WatchBox {
    var fired = false
    var lastValue = ""
}

private func axValueCallback(_ observer: AXObserver,
                             _ element: AXUIElement,
                             _ notification: CFString,
                             _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let box = Unmanaged<WatchBox>.fromOpaque(refcon).takeUnretainedValue()
    box.fired = true
    CFRunLoopStop(CFRunLoopGetCurrent())
}

/// 读元素的字符串值（AXValue / AXTitle / AXDescription 任一可用）
func elementValueString(_ el: AXUIElement) -> String {
    for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let v = axAttr(el, attr as String) {
            if let s = v as? String, !s.isEmpty { return cleanText(s) }
            if let n = v as? NSNumber { return n.stringValue }
        }
    }
    return ""
}

struct ChangeWaitResult {
    var changed: Bool
    var waitedMs: Double
    var via: String        // "ax-observer" | "poll" | "timeout"
    var valueBefore: String
    var valueAfter: String
}

/// 等待指定元素的值发生变化。
///
/// 实现：AXObserver 监听 kAXValueChangedNotification，
/// 同时每 ~20ms 直接读一次值作为兜底（有些应用不发通知，或通知延迟）。
/// 谁先命中就返回，避免纯靠固定 sleep 浪费时间。
func waitForElementChange(pid: pid_t,
                          element: AXUIElement,
                          timeoutMs: Int = 1500) -> ChangeWaitResult {
    let t0 = nowNs()
    let before = elementValueString(element)

    var observer: AXObserver?
    let box = WatchBox()
    box.lastValue = before
    let refcon = Unmanaged.passUnretained(box).toOpaque()

    var observerReady = false
    if AXObserverCreate(pid, axValueCallback, &observer) == .success, let obs = observer {
        if AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString, refcon) == .success {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observerReady = true
        }
    }

    var via = "timeout"
    let deadline = nowNs() + UInt64(max(50, timeoutMs)) * 1_000_000

    while nowNs() < deadline {
        // 通知已到，或直接读值发现变了 —— 两条路任一即可
        let now = elementValueString(element)
        if now != before {
            via = observerReady && box.fired ? "ax-observer" : "poll"
            break
        }
        if box.fired {
            via = "ax-observer"
            break
        }
        let remainNs = deadline &- nowNs()
        let slice = min(0.02, Double(remainNs) / 1e9)
        if observerReady {
            CFRunLoopRunInMode(.defaultMode, slice, false)
        } else {
            usleep(useconds_t(slice * 1_000_000))
        }
    }

    if observerReady, let obs = observer {
        AXObserverRemoveNotification(obs, element, kAXValueChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    let after = elementValueString(element)
    let changed = after != before
    if changed && via == "timeout" { via = "poll" }
    return ChangeWaitResult(changed: changed, waitedMs: msSince(t0), via: via,
                            valueBefore: before, valueAfter: after)
}

/// 在两次快照之间找出「最可能代表操作结果」的变化元素路径。
///
/// 关键：**不能按路径索引对比**。树里节点数一变（文本换行、元素增删），
/// 后面所有 index 整体错位，会导致「全树都变了」，取最深节点得到垃圾路径
/// —— 实测就是这样把观测目标学成了 [0,0,0,0,0,0,0]。
/// 正确做法是按元素身份（role + identifier + title）匹配，再看值有没有变。
func detectChangedPath(before: AXSnapshot, after: AXSnapshot) -> [Int]? {
    func identity(_ it: AXItem) -> String {
        "\(it.role)#\(it.identifier)#\(it.title)#\(it.desc)"
    }
    var oldValues: [String: String] = [:]
    for it in before.items where it.role != "AXMenuBar" {
        let k = identity(it)
        if oldValues[k] == nil { oldValues[k] = it.value }
    }

    var candidates: [(path: [Int], depth: Int)] = []
    for it in after.items where it.role != "AXMenuBar" {
        guard ["AXStaticText", "AXTextField", "AXTextArea", "AXComboBox"].contains(it.role) else { continue }
        let k = identity(it)
        guard let prev = oldValues[k], prev != it.value else { continue }
        candidates.append((it.path, it.path.count))
    }
    // 取最深的那个：越是叶子，越可能是真正显示结果的地方
    return candidates.max(by: { $0.depth < $1.depth })?.path
}
