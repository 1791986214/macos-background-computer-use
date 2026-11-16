using System.Text;
using Interop.UIAutomationClient;
using Wbcu.Contract;
using Wbcu.Windows.Cli;

namespace Wbcu.Windows.Uia;

/// <summary>UIA 树上的一个节点。全部是**托管数据**，跨线程安全（不含任何 COM 引用）。</summary>
public sealed class UiaNode
{
    public int Index { get; init; }
    public int Depth { get; init; }
    public int[] Path { get; init; } = Array.Empty<int>();
    public string Name { get; init; } = "";
    public string AutomationId { get; init; } = "";
    public string ClassName { get; init; } = "";
    public string ControlType { get; init; } = "";
    public string HelpText { get; init; } = "";
    public string Value { get; init; } = "";
    public double[] Rect { get; init; } = Array.Empty<double>();
    public bool Enabled { get; init; }
    public bool Offscreen { get; init; }
    public long NativeHwnd { get; init; }
    public List<string> Patterns { get; init; } = new();

    public ElementFacts Facts() => new(
        Name: Name,
        AutomationId: AutomationId,
        ControlType: ControlType,
        ClassName: ClassName,
        HelpText: HelpText,
        Value: Value,
        Path: Path,
        FlatIndex: Index);

    public Dictionary<string, object?> ToJson() => new()
    {
        ["i"] = Index,
        ["depth"] = Depth,
        ["path"] = Path,
        ["controlType"] = ControlType,
        ["name"] = Name,
        ["automationId"] = AutomationId,
        ["class"] = ClassName,
        ["value"] = Value,
        ["rect"] = Rect,
        ["enabled"] = Enabled,
        ["offscreen"] = Offscreen,
        ["patterns"] = Patterns,
        ["hwnd"] = NativeHwnd == 0 ? null : "0x" + NativeHwnd.ToString("X"),
    };

    public string Describe() =>
        $"{ControlType}" + (Name.Length > 0 ? $" \"{Name}\"" : "")
        + (AutomationId.Length > 0 ? $" #{AutomationId}" : "")
        + (Path.Length > 0 ? $" path[{string.Join(",", Path)}]" : "");
}

public sealed class UiaSnapshot
{
    public List<UiaNode> Nodes { get; } = new();
    public double BuildMs { get; set; }
    public string Fingerprint { get; set; } = "";
    public bool Truncated { get; set; }

    public UiaNode? ByIndex(int i) => i >= 0 && i < Nodes.Count ? Nodes[i] : null;

    public IEnumerable<UiaNode> WithPattern(string pattern) =>
        Nodes.Where(n => n.Patterns.Contains(pattern));
}

