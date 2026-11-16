namespace Wbcu.Contract;

/// <summary>选择器类型。语法在 contract/selectors.md 里定义，两个平台共用。</summary>
public enum SelectorKind
{
    /// <summary>未指定：由引擎用「默认状态元素」策略（窗口内第一个可读的文本/值元素）。</summary>
    Auto,
    AutomationId,
    Name,
    ControlType,
    ClassName,
    HelpText,
    Value,
    /// <summary>从窗口根节点出发的树索引路径，例如 0,1,3。</summary>
    Path,
    /// <summary>扁平化树序遍历后的第 N 个节点（0 基）。</summary>
    Index,
}

/// <summary>
/// 元素选择器。
///
/// 设计取舍：**长期记忆只许存 AutomationId / 名称 / 控件类型这类语义标识**，
/// 坐标和 RuntimeId 只做「运行时定位」和「短期复验」，不写进经验库。
/// 原因见 docs/experience-memory.md：HWND 与 RuntimeId 跨进程重启后不保证稳定。
/// </summary>
public sealed class Selector
{
    public SelectorKind Kind { get; init; } = SelectorKind.Auto;

    /// <summary>主值。Path 类型时是原始 "0,1,3" 文本，同时提供 <see cref="PathParts"/>。</summary>
    public string Value { get; init; } = "";

    /// <summary>同名多元素时的第 N 个（0 基）。0 表示第一个。</summary>
    public int Nth { get; init; }

    /// <summary>Name 选择器的「包含」模式（语法前缀 ~）。</summary>
    public bool Contains { get; init; }

    public int[] PathParts { get; init; } = Array.Empty<int>();

    public string Raw { get; init; } = "";

    public static readonly Selector None = new();

    /// <summary>
    /// 解析语法（大小写不敏感的键名）：
    ///   automationid:Foo | id:Foo
    ///   name:Save    | name:~Save   （~ = 包含匹配）
    ///   controltype:Button | role:AXButton | type:Button
    ///   class:NotepadEdit | classname:...
    ///   helptext:...
    ///   value:15
    ///   path:0,1,3
    ///   index:7 | idx:7
    /// 末尾可带 [n] 指定同名第 n 个：name:OK[1]
    /// 无法识别时退化为 Auto，并把原始串记在 Raw 里（不抛异常，让调用方报错更清楚）。
    /// </summary>
    public static Selector Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return None;
        var raw = text!.Trim();

        var nth = 0;
        var body = raw;
        var open = body.LastIndexOf('[');
        if (open > 0 && body.EndsWith(']'))
        {
            var inner = body.Substring(open + 1, body.Length - open - 2);
            if (int.TryParse(inner, out var n) && n >= 0)
            {
                nth = n;
                body = body.Substring(0, open);
            }
        }

        var idx = body.IndexOf(':');
        if (idx <= 0)
        {
            // 裸字符串：当成 Name 精确匹配（最符合人的直觉：「点『保存』」）
            return new Selector { Kind = SelectorKind.Name, Value = body, Nth = nth, Raw = raw };
        }

        var key = body.Substring(0, idx).Trim().ToLowerInvariant();
        var val = body.Substring(idx + 1).Trim();

        switch (key)
        {
            case "automationid":
            case "automation":
            case "id":
                return new Selector { Kind = SelectorKind.AutomationId, Value = val, Nth = nth, Raw = raw };

            case "name":
            case "text":
            case "title":
                var contains = val.StartsWith('~');
                return new Selector
                {
                    Kind = SelectorKind.Name,
                    Value = contains ? val.Substring(1) : val,
                    Nth = nth,
                    Contains = contains,
                    Raw = raw,
                };

            case "controltype":
            case "role":
            case "type":
                // 兼容 macOS 的 AX 前缀写法：role:AXButton → Button
                var ct = val.StartsWith("AX", StringComparison.OrdinalIgnoreCase) && val.Length > 2
                    ? val.Substring(2)
                    : val;
                return new Selector { Kind = SelectorKind.ControlType, Value = ct, Nth = nth, Raw = raw };

            case "class":
            case "classname":
                return new Selector { Kind = SelectorKind.ClassName, Value = val, Nth = nth, Raw = raw };

            case "helptext":
                return new Selector { Kind = SelectorKind.HelpText, Value = val, Nth = nth, Raw = raw };

            case "value":
                return new Selector { Kind = SelectorKind.Value, Value = val, Nth = nth, Raw = raw };

            case "path":
                var parts = val.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                               .Select(p => int.TryParse(p, out var v) ? v : -1)
                               .ToArray();
                return new Selector { Kind = SelectorKind.Path, Value = val, Nth = nth, PathParts = parts, Raw = raw };

            case "index":
            case "idx":
                var flat = int.TryParse(val, out var fi) ? fi : -1;
                return new Selector
                {
                    Kind = SelectorKind.Index,
                    Value = val,
                    Nth = flat,
                    PathParts = flat >= 0 ? new[] { flat } : Array.Empty<int>(),
                    Raw = raw,
                };

            default:
                return new Selector { Kind = SelectorKind.Auto, Value = raw, Raw = raw };
        }
    }

    /// <summary>
    /// 与元素事实匹配（纯逻辑，不含任何 API 调用）。Nth 由调用方在收集候选时处理。
    /// </summary>
    public bool Matches(ElementFacts facts)
    {
        switch (Kind)
        {
            case SelectorKind.AutomationId:
                return string.Equals(facts.AutomationId, Value, StringComparison.OrdinalIgnoreCase);

            case SelectorKind.Name:
                return Contains
                    ? TextNormalize.Normalize(facts.Name).Contains(TextNormalize.Normalize(Value), StringComparison.Ordinal)
                    : TextNormalize.Matches(facts.Name, Value, TextNormalize.Modes.Equals_);

            case SelectorKind.ControlType:
                return string.Equals(facts.ControlType, Value, StringComparison.OrdinalIgnoreCase);

            case SelectorKind.ClassName:
                return string.Equals(facts.ClassName, Value, StringComparison.OrdinalIgnoreCase);

            case SelectorKind.HelpText:
                return TextNormalize.Matches(facts.HelpText, Value, TextNormalize.Modes.Contains);

            case SelectorKind.Value:
                return TextNormalize.Matches(facts.Value, Value, TextNormalize.Modes.Equals_);

            case SelectorKind.Path:
                return facts.PathOrEmpty.SequenceEqual(PathParts);

            case SelectorKind.Index:
                return facts.FlatIndex == Nth;

            default:
                return false;
        }
    }

    public string Describe() => Kind switch
    {
        SelectorKind.Auto => "(auto)",
        SelectorKind.Path => $"path:[{string.Join(",", PathParts)}]",
        SelectorKind.Index => $"index:{Nth}",
        _ => $"{Kind.ToString().ToLowerInvariant()}:{Value}" + (Nth > 0 ? $"[{Nth}]" : ""),
    };
}

/// <summary>元素的可比较事实集合。Windows 侧从 UIA 填充，macOS 侧从 AX 填充。</summary>
public sealed record ElementFacts(
    string Name = "",
    string AutomationId = "",
    string ControlType = "",
    string ClassName = "",
    string HelpText = "",
    string Value = "",
    int[]? Path = null,
    int FlatIndex = -1)
{
    public int[] PathOrEmpty => Path ?? Array.Empty<int>();
}
