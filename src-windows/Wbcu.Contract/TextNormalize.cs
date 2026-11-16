using System.Text;

namespace Wbcu.Contract;

/// <summary>
/// 文本归一化 + 值匹配。
///
/// 这段逻辑与 macOS 引擎 src/InputDispatcher/ExpectedState.swift 的
/// normalize() / matches() 逐条对齐（同一套判据、同一套模式名），
/// 目的是让「同一个期望字符串」在两个平台上得出同一个结论。
///
/// 为什么必须归一化：真实控件读出来的值会带不可见字符。
/// 实测样例（macOS 计算器）：显示 "7,778" 时读到的字节里含 U+200E（LRM），
/// 直接比较会误判成 failure。Windows 的 UIA Name/Value 同样可能带
/// ZWSP / LRM / 不换行空格 / 千分位逗号，所以这里继续沿用同一口径。
///
/// 口径说明（与 Swift 一致）：
///   - 丢弃 Unicode Category = Format / Control（LRM、RLM、ZWSP、BOM、制表符…）
///   - 丢弃 ASCII 逗号与 U+00A0（千分位 / 不换行空格）
///   - 两端 trim
/// 副作用：字符串里的普通逗号也会被吃掉（"a,b" 归一化成 "ab"）。
/// 这是既有行为，为了让两平台一致而保留，不做「聪明」的猜测。
/// </summary>
public static class TextNormalize
{
    public static string Normalize(string? s)
    {
        if (string.IsNullOrEmpty(s)) return string.Empty;

        var sb = new StringBuilder(s!.Length);
        foreach (var rune in s.EnumerateRunes())
        {
            var cat = Rune.GetUnicodeCategory(rune);
            if (cat is System.Globalization.UnicodeCategory.Format
                    or System.Globalization.UnicodeCategory.Control)
            {
                continue;
            }
            if (rune.Value == ',' || rune.Value == 0x00A0) continue;
            sb.Append(rune.ToString());
        }
        return sb.ToString().Trim();
    }

    /// <summary>匹配模式名。与 SKILL.md / macOS 引擎同一套字面量。</summary>
    public static class Modes
    {
        public const string Equals_ = "equals";
        public const string Contains = "contains";
        public const string NotEquals = "not_equals";
        public const string Changed = "changed";
        public const string NotChanged = "not_changed";
        /// <summary>不归一化，仅 trim 后逐字比较。用于「我要的就是原始字节」的场景。</summary>
        public const string Strict = "strict";
    }

    public static bool IsKnownMode(string? mode) => mode is
        Modes.Equals_ or Modes.Contains or Modes.NotEquals or
        Modes.Changed or Modes.NotChanged or Modes.Strict;

    /// <summary>
    /// 值匹配。<paramref name="mode"/> 未知时按 equals 处理（与 Swift 的 default 分支一致）。
    /// changed / not_changed 一律返回 true：这两个模式由调用方比较前后两次读数决定，
    /// 单次匹配没有意义。
    /// </summary>
    public static bool Matches(string? actual, string? expected, string? mode)
    {
        var m = string.IsNullOrEmpty(mode) ? Modes.Equals_ : mode!;

        if (m == Modes.Strict)
        {
            return (actual ?? string.Empty).Trim() == (expected ?? string.Empty).Trim();
        }

        var a = Normalize(actual);
        var e = Normalize(expected);

        return m switch
        {
            Modes.Contains => a.Contains(e, StringComparison.Ordinal),
            Modes.NotEquals => a != e,
            Modes.Changed => true,
            Modes.NotChanged => true,
            _ => a == e,
        };
    }
}
