using Wbcu.Contract;

namespace Wbcu.Windows.Cli;

/// <summary>
/// 输出与退出码的统一口径。
/// JSON 模式下 stdout 只允许出现**一个** JSON 对象（供 Skill 直接解析）；
/// 人类可读的提示走 stderr，绝不污染 stdout。
/// </summary>
public sealed class Ctx
{
    public Args Args { get; }
    public bool Json { get; }
    public bool Pretty { get; }

    public Ctx(Args args)
    {
        Args = args;
        Json = args.Flag("json");
        Pretty = args.Flag("pretty");
    }

    public void Emit(ResultEnvelope env)
    {
        env.Platform = Platforms.Windows;
        env.Engine = Engines.WindowsUia;

        if (Json)
        {
            Console.Out.WriteLine(env.ToJson(Pretty));
            return;
        }

        var head = env.Ok ? "OK  " : "FAIL";
        Console.Out.WriteLine($"{head} {env.Action}"
            + (env.Method != null ? $"  method={env.Method}" : "")
            + $"  {env.ElapsedMs:0}ms");

        if (env.Verification != null)
        {
            var v = env.Verification;
            Console.Out.WriteLine($"     验证: {v.Result.ToWire()} ({v.VerificationMethod}, 置信度 {v.Confidence:0.00})");
            if (v.Note.Length > 0) Console.Out.WriteLine($"     说明: {v.Note}");
        }
        if (!string.IsNullOrEmpty(env.FailureReason)) Console.Out.WriteLine($"     原因: {env.FailureReason}");
        foreach (var w in env.Warnings) Console.Out.WriteLine($"     注意: {w}");
        foreach (var kv in env.Data)
        {
            if (kv.Value is IEnumerable<object> seq)
            {
                var items = seq.Take(40).Select(x => "       - " + x);
                Console.Out.WriteLine($"     {kv.Key}:");
                foreach (var line in items) Console.Out.WriteLine(line);
            }
            else
            {
                Console.Out.WriteLine($"     {kv.Key}: {kv.Value}");
            }
        }
    }

    public void EmitObject(object o)
    {
        if (Json)
        {
            Console.Out.WriteLine(Wbcu.Contract.Json.Serialize(o, Pretty));
            return;
        }

        if (o is IEnumerable<object> seq)
        {
            foreach (var item in seq) Console.Out.WriteLine(item);
        }
        else
        {
            Console.Out.WriteLine(o);
        }
    }

    public void Text(string s) => Console.Out.WriteLine(s);
    public void Warn(string s) => Console.Error.WriteLine("wbcu: " + s);

    public int Fail(CliError e)
    {
        var env = ResultEnvelope.Error("", e.Code, e.Message);
        if (Json)
        {
            Console.Out.WriteLine(env.ToJson(Pretty));
        }
        else
        {
            Console.Error.WriteLine($"wbcu: {e.Message}");
        }
        return e.ExitCode;
    }
}
