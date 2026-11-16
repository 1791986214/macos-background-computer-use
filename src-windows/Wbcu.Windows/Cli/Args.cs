namespace Wbcu.Windows.Cli;

/// <summary>
/// 参数解析。刻意与 macOS 引擎的 Args 保持同一套规则：
///   --key value / --key=value / --flag / positional
/// 这样同一段 Skill 指令在两个平台上写法完全一致（只有可执行文件名不同）。
/// </summary>
public sealed class Args
{
    private static readonly HashSet<string> BoolFlags = new(StringComparer.Ordinal)
    {
        "json", "pretty", "all", "foreground", "no-verify", "no-ghost", "no-experience",
        "allow-global", "exact", "raw", "follow", "idempotent", "deep", "force", "new",
    };

    public List<string> Positional { get; } = new();
    public HashSet<string> Flags { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> Opts { get; } = new(StringComparer.Ordinal);

    public static Args Parse(IReadOnlyList<string> argv)
    {
        var a = new Args();
        var i = 0;
        while (i < argv.Count)
        {
            var t = argv[i];
            if (t.StartsWith("--", StringComparison.Ordinal))
            {
                var key = t.Substring(2);
                if (key.Length == 0) { i++; continue; }

                var eq = key.IndexOf('=');
                if (eq >= 0)
                {
                    a.Opts[key.Substring(0, eq)] = key.Substring(eq + 1);
                    i++;
                    continue;
                }

                if (BoolFlags.Contains(key))
                {
                    a.Flags.Add(key);
                    i++;
                    continue;
                }

                if (i + 1 < argv.Count && !argv[i + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    a.Opts[key] = argv[i + 1];
                    i += 2;
                    continue;
                }

                a.Flags.Add(key);
                i++;
                continue;
            }

            a.Positional.Add(t);
            i++;
        }
        return a;
    }

    public string? Str(string k) => Opts.TryGetValue(k, out var v) ? v : null;
    public bool Flag(string k) => Flags.Contains(k);

    public int? Int(string k) => int.TryParse(Str(k), out var v) ? v : null;
    public double? Dbl(string k) => double.TryParse(Str(k), out var v) ? v : null;

    public string Require(string k) =>
        Str(k) ?? throw new CliError(Contract.ErrorCodes.BadArgs, $"缺少参数 --{k}");

    public int RequireInt(string k) =>
        Int(k) ?? throw new CliError(Contract.ErrorCodes.BadArgs, $"缺少整数参数 --{k}");
}

/// <summary>携带稳定错误码的异常：CLI 顶层统一转成 JSON 错误信封。</summary>
public sealed class CliError : Exception
{
    public string Code { get; }
    public int ExitCode { get; }

    public CliError(string code, string message, int exitCode = ExitCodes.BadArgs) : base(message)
    {
        Code = code;
        ExitCode = exitCode;
    }
}

public static class ExitCodes
{
    public const int Ok = 0;
    public const int Internal = 1;
    public const int BadArgs = 2;
    public const int TargetNotFound = 3;
    public const int UiaUnavailable = 4;
    public const int NotDelivered = 5;
    public const int VerifyFailed = 6;
    public const int NotSupported = 7;
}
