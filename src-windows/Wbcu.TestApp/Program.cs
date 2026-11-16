using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Wbcu.TestApp;

/// <summary>
/// 受控测试目标（WPF）。刻意**不用 XAML**：
/// 纯代码构建，好处是能在非 Windows 机器上编译（EnableWindowsTargeting），
/// 也避免 XAML 编译任务在 CI 上的额外依赖。
///
/// 与 Win32 版的分工：
///   Win32 版  —— 验证「原生控件 + 窗口消息」路径
///   WPF 版    —— 验证「托管框架 + UIA Provider」路径（WPF 的 UIA 是自绘但语义完整）
/// 两者都有 AutomationId，方便用 `--automationid` 定位而不是靠坐标。
/// </summary>
public static class Program
{
    private static int _buttonClicks;
    private static int _canvasClicks;

    private static TextBlock _result = null!;
    private static ListBox _log = null!;

    [STAThread]
    public static void Main()
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.Run(BuildWindow());
    }

    private static Window BuildWindow()
    {
        var root = new Grid { Margin = new Thickness(16) };
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(320) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var left = new StackPanel();

        var button = new Button
        {
            Content = "点我 (+1)",
            Height = 34,
            Margin = new Thickness(0, 0, 0, 10),
        };
        AutomationProperties.SetAutomationId(button, "incButton");
        AutomationProperties.SetName(button, "点我 (+1)");
        button.Click += (_, _) =>
        {
            _buttonClicks++;
            Refresh();
            Append($"按钮被点击 #{_buttonClicks}（真实 UI 事件）");
        };
        left.Children.Add(button);

        var input = new TextBox { Height = 30, Margin = new Thickness(0, 0, 0, 10) };
        AutomationProperties.SetAutomationId(input, "inputBox");
        AutomationProperties.SetName(input, "输入框");
        input.TextChanged += (_, _) => Append($"输入框长度 → {input.Text.Length}");
        left.Children.Add(input);

        var check = new CheckBox { Content = "启用选项", Margin = new Thickness(0, 0, 0, 10) };
        AutomationProperties.SetAutomationId(check, "optCheck");
        AutomationProperties.SetName(check, "启用选项");
        check.Checked += (_, _) => Append("复选框 → 勾选");
        check.Unchecked += (_, _) => Append("复选框 → 未勾选");
        left.Children.Add(check);

        var combo = new ComboBox { Margin = new Thickness(0, 0, 0, 10) };
        AutomationProperties.SetAutomationId(combo, "comboBox");
        AutomationProperties.SetName(combo, "下拉框");
        combo.Items.Add("选项 A");
        combo.Items.Add("选项 B");
        combo.Items.Add("选项 C");
        combo.SelectedIndex = 0;
        combo.SelectionChanged += (_, _) => Append($"下拉框选择 → {combo.SelectedItem}");
        left.Children.Add(combo);

        _result = new TextBlock { FontSize = 14, Margin = new Thickness(0, 6, 0, 0) };
        AutomationProperties.SetAutomationId(_result, "resultText");
        AutomationProperties.SetName(_result, "结果");
        left.Children.Add(_result);

        root.Children.Add(left);

        // 右侧：滚动区 + 画布
        var right = new Grid();
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(90) });

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Height = 200 };
        AutomationProperties.SetAutomationId(scroll, "scrollViewer");
        var stack = new StackPanel();
        for (var i = 1; i <= 50; i++)
        {
            stack.Children.Add(new TextBlock { Text = $"列表项 {i:00}", Margin = new Thickness(0, 1, 0, 1) });
        }
        scroll.Content = stack;
        Grid.SetRow(scroll, 0);
        right.Children.Add(scroll);

        var canvas = new Canvas
        {
            Background = new SolidColorBrush(Color.FromRgb(240, 232, 224)),
            Margin = new Thickness(0, 8, 0, 0),
        };
        AutomationProperties.SetAutomationId(canvas, "canvas");
        AutomationProperties.SetName(canvas, "画布");
        canvas.MouseLeftButtonDown += (_, e) =>
        {
            _canvasClicks++;
            Refresh();
            Append($"画布点击 #{_canvasClicks} @({e.GetPosition(canvas).X:0},{e.GetPosition(canvas).Y:0})");
        };
        var canvasLabel = new TextBlock { Text = "画布（自绘，无控件语义）", Margin = new Thickness(8, 8, 0, 0) };
        canvas.Children.Add(canvasLabel);
        Grid.SetRow(canvas, 1);
        right.Children.Add(canvas);

        Grid.SetColumn(right, 1);
        root.Children.Add(right);

        // 底部日志
        _log = new ListBox { Height = 120, Margin = new Thickness(0, 12, 0, 0) };
        AutomationProperties.SetAutomationId(_log, "logList");
        Grid.SetRow(_log, 1);
        Grid.SetColumnSpan(_log, 2);
        root.Children.Add(_log);

        var window = new Window
        {
            Title = "wbcu 测试目标 (WPF)",
            Width = 780,
            Height = 620,
            Content = root,
        };
        window.Loaded += (_, _) => Refresh();
        return window;
    }

    private static void Refresh()
    {
        _result.Text = $"结果: 按钮={_buttonClicks} 画布={_canvasClicks}";
        if (Application.Current?.MainWindow != null)
        {
            Application.Current.MainWindow.Title = $"wbcu 测试目标 (WPF) — 按钮={_buttonClicks} 画布={_canvasClicks}";
        }
    }

    private static void Append(string line)
    {
        _log.Items.Add($"{DateTime.Now:HH:mm:ss.fff} {line}");
        if (_log.Items.Count > 200) _log.Items.RemoveAt(0);
        _log.ScrollIntoView(_log.Items[^1]);
    }
}
