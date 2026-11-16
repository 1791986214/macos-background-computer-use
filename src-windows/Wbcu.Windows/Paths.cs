using System.Security.Cryptography;
using System.Text;

namespace Wbcu.Windows;

/// <summary>
/// 状态目录。Windows 用 %LOCALAPPDATA%\wbcu，**不要**照搬 macOS 的 ~/.wbcu —— 
/// 两者语义一样（每用户、本机、不需要管理员），但路径规则不同。
/// </summary>
public static class Paths
{
    public static string Root
    {
        get
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(local))
            {
                local = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Local");
            }
            var p = System.IO.Path.Combine(local, "wbcu");
            Directory.CreateDirectory(p);
            return p;
        }
    }

    public static string Sessions => EnsureDir(System.IO.Path.Combine(Root, "sessions"));
    public static string Experience => EnsureDir(System.IO.Path.Combine(Root, "experience"));
    public static string Trace => EnsureDir(System.IO.Path.Combine(Root, "trace"));
    public static string Perf => System.IO.Path.Combine(Root, "perf.jsonl");

    public static string SessionFile(string id) => System.IO.Path.Combine(Sessions, id + ".json");

    public static string TempDir
    {
        get
        {
            var d = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "wbcu");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    private static string EnsureDir(string p)
    {
        Directory.CreateDirectory(p);
        return p;
    }

    /// <summary>
    /// 短会话 id：时间戳 + 目标指纹，人和机器都能读。
    /// 加随机后缀是为了避免同一毫秒内并发起两个会话时撞号。
    /// </summary>
    public static string NewSessionId(int pid, string windowHandle)
    {
        var stamp = DateTime.UtcNow.ToString("yyMMddHHmmss");
        var tail = Math.Abs((pid * 31 + windowHandle.GetHashCode()) % 997);
        var rnd = Convert.ToHexString(RandomNumberGenerator.GetBytes(2)).ToLowerInvariant();
        return $"s{stamp}{tail:000}{rnd}";
    }

    public static string SafeFileName(string s)
    {
        var sb = new StringBuilder();
        foreach (var c in s)
        {
            sb.Append(char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_');
        }
        var name = sb.ToString();
        if (name.Length > 120) name = name.Substring(0, 120);
        return name;
    }
}