/// <summary>
/// UI Automation 解析器。
///
/// 设计要点：
///   - 所有 COM 交互都发生在 UiaThread 上；对外只返回托管快照。
///   - 选择器语义与 macOS 侧同一套（见 contract/selectors.md）。
///   - 语义优先：能拿到 Invoke/Toggle/Value 等 Pattern 时，绝不退化成「按坐标点」。
///     这既是成功率问题，也是「不打扰用户」问题——Pattern 调用不需要前台。
/// </summary>
public static class UiaResolver
{
    /// <summary>遍历整棵树，返回托管快照。includePatterns=true 会为每个节点探测可用 Pattern（更慢）。</summary>
    public static UiaSnapshot Walk(IntPtr hwnd, int maxDepth = 12, int maxNodes = 2000, bool includePatterns = true)
    {
        return UiaThread.Instance.Run(uia =>
        {
            var snap = new UiaSnapshot();
            var t0 = Environment.TickCount64;

            IUIAutomationElement root;
            try
            {
                root = uia.ElementFromHandle(hwnd);
            }
            catch (Exception ex)
            {
                throw new CliError(ErrorCodes.ElementNotFound,
                    "拿不到窗口的 UIA 根元素：" + ex.Message, ExitCodes.TargetNotFound);
            }

            if (root == null)
            {
                throw new CliError(ErrorCodes.ElementNotFound, "窗口没有 UIA 根元素（可能已关闭）", ExitCodes.TargetNotFound);
            }

            var walker = uia.RawViewWalker;
            var path = new List<int>();
            var index = 0;
            var fp = new StringBuilder();

            void Visit(IUIAutomationElement el, int depth)
            {
                if (snap.Nodes.Count >= maxNodes)
                {
                    snap.Truncated = true;
                    return;
                }

                var node = Describe(el, index, depth, path.ToArray(), includePatterns);
                snap.Nodes.Add(node);
                fp.Append(node.ControlType).Append('|').Append(node.Name).Append('|')
                  .Append(node.Value).Append('|').Append(node.Rect.Length == 4 ? string.Join(",", node.Rect) : "")
                  .Append('|').Append(node.Enabled ? '1' : '0').Append(';');
                index++;

                if (depth >= maxDepth) return;

                IUIAutomationElement? child;
                try
                {
                    child = walker.GetFirstChildElement(el);
                }
                catch
                {
                    return;
                }

                var i = 0;
                while (child != null && snap.Nodes.Count < maxNodes)
                {
                    path.Add(i);
                    Visit(child, depth + 1);
                    path.RemoveAt(path.Count - 1);

                    try
                    {
                        child = walker.GetNextSiblingElement(child);
                    }
                    catch
                    {
                        break;
                    }
                    i++;
                }
            }

            Visit(root, 0);

            snap.BuildMs = Environment.TickCount64 - t0;
            snap.Fingerprint = Fnv1a(fp.ToString()).ToString("x16");
            return snap;
        });
    }

    private static UiaNode Describe(IUIAutomationElement el, int index, int depth, int[] path, bool includePatterns)
    {
        string name = "", aid = "", cls = "", help = "", value = "";
        var ct = 0;
        var rect = Array.Empty<double>();
        var enabled = true;
        var offscreen = false;
        long nhwnd = 0;
        var patterns = new List<string>();

        try { name = el.CurrentName ?? ""; } catch { }
        try { aid = el.CurrentAutomationId ?? ""; } catch { }
        try { cls = el.CurrentClassName ?? ""; } catch { }
        try { help = el.CurrentHelpText ?? ""; } catch { }
        try { ct = el.CurrentControlType; } catch { }
        try
        {
            var r = el.CurrentBoundingRectangle;
            rect = new double[] { r.left, r.top, r.right - r.left, r.bottom - r.top };
        }
        catch { }
        try { enabled = el.CurrentIsEnabled != 0; } catch { }
        try { offscreen = el.CurrentIsOffscreen != 0; } catch { }
        try { nhwnd = el.CurrentNativeWindowHandle.ToInt64(); } catch { }

        if (includePatterns)
        {
            patterns = ProbePatterns(el, ref value);
        }

        return new UiaNode
        {
            Index = index,
            Depth = depth,
            Path = path,
            Name = name,
            AutomationId = aid,
            ClassName = cls,
            ControlType = UiaIds.ControlTypeName(ct),
            HelpText = help,
            Value = value,
            Rect = rect,
            Enabled = enabled,
            Offscreen = offscreen,
            NativeHwnd = nhwnd,
            Patterns = patterns,
        };
    }

    private static List<string> ProbePatterns(IUIAutomationElement el, ref string value)
    {
        var list = new List<string>();
        var probes = new (int Id, string Name)[]
        {
            (UiaIds.InvokePattern, "invoke"),
            (UiaIds.ValuePattern, "value"),
            (UiaIds.TogglePattern, "toggle"),
            (UiaIds.SelectionItemPattern, "selectionitem"),
            (UiaIds.ExpandCollapsePattern, "expandcollapse"),
            (UiaIds.ScrollPattern, "scroll"),
            (UiaIds.TextPattern, "text"),
            (UiaIds.WindowPattern, "window"),
            (UiaIds.RangeValuePattern, "rangevalue"),
        };

        foreach (var (id, name) in probes)
        {
            object? pat = null;
            try { pat = el.GetCurrentPattern(id); } catch { }
            if (pat == null) continue;
            list.Add(name);
            if (name == "value" && pat is IUIAutomationValuePattern vp)
            {
                try { value = vp.CurrentValue ?? ""; } catch { }
            }
            else if (name == "text" && value.Length == 0 && pat is IUIAutomationTextPattern tp)
            {
                try { value = tp.DocumentRange.GetText(1024) ?? ""; } catch { }
            }
        }
        return list;
    }

