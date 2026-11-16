using Wbcu.Contract;
using Xunit;

namespace Wbcu.Tests;

public class TextNormalizeTests
{
    [Theory]
    [InlineData("\u200E7,778", "7778")]
    [InlineData("\u200Babc\u200F", "abc")]
    [InlineData("1\u00A0234,5", "12345")]
    [InlineData("  15  ", "15")]
    [InlineData(null, "")]
    public void Normalize_strips_invisible_and_separators(string? input, string expected)
    {
        Assert.Equal(expected, TextNormalize.Normalize(input));
    }

    [Fact]
    public void Comma_is_dropped_even_when_semantically_meaningful()
    {
        // 这是刻意的既有行为（与 macOS 一致）：宁可把 "a,b" 归一成 "ab"，
        // 也不要让千分位造成误判。文档里写清楚，不做聪明猜测。
        Assert.Equal("ab", TextNormalize.Normalize("a,b"));
    }

    [Theory]
    [InlineData("15", "15", "equals", true)]
    [InlineData("15.0", "15", "equals", false)]
    [InlineData("结果 15", "15", "contains", true)]
    [InlineData("15", "16", "not_equals", true)]
    [InlineData("15", "15", "not_equals", false)]
    [InlineData("15", "15", "changed", true)]
    [InlineData("abc", "ABC", "equals", false)]
    [InlineData(" abc ", "abc", "strict", true)]
    public void Matches_follows_documented_modes(string actual, string expected, string mode, bool want)
    {
        Assert.Equal(want, TextNormalize.Matches(actual, expected, mode));
    }

    [Fact]
    public void Unknown_mode_falls_back_to_equals()
    {
        Assert.True(TextNormalize.Matches("15", "15", "whatever"));
        Assert.False(TextNormalize.Matches("15", "16", "whatever"));
    }
}

public class SelectorTests
{
    [Fact]
    public void Parses_documented_syntaxes()
    {
        Assert.Equal(SelectorKind.AutomationId, Selector.Parse("automationid:num7Button").Kind);
        Assert.Equal("num7Button", Selector.Parse("id:num7Button").Value);

        var name = Selector.Parse("name:保存");
        Assert.Equal(SelectorKind.Name, name.Kind);
        Assert.False(name.Contains);

        var contains = Selector.Parse("name:~保存");
        Assert.True(contains.Contains);
        Assert.Equal("保存", contains.Value);

        Assert.Equal(SelectorKind.ControlType, Selector.Parse("controltype:Button").Kind);
        // 兼容 macOS 的 AX 前缀
        Assert.Equal("Button", Selector.Parse("role:AXButton").Value);

        Assert.Equal(SelectorKind.ClassName, Selector.Parse("class:NotepadEdit").Kind);
        Assert.Equal(SelectorKind.HelpText, Selector.Parse("helptext:保存").Kind);
        Assert.Equal(SelectorKind.Value, Selector.Parse("value:15").Kind);
    }

    [Fact]
    public void Parses_path_and_index()
    {
        var p = Selector.Parse("path:0,1,7");
        Assert.Equal(SelectorKind.Path, p.Kind);
        Assert.Equal(new[] { 0, 1, 7 }, p.PathParts);

        var i = Selector.Parse("index:9");
        Assert.Equal(SelectorKind.Index, i.Kind);
        Assert.Equal(9, i.Nth);
    }

    [Fact]
    public void Parses_nth_suffix()
    {
        // 实测踩坑：计算器结果会出现在第二个 AXStaticText 上，需要 [1]
        var s = Selector.Parse("controltype:StaticText[1]");
        Assert.Equal(SelectorKind.ControlType, s.Kind);
        Assert.Equal(1, s.Nth);
        Assert.Equal("StaticText", s.Value);
    }

    [Fact]
    public void Bare_string_becomes_name_selector()
    {
        var s = Selector.Parse("保存");
        Assert.Equal(SelectorKind.Name, s.Kind);
        Assert.Equal("保存", s.Value);
    }

    [Fact]
    public void Empty_becomes_auto()
    {
        Assert.Equal(SelectorKind.Auto, Selector.Parse("").Kind);
        Assert.Equal(SelectorKind.Auto, Selector.Parse(null).Kind);
        Assert.Equal(SelectorKind.Auto, Selector.Parse("   ").Kind);
    }

    [Fact]
    public void Matches_uses_normalized_comparison()
    {
        var s = Selector.Parse("name:7");
        Assert.True(s.Matches(new ElementFacts(Name: "\u200E7")));
        Assert.False(s.Matches(new ElementFacts(Name: "77")));
    }

    [Fact]
    public void AutomationId_match_is_case_insensitive()
    {
        var s = Selector.Parse("automationid:Num7Button");
        Assert.True(s.Matches(new ElementFacts(AutomationId: "num7button")));
    }

    [Fact]
    public void Path_match_requires_exact_sequence()
    {
        var s = Selector.Parse("path:0,1");
        Assert.True(s.Matches(new ElementFacts(Path: new[] { 0, 1 })));
        Assert.False(s.Matches(new ElementFacts(Path: new[] { 0, 1, 2 })));
    }
}

public class GeometryTests
{
    [Fact]
    public void Local_and_global_are_inverse()
    {
        var frame = new WbRect(100, 50, 800, 600);
        var g = new WbPoint(300, 200);
        var l = Geometry.WindowLocal(g, frame);
        Assert.Equal(new WbPoint(200, 150), l);
        Assert.Equal(g, Geometry.WindowGlobal(l, frame));
    }

    [Fact]
    public void Dpi_scale_maps_96_to_one()
    {
        Assert.Equal(1.0, Geometry.ScaleFromDpi(96));
        Assert.Equal(1.5, Geometry.ScaleFromDpi(144));
        Assert.Equal(2.0, Geometry.ScaleFromDpi(192));
        Assert.Equal(1.0, Geometry.ScaleFromDpi(0));
    }

    [Fact]
    public void Physical_and_dip_are_inverse()
    {
        var dip = new WbPoint(100, 200);
        var px = Geometry.ToPhysical(dip, 1.5);
        Assert.Equal(new WbPoint(150, 300), px);
        Assert.Equal(dip, Geometry.ToDip(px, 1.5));
    }

    [Fact]
    public void Fully_covered_rect_has_zero_visible_ratio()
    {
        var target = new WbRect(10, 10, 100, 100);
        var ratio = Geometry.VisibleRatio(target, new[] { new WbRect(0, 0, 500, 500) });
        Assert.Equal(0, ratio);
    }

    [Fact]
    public void Non_overlapping_rect_is_fully_visible()
    {
        var target = new WbRect(10, 10, 100, 100);
        Assert.Equal(1.0, Geometry.VisibleRatio(target, new[] { new WbRect(500, 500, 10, 10) }));
    }
}
