using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Tests;

internal static class InventoryJsonFixture
{
    internal static async Task<DeviceInventoryData> WriteAsync(string path, DeviceInventoryData data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var saved = data with { Revision = Guid.NewGuid() };
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(new { version = 4, data = saved },
            new JsonSerializerOptions(JsonSerializerDefaults.Web)));
        return saved;
    }
}