    /// <summary>
    /// 在 UIA 线程里定位元素并执行动作。返回 succeeded/failure 由调用方结合验证判定。
    /// 失败时给出具体原因（找不到 / 没有该 Pattern / provider 抛异常），不假装成功。
    /// </summary>
    public static (bool Ok, string Method, string Failure, double Ms) Act(
        IntPtr hwnd, Selector selector, string verb, string? text = null)
    {
        return UiaThread.Instance.Run(uia =>
        {
            var t0 = Environment.TickCount64;
            IUIAutomationElement root;
            try
            {
                root = uia.ElementFromHandle(hwnd);
            }
            catch (Exception ex)
            {
                return (false, "none", "拿不到 UIA 根元素：" + ex.Message, (double)(Environment.TickCount64 - t0));
            }

            var el = FindElement(uia, root, selector, out var fail);
            if (el == null)
            {
                return (false, "none", fail, (double)(Environment.TickCount64 - t0));
            }

            try
            {
                switch (verb)
                {
                    case "invoke":
                        if (TryPattern(uia, el, UiaIds.InvokePattern, out var ip))
                        {
                            ((IUIAutomationInvokePattern)ip!).Invoke();
                            return (true, "uia_invoke", "", (double)(Environment.TickCount64 - t0));
                        }
                        if (TryPattern(uia, el, UiaIds.SelectionItemPattern, out var sp))
                        {
                            ((IUIAutomationSelectionItemPattern)sp!).Select();
                            return (true, "uia_select", "", (double)(Environment.TickCount64 - t0));
                        }
                        if (TryPattern(uia, el, UiaIds.TogglePattern, out var tp))
                        {
                            ((IUIAutomationTogglePattern)tp!).Toggle();
                            return (true, "uia_toggle", "", (double)(Environment.TickCount64 - t0));
                        }
                        return (false, "none", "元素不提供 invoke/toggle/selectionitem 任一 Pattern（自绘或无 Pattern 控件）",
                                (double)(Environment.TickCount64 - t0));

                    case "toggle":
                        if (TryPattern(uia, el, UiaIds.TogglePattern, out var t2))
                        {
                            ((IUIAutomationTogglePattern)t2!).Toggle();
                            return (true, "uia_toggle", "", (double)(Environment.TickCount64 - t0));
                        }
                        return (false, "none", "元素不提供 toggle Pattern", (double)(Environment.TickCount64 - t0));

                    case "expand":
                        if (TryPattern(uia, el, UiaIds.ExpandCollapsePattern, out var e2))
                        {
                            var ec = (IUIAutomationExpandCollapsePattern)e2!;
                            if (ec.CurrentExpandCollapseState == ExpandCollapseState.ExpandCollapseState_Collapsed
                                || ec.CurrentExpandCollapseState == ExpandCollapseState.ExpandCollapseState_PartiallyExpanded)
                            {
                                ec.Expand();
                            }
                            return (true, "uia_expandcollapse", "", (double)(Environment.TickCount64 - t0));
                        }
                        return (false, "none", "元素不提供 expandcollapse Pattern", (double)(Environment.TickCount64 - t0));

                    case "setvalue":
                        if (text == null) return (false, "none", "setvalue 缺少文本", 0.0);
                        if (TryPattern(uia, el, UiaIds.ValuePattern, out var v2))
                        {
                            ((IUIAutomationValuePattern)v2!).SetValue(text);
                            return (true, "uia_setvalue", "", (double)(Environment.TickCount64 - t0));
                        }
                        return (false, "none", "元素不提供 value Pattern（不可通过 UIA 写值）",
                                (double)(Environment.TickCount64 - t0));

                    case "scroll":
                        if (TryPattern(uia, el, UiaIds.ScrollPattern, out var s2))
                        {
                            var sc = (IUIAutomationScrollPattern)s2!;
                            sc.Scroll(ScrollAmount.ScrollAmount_LargeDecrement, ScrollAmount.ScrollAmount_NoAmount);
                            return (true, "uia_scroll", "", (double)(Environment.TickCount64 - t0));
                        }
                        return (false, "none", "元素不提供 scroll Pattern", (double)(Environment.TickCount64 - t0));

                    case "focus":
                        el.SetFocus();
                        return (true, "uia_focus", "", (double)(Environment.TickCount64 - t0));

                    default:
                        return (false, "none", "未知动作 " + verb, (double)(Environment.TickCount64 - t0));
                }
            }
            catch (Exception ex)
            {
                return (false, "none", "UIA 动作抛异常：" + ex.GetType().Name + " " + ex.Message,
                        (double)(Environment.TickCount64 - t0));
            }
        });
    }

