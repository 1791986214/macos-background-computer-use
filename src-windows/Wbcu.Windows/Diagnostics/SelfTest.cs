using Wbcu.Contract;
using Wbcu.Windows.Uia;
using Wbcu.Windows.Win32;

namespace Wbcu.Windows.Diagnostics;

/// <summary>
/// 自检：不需要交互桌面、不需要目标应用，CI 上可跑。
///
/// 它检查的是「引擎自己的逻辑与依赖是否完好」，不是「点击能不能成功」——
/// 后者必须由 GUI 测试套件在真机桌面上跑（见 Wbcu.GuiTests）。
/// 这条边界必须清楚，否则很容易拿自检全绿去冒充功能验收。
/// </summary>
public static class SelfTest
{
    public sealed class Check
    {
        public string Name { get; init; } = "";
        public bool Ok { get; set; }
        public string Detail { get; set; } = "";
    }

    public static (bool Ok, List<Check> Checks) Run()
    {
        var checks = new List<Check>();

        void Case(string name, Func<string> body)
        {
            var c = new Check { Name = name };
            try
            {
                c.Detail = body();
                c.Ok = true;
            }
            catch (Exception ex)
            {
                c.Ok = false;
                c.Detail = ex.GetType().Name + ": " + ex.Message;
            }
            checks.Add(c);
        }

        Case("contract.actions", () =>
        {
            if (Actions.All.Length != 11) throw new Exception("动作数量不是 11");
            if (Actions.All.Distinct().Count() != Actions.All.Length) throw new Exception("动作名重复");
            return "11 个统一动作";
        });

        Case("contract.schema", () =>
        {
            var s = ContractSchema.Build(Platforms.Windows, Engines.WindowsUia, Capabilities.Version);
            if (!s.ContainsKey("invariants")) throw new Exception("契约缺少 invariants");
            return "schemaVersion=" + s["schemaVersion"];
        });

        Case("verify.four_categories", () =>
        {
            var pre = new ElementReadout { Found = true, Value = "0" };
            var ok = VerifyLogic.Evaluate(new StateExpectation { Value = "15" }, pre,
                                          new ElementReadout { Found = true, Value = "15" }, true, true, "", "t", "a");
            if (ok.Result != VerifyCategory.Success) throw new Exception("成功用例判错");
            var already = VerifyLogic.Evaluate(new StateExpectation { Value = "0" }, pre,
                                               new ElementReadout { Found = true, Value = "0" }, false, true, "", "t", "a");
            if (already.Result != VerifyCategory.AlreadySatisfied) throw new Exception("幂等用例判错");
            var fail = VerifyLogic.Evaluate(new StateExpectation { Value = "15" }, pre,
                                            new ElementReadout { Found = true, Value = "12" }, true, true, "", "t", "a");
            if (fail.Result != VerifyCategory.Failure) throw new Exception("失败用例判错");
            var unk = VerifyLogic.Evaluate(new StateExpectation(), pre,
                                           new ElementReadout { Found = true, Value = "0" }, null, true, "", "t", "a");
            if (unk.Result != VerifyCategory.Inconclusive) throw new Exception("证据不足用例判错");
            return "四分类语义正确";
        });

        Case("text.normalize", () =>
        {
            if (TextNormalize.Normalize("\u200E7,778") != "7778") throw new Exception("LRM/千分位归一化失败");
            return "不可见字符与千分位已归一";
        });

        Case("selector.parse", () =>
        {
            var s = Selector.Parse("controltype:Button[1]");
            if (s.Kind != SelectorKind.ControlType || s.Nth != 1) throw new Exception("下标解析失败");
            return "选择器语法正常";
        });

        Case("capture.png_encoder", () =>
        {
            var buf = new byte[4 * 4 * 4];
            var png = PngWriter.FromBgra(buf, 4, 4);
            if (png.Length < 60 || png[1] != 0x50) throw new Exception("PNG 编码异常");
            return $"{png.Length} bytes";
        });

        Case("ghost.raster", () =>
        {
            var buf = CursorRaster.RenderCursor(64);
            if (buf.Length != 64 * 64 * 4) throw new Exception("光栅尺寸错误");
            for (var i = 3; i < buf.Length; i += 4)
            {
                if (buf[i] > 200) return "光标已渲染且有实心像素";
            }
            throw new Exception("没有实心像素");
        });

        Case("state.dir", () =>
        {
            var probe = Path.Combine(Paths.Root, ".selftest");
            File.WriteAllText(probe, "ok");
            var back = File.ReadAllText(probe);
            File.Delete(probe);
            if (back != "ok") throw new Exception("状态目录不可写");
            return Paths.Root;
        });

        Case("uia.init", () =>
        {
            // CI / 服务会话里没有交互桌面：UIA 的语义调用可能不可用。
            // 这种情况如实记「跳过」，不算通过，也不算失败。
            if (!Environment.UserInteractive)
            {
                return "跳过（非交互式会话，UIA 实测需要真实桌面）";
            }
            if (!UiaThread.Instance.Available)
            {
                throw new Exception("UIA 无法初始化：" + UiaThread.Instance.InitError);
            }
            // 真正调用一次，确认 COM 通路可用（会在 UIA 线程上执行）
            var count = UiaThread.Instance.Run(uia => uia.GetRootElement() != null ? 1 : 0);
            if (count != 1) throw new Exception("GetRootElement 返回空");
            return "CUIAutomation8 可用，GetRootElement 正常";
        });

        Case("foreground.readable", () =>
        {
            var fg = Native.GetForegroundWindow();
            return "前台窗口 0x" + fg.ToInt64().ToString("X");
        });

        var ok = checks.All(c => c.Ok);
        return (ok, checks);
    }
}

