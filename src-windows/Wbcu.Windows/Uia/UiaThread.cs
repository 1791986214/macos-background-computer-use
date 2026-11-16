using System.Collections.Concurrent;
using Interop.UIAutomationClient;
using Wbcu.Windows.Cli;

namespace Wbcu.Windows.Uia;

/// <summary>
/// UIA 专用工作线程。
///
/// 为什么必须单独一条 MTA 线程：
///   1) 跨进程 UIA 调用可能阻塞几十毫秒到几秒（目标的 provider 卡住时）。
///      在调用方线程上直接做，会把 CLI 的时序测量和超时逻辑全部污染。
///   2) COM 单元模型要固定。UIA 客户端在 MTA 上工作良好（provider 侧自行封送），
///      而一旦在 STA 上跨线程乱用，就会出现「有时能拿到元素，有时 ElementNotAvailable」。
///   3) 所有 COM 对象只在同一条线程上创建和释放，避免代理跨套间失效。
///
/// 对外只暴露 Run(...)：**绝不**把 IUIAutomationElement 返回给别的线程。
/// 需要读写元素时，把逻辑写成委托，在这条线程里跑完。
/// </summary>
public sealed class UiaThread : IDisposable
{
    private static readonly Lazy<UiaThread> Lazy = new(() => new UiaThread());
    public static UiaThread Instance => Lazy.Value;

    private readonly BlockingCollection<Work> _queue = new();
    private readonly Thread _thread;
    private IUIAutomation? _uia;
    private Exception? _initError;
    private readonly ManualResetEventSlim _ready = new(false);

    private sealed class Work
    {
        public required Func<IUIAutomation, object?> Body;
        public object? Result;
        public Exception? Error;
        public readonly ManualResetEventSlim Done = new(false);
    }

    private UiaThread()
    {
        _thread = new Thread(Loop)
        {
            IsBackground = true,
            Name = "wbcu-uia",
        };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
        _ready.Wait(5000);
    }

    private void Loop()
    {
        try
        {
            _uia = new CUIAutomation8();
        }
        catch (Exception ex)
        {
            _initError = ex;
            _ready.Set();
            return;
        }
        _ready.Set();

        foreach (var w in _queue.GetConsumingEnumerable())
        {
            try
            {
                w.Result = w.Body(_uia!);
            }
            catch (Exception ex)
            {
                w.Error = ex;
            }
            finally
            {
                w.Done.Set();
            }
        }
    }

    public bool Available => _initError == null && _uia != null;
    public string InitError => _initError?.Message ?? "";

    /// <summary>在 UIA 线程上执行。超时抛 CliError(timeout)，绝不挂死调用方。</summary>
    public T Run<T>(Func<IUIAutomation, T> fn, int timeoutMs = 10000)
    {
        if (!Available)
        {
            throw new CliError(Contract.ErrorCodes.UiaUnavailable,
                "UI Automation 初始化失败：" + InitError, ExitCodes.UiaUnavailable);
        }

        var work = new Work { Body = uia => fn(uia) };
        _queue.Add(work);

        if (!work.Done.Wait(timeoutMs))
        {
            // 工作项仍在跑：不 Dispose 它的信号量，交给 GC（让它自然结束）
            throw new CliError(Contract.ErrorCodes.Timeout,
                $"UIA 调用超时（{timeoutMs}ms）：目标进程可能无响应", ExitCodes.TargetNotFound);
        }

        if (work.Error != null)
        {
            throw new CliError(Contract.ErrorCodes.UiaUnavailable,
                "UIA 调用失败：" + work.Error.GetType().Name + " " + work.Error.Message,
                ExitCodes.UiaUnavailable);
        }

        return (T)work.Result!;
    }

    public void Run(Action<IUIAutomation> fn, int timeoutMs = 10000) =>
        Run<object?>(uia => { fn(uia); return null; }, timeoutMs);

    public void Dispose()
    {
        _queue.CompleteAdding();
        _ready.Dispose();
    }
}

/// <summary>
/// UIA 常量。刻意**自己定义字面量**而不是引用互操作程序集里的枚举名：
/// 一是枚举名在不同版本里拼写有差异，二是这些数字是 Windows SDK 的稳定契约，
/// 写死并注明含义比依赖第三方命名更可靠。
/// </summary>
public static class UiaIds
{
    // Property ids
    public const int NameProperty = 30005;
    public const int ControlTypeProperty = 30003;
    public const int AutomationIdProperty = 30011;
    public const int ClassNameProperty = 30012;
    public const int HelpTextProperty = 30013;
    public const int BoundingRectangleProperty = 30001;
    public const int IsEnabledProperty = 30010;
    public const int IsOffscreenProperty = 30022;
    public const int ProcessIdProperty = 30002;
    public const int ValueValueProperty = 30045;
    public const int NativeWindowHandleProperty = 30020;

    // Pattern ids
    public const int InvokePattern = 10000;
    public const int SelectionPattern = 10001;
    public const int ValuePattern = 10002;
    public const int RangeValuePattern = 10003;
    public const int ScrollPattern = 10004;
    public const int ExpandCollapsePattern = 10005;
    public const int GridPattern = 10006;
    public const int GridItemPattern = 10007;
    public const int SelectionItemPattern = 10010;
    public const int TogglePattern = 10015;
    public const int TextPattern = 10014;
    public const int WindowPattern = 10009;
    public const int LegacyIAccessiblePattern = 10018;

    // Control types
    private static readonly Dictionary<int, string> ControlTypes = new()
    {
        [50000] = "Button",
        [50001] = "Calendar",
        [50002] = "CheckBox",
        [50003] = "ComboBox",
        [50004] = "Edit",
        [50005] = "Hyperlink",
        [50006] = "Image",
        [50007] = "ListItem",
        [50008] = "List",
        [50009] = "Menu",
        [50010] = "MenuBar",
        [50011] = "MenuItem",
        [50012] = "ProgressBar",
        [50013] = "RadioButton",
        [50014] = "ScrollBar",
        [50015] = "Slider",
        [50016] = "Spinner",
        [50017] = "StatusBar",
        [50018] = "Tab",
        [50019] = "TabItem",
        [50020] = "Text",
        [50021] = "ToolBar",
        [50022] = "ToolTip",
        [50023] = "Tree",
        [50024] = "TreeItem",
        [50025] = "Custom",
        [50026] = "Group",
        [50027] = "Thumb",
        [50028] = "DataGrid",
        [50029] = "DataItem",
        [50030] = "Document",
        [50031] = "SplitButton",
        [50032] = "Window",
        [50033] = "Pane",
        [50034] = "Header",
        [50035] = "HeaderItem",
        [50036] = "Table",
        [50037] = "TitleBar",
        [50038] = "Separator",
        [50039] = "SemanticZoom",
        [50040] = "AppBar",
    };

    public static string ControlTypeName(int id) =>
        ControlTypes.TryGetValue(id, out var n) ? n : "Control" + id;
}