    /// <summary>
    /// 在托管快照里按选择器定位节点（不碰 COM，可在任意线程用）。
    /// 用于「先算坐标再投递消息」这条降级路径，以及经验库的复验。
    /// </summary>
    public static UiaNode? Locate(UiaSnapshot snap, Selector sel)
    {
        switch (sel.Kind)
        {
            case SelectorKind.Path:
                return snap.Nodes.FirstOrDefault(n => n.Path.SequenceEqual(sel.PathParts));

            case SelectorKind.Index:
                return snap.ByIndex(sel.Nth);

            case SelectorKind.Auto:
                return snap.Nodes.FirstOrDefault(n =>
                           n.ControlType == "Edit" && n.Value.Length > 0)
                       ?? snap.Nodes.FirstOrDefault(n =>
                           n.ControlType == "Edit" && n.Name.Length > 0)
                       ?? snap.Nodes.FirstOrDefault(n =>
                           n.ControlType == "Text" && n.Name.Length > 0);

            default:
            {
                var hits = snap.Nodes.Where(n => sel.Matches(n.Facts())).ToList();
                if (hits.Count == 0) return null;
                return hits[Math.Min(sel.Nth, hits.Count - 1)];
            }
        }
    }

    /// <summary>便捷：直接对窗口做一次快照并按选择器定位。</summary>
    public static UiaNode? Locate(IntPtr hwnd, Selector sel, UiaSnapshot? snapshot = null)
    {
        var snap = snapshot ?? Walk(hwnd, maxDepth: 16, maxNodes: 2000, includePatterns: true);
        return Locate(snap, sel);
    }

