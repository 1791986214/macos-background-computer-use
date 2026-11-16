using System.Text.Json;
using System.Text.Json.Serialization;

namespace Wbcu.Contract;

/// <summary>四分类的线上字面量是 snake_case，这里用专用转换器保证两个平台一致。</summary>
public sealed class VerifyCategoryConverter : JsonConverter<VerifyCategory>
{
    public override VerifyCategory Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var s = reader.GetString();
        return s switch
        {
            "success" => VerifyCategory.Success,
            "already_satisfied" => VerifyCategory.AlreadySatisfied,
            "failure" => VerifyCategory.Failure,
            _ => VerifyCategory.Inconclusive,
        };
    }

    public override void Write(Utf8JsonWriter writer, VerifyCategory value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToWire());
}