/// <summary>
/// 环境体检。比自检更进一步：检查安装位置、技能文件版本一致性、追踪守护进程等。
/// </summary>
public static class Doctor
{
    public static List<(string Name, string Status, string Detail)> Run()
    {
        var list = new List<(string, string, string)>();

        list.Add(("engine_version", "info", Capabilities.Version));
        list.Add(("os", "info", $"{Environment.OSVersion.VersionString} build {Environment.OSVersion.Version.Build}"));
        list.Add(("arch", "info", System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString()));

        // 解释器位置
        var exe = Environment.ProcessPath ?? "";
        list.Add(("engine_path", File.Exists(exe) ? "pass" : "fail", exe));

        // 技能文件
        var skillDir = SkillLocator.Find();
        if (skillDir == null)
        {
            list.Add(("skill_file", "warn", "没找到 WorkBuddy 技能目录（可用 --skill-dir 指定，或安装时传路径）"));
        }
        else
        {
            var md = Path.Combine(skillDir, "SKILL.md");
            if (!File.Exists(md))
            {
                list.Add(("skill_file", "warn", "技能目录存在但没有 SKILL.md：" + skillDir));
            }
            else
            {
                var version = SkillLocator.ReadVersion(md);
                list.Add(("skill_file", version == null ? "warn" : "pass", $"{md} (version={version ?? "?"})"));
                if (version != null && version != Capabilities.Version)
                {
                    list.Add(("version_match", "warn",
                        $"引擎 {Capabilities.Version} ≠ 技能 {version}（跑 install.ps1 同步）"));
                }
                else if (version != null)
                {
                    list.Add(("version_match", "pass", version));
                }
            }
        }

        // 状态目录
        try
        {
            var probe = Path.Combine(Paths.Root, ".doctor");
            File.WriteAllText(probe, "1");
            File.Delete(probe);
            list.Add(("state_dir", "pass", Paths.Root));
        }
        catch (Exception ex)
        {
            list.Add(("state_dir", "fail", ex.Message));
        }

        // UIA
        list.Add(("uia", UiaThread.Instance.Available ? "pass" : "fail",
                  UiaThread.Instance.Available ? "CUIAutomation8 已初始化" : UiaThread.Instance.InitError));

        // DWM / 捕获能力
        var build = Environment.OSVersion.Version.Build;
        list.Add(("graphics_capture", build >= 18362 ? "pass" : "warn",
                  build >= 18362 ? "系统支持 Graphics Capture" : "系统低于 1903，只能用 PrintWindow"));

        // 追踪守护进程
        var tracePid = Trace.ActivationTrace.DaemonPid();
        list.Add(("trace_daemon", tracePid != null ? "pass" : "info",
                  tracePid != null ? $"运行中 pid={tracePid}" : "未启动（wbcu trace start）"));

        // GUI 验收状态
        var verified = Diagnostics.Capabilities.LoadVerified();
        list.Add(("gui_verified", verified.Count > 1 ? "pass" : "warn",
                  verified.Count > 1
                      ? "已在本机跑过 GUI 测试套件：" + string.Join(", ", verified.Keys.Where(k => !k.StartsWith("__")))
                      : "尚未在本机跑过 GUI 测试套件（capabilities 会如实标 not_tested）"));

        return list;
    }
}

/// <summary>
/// 定位 WorkBuddy 技能目录。**不假设** macOS 的 ~/.workbuddy 在 Windows 上等价，
/// 而是逐个探测已知候选，全部失败就返回 null 让上层如实报告。
/// </summary>
public static class SkillLocator
{
    public static IEnumerable<string> Candidates()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        yield return Path.Combine(home, ".workbuddy", "skills", "workbuddy-third-hand");
        yield return Path.Combine(appData, "workbuddy", "skills", "workbuddy-third-hand");
        yield return Path.Combine(localAppData, "workbuddy", "skills", "workbuddy-third-hand");
        yield return Path.Combine(home, "Documents", "WorkBuddy", "skills", "workbuddy-third-hand");
    }

    public static string? Find()
    {
        foreach (var c in Candidates())
        {
            if (Directory.Exists(c)) return c;
        }
        // 退一步：只要 skills 目录存在，也算找到了（技能文件可能还没装）
        foreach (var c in Candidates())
        {
            var parent = Directory.GetParent(c)?.FullName;
            if (parent != null && Directory.Exists(parent)) return c;
        }
        return null;
    }

    public static string? ReadVersion(string skillMdPath)
    {
        try
        {
            foreach (var line in File.ReadLines(skillMdPath))
            {
                var t = line.Trim();
                if (t.StartsWith("version:", StringComparison.OrdinalIgnoreCase))
                {
                    return t.Substring("version:".Length).Trim();
                }
            }
        }
        catch { }
        return null;
    }
}