    private static bool TryPattern(IUIAutomation uia, IUIAutomationElement el, int patternId, out object? pattern)
    {
        pattern = null;
        try
        {
            pattern = el.GetCurrentPattern(patternId);
            return pattern != null;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>读取某元素的当前值（用于验证）。selector 为 Auto 时按「默认状态元素」启发式选取。</summary>
    public static ElementReadout Read(IntPtr hwnd, Selector selector)
    {
        return UiaThread.Instance.Run(uia =>
        {
            var t0 = Environment.TickCount64;
            var readout = new ElementReadout();

            IUIAutomationElement root;
            try
            {
                root = uia.ElementFromHandle(hwnd);
            }
            catch
            {
                return readout;
            }

            var el = FindElement(uia, root, selector, out _);
            if (el == null) return readout;

            readout.Found = true;
            try { readout.Role = UiaIds.ControlTypeName(el.CurrentControlType); } catch { }
            try { readout.Identifier = el.CurrentAutomationId ?? ""; } catch { }
            try { readout.Title = el.CurrentName ?? ""; } catch { }

            var value = "";
            if (TryPattern(uia, el, UiaIds.ValuePattern, out var vp) && vp is IUIAutomationValuePattern v)
            {
                try { value = v.CurrentValue ?? ""; } catch { }
            }
            if (value.Length == 0 && TryPattern(uia, el, UiaIds.TextPattern, out var tp) && tp is IUIAutomationTextPattern t)
            {
                try { value = t.DocumentRange.GetText(1024) ?? ""; } catch { }
            }
            readout.Value = value;
            readout.ElapsedMs = Environment.TickCount64 - t0;
            return readout;
        });
    }

    /// <summary>在整棵窗口树里按值搜索（用于「结果显示在另一个元素里」的兜底，与 macOS 的 searchValue 同义）。</summary>
    public static ElementReadout SearchValue(IntPtr hwnd, string expected, int[]? excludePath = null)
    {
        var snap = Walk(hwnd, maxDepth: 16, maxNodes: 2000, includePatterns: true);
        foreach (var n in snap.Nodes)
        {
            if (excludePath != null && n.Path.SequenceEqual(excludePath)) continue;
            var candidate = n.Value.Length > 0 ? n.Value : n.Name;
            if (candidate.Length == 0) continue;
            if (TextNormalize.Matches(candidate, expected, TextNormalize.Modes.Equals_))
            {
                return new ElementReadout
                {
                    Found = true,
                    Role = n.ControlType,
                    Identifier = n.AutomationId,
                    Title = n.Name,
                    Value = candidate,
                    Path = n.Path,
                    ElapsedMs = (long)snap.BuildMs,
                };
            }
        }
        return new ElementReadout();
    }

    /// <summary>
    /// 选择器 → COM 元素。三种实现路径：
    ///   1) 条件查找（AutomationId / Name / ControlType / Class / HelpText）—— provider 侧优化过，最快
    ///   2) 树路径（path:0,1,2）
    ///   3) 扁平遍历（index / value / auto）
    /// </summary>
    private static IUIAutomationElement? FindElement(IUIAutomation uia, IUIAutomationElement root,
                                                    Selector sel, out string failure)
    {
        failure = "";
        try
        {
            switch (sel.Kind)
            {
                case SelectorKind.AutomationId:
                    return Nth(uia, root, UiaIds.AutomationIdProperty, sel.Value, sel.Nth);

                case SelectorKind.Name:
                    return Nth(uia, root, UiaIds.NameProperty, sel.Value, sel.Nth);

                case SelectorKind.ClassName:
                    return Nth(uia, root, UiaIds.ClassNameProperty, sel.Value, sel.Nth);

                case SelectorKind.ControlType:
                {
                    var id = ReverseControlType(sel.Value);
                    if (id > 0) return Nth(uia, root, UiaIds.ControlTypeProperty, id, sel.Nth);
                    // 未知类型名：退化为遍历匹配
                    return FlatFind(uia, root, sel);
                }

                case SelectorKind.Path:
                    return ByPath(uia, root, sel.PathParts);

                case SelectorKind.Index:
                case SelectorKind.Value:
                case SelectorKind.HelpText:
                case SelectorKind.Auto:
                default:
                    return FlatFind(uia, root, sel);
            }
        }
        catch (Exception ex)
        {
            failure = "选择器查找失败：" + ex.Message;
            return null;
        }
    }

    private static IUIAutomationElement? Nth(IUIAutomation uia, IUIAutomationElement root,
                                             int propertyId, object value, int nth)
    {
        var cond = uia.CreatePropertyCondition(propertyId, value);
        var arr = root.FindAll(TreeScope.TreeScope_Descendants, cond);
        if (arr == null || arr.Length == 0) return null;
        if (nth >= arr.Length) return null;
        return arr.GetElement(nth);
    }

    private static IUIAutomationElement? ByPath(IUIAutomation uia, IUIAutomationElement root, int[] path)
    {
        var walker = uia.RawViewWalker;
        var cur = root;
        foreach (var idx in path)
        {
            var child = walker.GetFirstChildElement(cur);
            var i = 0;
            while (child != null && i < idx)
            {
                child = walker.GetNextSiblingElement(child);
                i++;
            }
            if (child == null) return null;
            cur = child;
        }
        return cur;
    }

    private static IUIAutomationElement? FlatFind(IUIAutomation uia, IUIAutomationElement root, Selector sel)
    {
        var walker = uia.RawViewWalker;
        var stack = new Stack<(IUIAutomationElement El, int[] Path, int Depth)>();
        stack.Push((root, Array.Empty<int>(), 0));
        var flat = 0;

        while (stack.Count > 0)
        {
            var (el, path, depth) = stack.Pop();

            var facts = FactsOf(el, path, flat);
            if (sel.Kind == SelectorKind.Index)
            {
                if (flat == sel.Nth) return el;
            }
            else if (sel.Kind == SelectorKind.Auto)
            {
                if (IsDefaultStateElement(el)) return el;
            }
            else if (sel.Matches(facts))
            {
                return el;
            }

            flat++;
            if (depth >= 16) continue;

            // 收集子节点（倒序压栈以保持文档顺序）
            var children = new List<IUIAutomationElement>();
            IUIAutomationElement? child;
            try { child = walker.GetFirstChildElement(el); }
            catch { child = null; }
            while (child != null)
            {
                children.Add(child);
                try { child = walker.GetNextSiblingElement(child); }
                catch { break; }
            }
            for (var i = children.Count - 1; i >= 0; i--)
            {
                var p = new int[path.Length + 1];
                Array.Copy(path, p, path.Length);
                p[path.Length] = i;
                stack.Push((children[i], p, depth + 1));
            }
        }
        return null;
    }

    private static ElementFacts FactsOf(IUIAutomationElement el, int[] path, int flat)
    {
        var name = ""; var aid = ""; var cls = ""; var help = ""; var value = ""; var ct = 0;
        try { name = el.CurrentName ?? ""; } catch { }
        try { aid = el.CurrentAutomationId ?? ""; } catch { }
        try { cls = el.CurrentClassName ?? ""; } catch { }
        try { help = el.CurrentHelpText ?? ""; } catch { }
        try { ct = el.CurrentControlType; } catch { }
        try
        {
            var p = el.GetCurrentPattern(UiaIds.ValuePattern);
            if (p is IUIAutomationValuePattern v) value = v.CurrentValue ?? "";
        }
        catch { }

        return new ElementFacts(name, aid, UiaIds.ControlTypeName(ct), cls, help, value, path, flat);
    }

    /// <summary>
    /// 「默认状态元素」启发式：与 macOS 的默认 AXStaticText 策略等价——
    /// 优先有值的 Edit（输入框/结果框），其次有名字的 Text（静态文本/结果行）。
    /// </summary>
    private static bool IsDefaultStateElement(IUIAutomationElement el)
    {
        try
        {
            var ct = el.CurrentControlType;
            if (ct == 50004) // Edit
            {
                var p = el.GetCurrentPattern(UiaIds.ValuePattern);
                if (p is IUIAutomationValuePattern v && !string.IsNullOrEmpty(v.CurrentValue)) return true;
                return !string.IsNullOrEmpty(el.CurrentName);
            }
            if (ct == 50020) // Text
            {
                return !string.IsNullOrEmpty(el.CurrentName);
            }
        }
        catch { }
        return false;
    }

    private static int ReverseControlType(string name)
    {
        for (var id = 50000; id <= 50040; id++)
        {
            if (string.Equals(UiaIds.ControlTypeName(id), name, StringComparison.OrdinalIgnoreCase)) return id;
        }
        return 0;
    }

    private static ulong Fnv1a(string s)
    {
        var h = 14695981039346656037UL;
        foreach (var c in s)
        {
            h ^= c;
            h *= 1099511628211UL;
        }
        return h;
    }
}
