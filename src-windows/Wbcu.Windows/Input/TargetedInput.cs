using Wbcu.Contract;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Input;

/// <summary>
/// 定向输入：在不移动真实鼠标、不抢前台的前提下，尽量让目标应用「真正响应」。
///
/// 执行阶梯（严格按顺序，不跳级）：
///
///   1. UIA 语义操作（Invoke / Toggle / SelectionItem / Value / Scroll）
///      —— 唯一的「正规通道」。不需要坐标、不需要焦点、不受遮挡影响。
///   2. 窗口消息定向投递（SendMessageTimeout + WM_*）
///      —— 发给**最深层的子窗口**，用客户区坐标。
///      注意：返回成功只代表「消息被目标处理了」，**不代表点击被消费**。
///      WPF / Electron / WinUI / 自绘界面经常忽略普通窗口消息。
///   3. SendInput 全局注入
///      —— 只在 --allow-global 显式授权时走这一步。它会真的动用户的鼠标。
///
/// 这套阶梯的意义不是「总能成功」，而是**失败时能说清楚失败在哪一层**。
/// </summary>
public static class TargetedInput
{
    public const string MethodUiaInvoke = "uia_invoke";
    public const string MethodUiaSetValue = "uia_setvalue";
    public const string MethodWmMessage = "wm_message";
    public const string MethodGlobal = "global_input";

    /// <summary>按屏幕坐标点击（已定位到具体点时使用）。</summary>
    public static ActionOutcome ClickAt(IntPtr windowHwnd, int screenX, int screenY, bool allowGlobal)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var outcome = new ActionOutcome();

        var target = DeepestChildAt(windowHwnd, screenX, screenY);
        if (target == IntPtr.Zero) target = windowHwnd;

        // 显式授权全局输入时，直接用 SendInput，不再先试窗口消息。
        // 原因：PostMessage 只要把消息塞进队列就返回 true，但 Chromium/CEF、WPF、
        // 自绘界面普遍不消费 WM_LBUTTONDOWN（实测企业微信点击后页面毫无反应）。
        // 旧顺序是「posted 就 return」，导致 --allow-global 永远走不到——
        // 参数形同虚设，用户明确授权了却还是点不动。
        if (allowGlobal)
        {
            var ok = GlobalInput.Click(screenX, screenY);
            outcome.Method = MethodGlobal;
            outcome.Delivered = ok;
            outcome.Escalated = true;
            outcome.Ok = ok;
            outcome.FailureReason = ok ? "" : "SendInput 失败";
            outcome.Notes.Add("已按 --allow-global 授权改用全局输入注入（会移动真实鼠标）");
            outcome.Notes.Add($"目标子窗口 {ClassName(target)} 0x{target.ToInt64():X}");
            outcome.DispatchMs = sw.Elapsed.TotalMilliseconds;
            return outcome;
        }

        var posted = PostClick(target, screenX, screenY, out var why);
        outcome.Method = MethodWmMessage;
        outcome.Delivered = posted;
        outcome.Notes.Add($"目标子窗口 {ClassName(target)} 0x{target.ToInt64():X}");

        if (posted)
        {
            outcome.Ok = true;          // 是否有用由上层验证决定
            outcome.DispatchMs = sw.Elapsed.TotalMilliseconds;
            return outcome;
        }

