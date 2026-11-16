using Wbcu.Contract;
using Wbcu.Windows.Discovery;

namespace Wbcu.Windows.Experience;

/// <summary>
/// 应用经验库。
///
/// 与 macOS 共用同一份格式与 key 规则（AppExperience），区别只在换行/路径。
/// 纪律（写在代码里，防止以后有人图省事）：
///   - **只存语义稳定的定位依据**：AutomationId → 相对路径 → 名称。
///   - HWND / RuntimeId / 绝对坐标 一律不进长期库（只可能作为 lastSeenRect 调试字段）。
///   - 复用前必须复验：名称/类型对不上就当没命中，退回实时查找。
/// </summary>
public static class ExperienceStore
{
    public static AppExperience LoadOrCreate(WindowInfo window)
    {
        var key = AppExperience.KeyOf(window.Exe, window.PackageFamily, window.Class);
        var path = FilePath(key);
        AppExperience? exp = null;
        if (File.Exists(path))
        {
            try { exp = Json.Deserialize<AppExperience>(File.ReadAllText(path)); } catch { }
        }

        exp ??= new AppExperience
        {
            Platform = Platforms.Windows,
            Executable = window.Exe,
            AppName = window.ProcessName,
            PackageFamily = window.PackageFamily,
            WindowClass = window.Class,
        };

        // 应用升级后经验可能失效，但不要删——只记录版本变化，由命中失败自然淘汰
        exp.AppVersion = VersionOf(window.Exe);
        return exp;
    }

    public static void Save(WindowInfo window, AppExperience exp)
    {
        exp.UpdatedAt = DateTime.UtcNow.ToString("O");
        var key = AppExperience.KeyOf(window.Exe, window.PackageFamily, window.Class);
        File.WriteAllText(FilePath(key), Json.Serialize(exp, pretty: true));
    }

    public static List<AppExperience> List()
    {
        var list = new List<AppExperience>();
        foreach (var f in Directory.EnumerateFiles(Paths.Experience, "*.json"))
        {
            try
            {
                var e = Json.Deserialize<AppExperience>(File.ReadAllText(f));
                if (e != null) list.Add(e);
            }
            catch { }
        }
        return list.OrderByDescending(e => e.UpdatedAt).ToList();
    }

    public static int Clear(string? appToken)
    {
        var files = Directory.EnumerateFiles(Paths.Experience, "*.json").ToList();
        var n = 0;
        foreach (var f in files)
        {
            if (!string.IsNullOrEmpty(appToken))
            {
                var text = File.ReadAllText(f);
                if (!text.ToLowerInvariant().Contains(appToken!.ToLowerInvariant())) continue;
            }
            try { File.Delete(f); n++; } catch { }
        }
        return n;
    }

    /// <summary>记录一次成功的元素操作路径。失败也记（用于降低下次优先级）。</summary>
    public static void RecordSuccess(AppExperience exp, WindowInfo window, string workflow,
                                     Uia.UiaNode node, string method, double endToEndMs)
    {
        var wf = exp.FindWorkflow(workflow) ?? new WorkflowMemory { Name = workflow };
        if (!exp.Workflows.Contains(wf)) exp.Workflows.Add(wf);

        var mem = wf.Elements.FirstOrDefault(e =>
            (node.AutomationId.Length > 0 && e.AutomationId == node.AutomationId) ||
            (node.AutomationId.Length == 0 && e.Name == node.Name && e.ControlType == node.ControlType));

        if (mem == null)
        {
            mem = new ElementMemory
            {
                Name = node.Name,
                AutomationId = node.AutomationId,
                ControlType = node.ControlType,
                Path = node.Path,
                Role = node.ControlType,
            };
            wf.Elements.Add(mem);
        }

        mem.OkCount++;
        mem.LastSeenAt = DateTime.UtcNow.ToString("O");
        mem.PreferredMethod = method;
        if (!mem.MethodHistory.Contains(method)) mem.MethodHistory.Add(method);
        if (node.Rect.Length == 4) mem.LastSeenRect = node.Rect;

        wf.Uses++;
        wf.Successes++;
        wf.UpdatedAt = mem.LastSeenAt;
        exp.Uses++;
        exp.Successes++;
        Save(window, exp);
    }

    public static void RecordFailure(AppExperience exp, WindowInfo window, string workflow)
    {
        var wf = exp.FindWorkflow(workflow);
        if (wf != null) wf.UpdatedAt = DateTime.UtcNow.ToString("O");
        exp.Uses++;
        exp.Failures++;
        Save(window, exp);
    }

    private static string FilePath(string key)
    {
        Directory.CreateDirectory(Paths.Experience);
        return Path.Combine(Paths.Experience, Paths.SafeFileName(key) + ".json");
    }

    private static string VersionOf(string exePath)
    {
        try
        {
            var vi = System.Diagnostics.FileVersionInfo.GetVersionInfo(exePath);
            return vi.FileVersion ?? "";
        }
        catch
        {
            return "";
        }
    }
}