        outcome.Ok = false;
        outcome.FailureReason = why + "；未授权全局输入（加 --allow-global 才会移动真实鼠标）";
        outcome.DispatchMs = sw.Elapsed.TotalMilliseconds;
        return outcome;
    }

    /// <summary>按元素点击：UIA 语义优先，失败才退化为坐标投递。</summary>
    public static ActionOutcome ClickElement(IntPtr windowHwnd, Selector selector, bool allowGlobal)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();

        var (ok, method, fail, _) = Uia.UiaResolver.Act(windowHwnd, selector, "invoke");
        if (ok)
        {
            return new ActionOutcome
            {
                Ok = true,
                Delivered = true,
                Method = method,
                DispatchMs = sw.Elapsed.TotalMilliseconds,
                Notes = { "通过 UIA 语义 Pattern 执行，未使用坐标、未激活窗口" },
            };
        }

        // 语义路径不可用：记下原因，退化为坐标投递
        var snap = Uia.UiaResolver.Walk(windowHwnd, maxDepth: 16, maxNodes: 2000, includePatterns: false);
        var node = Uia.UiaResolver.Locate(snap, selector);
        if (node == null || node.Rect.Length != 4)
        {
            return new ActionOutcome
            {
                Ok = false,
                Delivered = false,
                Method = "none",
                UiaError = fail,
                FailureReason = $"UIA 无法执行（{fail}），且定位不到元素坐标",
                DispatchMs = sw.Elapsed.TotalMilliseconds,
            };
        }

        var cx = (int)Math.Round(node.Rect[0] + node.Rect[2] / 2.0);
        var cy = (int)Math.Round(node.Rect[1] + node.Rect[3] / 2.0);
        if (node.Rect[2] <= 0 || node.Rect[3] <= 0)
        {
            return new ActionOutcome
            {
                Ok = false, Delivered = false, Method = "none", UiaError = fail,
                FailureReason = "元素矩形为空（可能在屏幕外或被虚拟化折叠）",
                DispatchMs = sw.Elapsed.TotalMilliseconds,
            };
        }

        var result = ClickAt(windowHwnd, cx, cy, allowGlobal);
        result.Escalated = true;
        result.UiaError = fail;
        result.Notes.Add($"UIA 语义不可用（{fail}）→ 已降级到坐标投递 ({cx},{cy})");
        result.DispatchMs = sw.Elapsed.TotalMilliseconds;
        return result;
    }

    /// <summary>设置文本：UIA ValuePattern 优先，其次 WM_CHAR，最后（仅在授权时）全局输入。</summary>
    public static ActionOutcome SetText(IntPtr windowHwnd, Selector? selector, string text, bool allowGlobal)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();

        if (selector != null && selector.Kind != SelectorKind.Auto)
        {
            var (ok, method, fail, _) = Uia.UiaResolver.Act(windowHwnd, selector, "setvalue", text);
            if (ok)
            {
                return new ActionOutcome
                {
                    Ok = true, Delivered = true, Method = method,
                    DispatchMs = sw.Elapsed.TotalMilliseconds,
                    Notes = { "通过 UIA ValuePattern 写值（不需要焦点）" },
                };
            }

            var target = TargetHwndFor(windowHwnd, selector);

            // 显式授权时优先用全局 Unicode 注入：CEF/Qt 这类自绘界面既不实现 UIA ValuePattern，
            // 也普遍不消费 WM_CHAR，只有 SendInput 能真正把字打进去。
            // 注意：这要求调用方已经点进目标输入框（焦点），本方法不负责聚焦。
            if (allowGlobal)
            {
                var typed = GlobalInput.TypeText(text);
                return new ActionOutcome
                {
                    Ok = typed,
                    Delivered = typed,
                    Method = MethodGlobal,
                    UiaError = fail,
                    Escalated = true,
                    FailureReason = typed ? "" : "SendInput 文本注入失败",
                    DispatchMs = sw.Elapsed.TotalMilliseconds,
                    Notes =
                    {
                        $"UIA ValuePattern 不可用（{fail}）→ 已按 --allow-global 用 SendInput 注入文本",
                        "前提：目标控件已获得焦点；会占用用户键盘输入流",
                    },
                };
            }

            var posted = PostChars(target, text, out var why);
            return new ActionOutcome
            {
                Ok = posted,
                Delivered = posted,
                Method = MethodWmMessage,
                UiaError = fail,
                FailureReason = posted ? "" : why,
                Escalated = true,
                DispatchMs = sw.Elapsed.TotalMilliseconds,
                Notes =
                {
                    $"UIA value Pattern 不可用（{fail}）→ 改用 WM_CHAR 投递到 0x{target.ToInt64():X}",
                    "WM_CHAR 是否被接收取决于控件实现；结果以验证为准",
                },
            };
        }

        var hwnd = TargetHwndFor(windowHwnd, selector);
        var okChars = PostChars(hwnd, text, out var reason);
        var outcome = new ActionOutcome
        {
            Ok = okChars,
            Delivered = okChars,
            Method = MethodWmMessage,
            FailureReason = okChars ? "" : reason,
            DispatchMs = sw.Elapsed.TotalMilliseconds,
            Notes = { $"WM_CHAR 投递到 0x{hwnd.ToInt64():X}" },
        };

        if (!okChars && allowGlobal)
        {
            foreach (var ch in text)
            {
                GlobalInput.Key((ushort)ch, false);
                GlobalInput.Key((ushort)ch, true);
            }
            outcome.Method = MethodGlobal;
            outcome.Escalated = true;
            outcome.Delivered = true;
            outcome.Ok = true;
            outcome.Notes.Add("退化为全局键盘注入（会进入用户当前焦点窗口）");
        }

        return outcome;
    }

    /// <summary>按键组合，例如 ctrl+a、alt+f4、enter。</summary>
    public static ActionOutcome KeyCombo(IntPtr windowHwnd, string combo, bool allowGlobal)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var parts = combo.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0)
        {
            return ActionOutcome.Fail("按键组合为空");
        }

        var vks = new List<ushort>();
        foreach (var p in parts)
        {
            var vk = VkFor(p);
            if (vk == null)
            {
                return ActionOutcome.Fail($"无法识别的键名：{p}");
            }
            vks.Add(vk.Value);
        }

        var why = "";
        var allDown = true;
        foreach (var vk in vks)
        {
            // 不短路：每个键都要按顺序发下去，任何一个失败都要记下来
            if (!SendKey(windowHwnd, vk, up: false, out why)) allDown = false;
        }
        for (var i = vks.Count - 1; i >= 0; i--)
        {
            SendKey(windowHwnd, vks[i], up: true, out _);
        }
        var sent = allDown;

        var outcome = new ActionOutcome
        {
            Ok = sent,
            Delivered = sent,
            Method = MethodWmMessage,
            FailureReason = sent ? "" : why,
            DispatchMs = sw.Elapsed.TotalMilliseconds,
            Notes = { $"WM_KEYDOWN/UP 投递 {combo} → 0x{windowHwnd.ToInt64():X}" },
        };

        if (!sent && allowGlobal)
        {
            foreach (var vk in vks) GlobalInput.Key(vk, false);
            for (var i = vks.Count - 1; i >= 0; i--) GlobalInput.Key(vks[i], true);
            outcome.Method = MethodGlobal;
            outcome.Escalated = true;
            outcome.Delivered = true;
            outcome.Ok = true;
        }
        return outcome;
    }

    /// <summary>滚动。优先 UIA ScrollPattern，其次 WM_MOUSEWHEEL。</summary>
    public static ActionOutcome Scroll(IntPtr windowHwnd, Selector? selector, int dy, int screenX, int screenY)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();

        if (selector != null && selector.Kind != SelectorKind.Auto)
        {
            var (ok, method, fail, _) = Uia.UiaResolver.Act(windowHwnd, selector, "scroll");
            if (ok)
            {
                return new ActionOutcome
                {
                    Ok = true, Delivered = true, Method = method,
                    DispatchMs = sw.Elapsed.TotalMilliseconds,
                };
            }
        }

        var target = DeepestChildAt(windowHwnd, screenX, screenY);
        if (target == IntPtr.Zero) target = windowHwnd;

        var delta = dy * 120; // WHEEL_DELTA
        var wParam = (IntPtr)((delta & 0xFFFF) << 16);
        var lParam = Native.MakeLParam(screenX, screenY);
        var ok2 = Native.SendMessageTimeoutW(target, Native.WM_MOUSEWHEEL, wParam, lParam,
                                            Native.SMTO_BLOCK | Native.SMTO_ABORTIFHUNG, 200, out _) != IntPtr.Zero;

        return new ActionOutcome
        {
            Ok = ok2,
            Delivered = ok2,
            Method = MethodWmMessage,
            FailureReason = ok2 ? "" : "WM_MOUSEWHEEL 未被处理（该控件可能只响应真实滚轮或 UIA ScrollPattern）",
            DispatchMs = sw.Elapsed.TotalMilliseconds,
            Notes = { $"WM_MOUSEWHEEL Δ{delta} → 0x{target.ToInt64():X}" },
        };
    }

    // ---------------- 内部实现 ----------------

    /// <summary>找到屏幕点下最深一层的子窗口。直接发给顶层窗口通常会被忽略。</summary>
    public static IntPtr DeepestChildAt(IntPtr top, int screenX, int screenY)
    {
        var cur = top;
        for (var i = 0; i < 8; i++)
        {
            var p = new Native.POINT(screenX, screenY);
            if (!Native.ScreenToClient(cur, ref p)) break;
            var child = Native.RealChildWindowFromPoint(cur, p);
            if (child == IntPtr.Zero || child == cur) break;
            cur = child;
        }
        return cur;
    }

    private static bool PostClick(IntPtr hwnd, int screenX, int screenY, out string why)
    {
        why = "";
        var p = new Native.POINT(screenX, screenY);
        if (!Native.ScreenToClient(hwnd, ref p))
        {
            why = "ScreenToClient 失败";
            return false;
        }
        if (!Native.IsWindowVisible(hwnd))
        {
            why = "目标子窗口不可见";
            return false;
        }

        var lp = Native.MakeLParam(p.X, p.Y);

        // 先补一条 move：很多控件依赖 hover 状态才会正确计算命中区域
        Native.SendMessageTimeoutW(hwnd, Native.WM_MOUSEMOVE, IntPtr.Zero, lp,
                                   Native.SMTO_BLOCK | Native.SMTO_ABORTIFHUNG, 150, out _);

        var down = Native.SendMessageTimeoutW(hwnd, Native.WM_LBUTTONDOWN, (IntPtr)Native.MK_LBUTTON, lp,
                                              Native.SMTO_BLOCK | Native.SMTO_ABORTIFHUNG, 200, out _);
        var up = Native.SendMessageTimeoutW(hwnd, Native.WM_LBUTTONUP, IntPtr.Zero, lp,
                                            Native.SMTO_BLOCK | Native.SMTO_ABORTIFHUNG, 200, out _);

        if (down == IntPtr.Zero)
        {
            why = "WM_LBUTTONDOWN 未被目标处理（窗口可能挂起或拒绝该消息）";
            return false;
        }
        if (up == IntPtr.Zero)
        {
            why = "WM_LBUTTONUP 未被目标处理";
            return false;
        }
        return true;
    }

    private static bool PostChars(IntPtr hwnd, string text, out string why)
    {
        why = "";
        if (hwnd == IntPtr.Zero)
        {
            why = "没有可投递的窗口句柄";
            return false;
        }

        var any = false;
        foreach (var ch in text)
        {
            var ok = Native.SendMessageTimeoutW(hwnd, Native.WM_CHAR, (IntPtr)ch, (IntPtr)1,
                                                Native.SMTO_BLOCK | Native.SMTO_ABORTIFHUNG, 150, out _) != IntPtr.Zero;
            any |= ok;
        }

        if (!any)
        {
            why = "WM_CHAR 全部未被处理（该控件可能只接受真实键盘输入或 UIA ValuePattern）";
            return false;
        }
        return true;
    }

    private static bool SendKey(IntPtr hwnd, ushort vk, bool up, out string why)
    {
        why = "";
        var msg = up ? Native.WM_KEYUP : Native.WM_KEYDOWN;
        var lparam = up ? (IntPtr)unchecked((int)0xC0000001) : (IntPtr)1;
        var ok = Native.SendMessageTimeoutW(hwnd, msg, (IntPtr)vk, lparam,
                                            Native.SMTO_BLOCK | Native.SMTO_ABORTIFHUNG, 150, out _) != IntPtr.Zero;
        if (!ok) why = $"WM_KEY{(up ? "UP" : "DOWN")}(vk={vk}) 未被处理";
        return ok;
    }

    /// <summary>找出应该接收键盘/文本消息的窗口：优先元素自带的 HWND，其次目标窗口。</summary>
    private static IntPtr TargetHwndFor(IntPtr windowHwnd, Selector? selector)
    {
        if (selector == null || selector.Kind == SelectorKind.Auto) return windowHwnd;
        try
        {
            var node = Uia.UiaResolver.Locate(windowHwnd, selector);
            if (node != null && node.NativeHwnd != 0) return new IntPtr(node.NativeHwnd);
        }
        catch { }
        return windowHwnd;
    }

    private static string ClassName(IntPtr hwnd) => Native.GetClassName(hwnd);

    /// <summary>键名 → 虚拟键码。只覆盖实际会用到的名字，未知就明确报错。</summary>
    public static ushort? VkFor(string name)
    {
        var n = name.Trim().ToLowerInvariant();
        switch (n)
        {
            case "ctrl": case "control": return 0x11;
            case "shift": return 0x10;
            case "alt": return 0x12;
            case "win": case "meta": case "cmd": return 0x5B;
            case "enter": case "return": return 0x0D;
            case "tab": return 0x09;
            case "esc": case "escape": return 0x1B;
            case "space": return 0x20;
            case "backspace": return 0x08;
            case "delete": case "del": return 0x2E;
            case "insert": return 0x2D;
            case "home": return 0x24;
            case "end": return 0x23;
            case "pageup": return 0x21;
            case "pagedown": return 0x22;
            case "left": return 0x25;
            case "up": return 0x26;
            case "right": return 0x27;
            case "down": return 0x28;
            case "plus": return 0xBB;
            case "minus": return 0xBD;
            case "equal": case "equals": return 0xBB;
            case "decimal": return 0x6E;
            case "multiply": return 0x6A;
            case "divide": return 0x6F;
        }

        if (n.Length == 1)
        {
            var c = char.ToUpperInvariant(n[0]);
            if (c >= 'A' && c <= 'Z') return (ushort)c;
            if (c >= '0' && c <= '9') return (ushort)c;
            switch (c)
            {
                case '=': return 0xBB;
                case '-': return 0xBD;
                case '+': return 0xBB;
                case '.': return 0x6E;
                case '*': return 0x6A;
                case '/': return 0x6F;
            }
        }

        if (n.Length is 2 or 3 && n[0] == 'f' && int.TryParse(n.AsSpan(1), out var fn) && fn is >= 1 and <= 24)
        {
            return (ushort)(0x6F + fn); // VK_F1 = 0x70
        }

        return null;
    }
}
