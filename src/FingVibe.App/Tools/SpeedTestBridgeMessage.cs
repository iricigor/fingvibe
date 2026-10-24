using System.Text.Json;

namespace FingVibe.App;

internal sealed record SpeedTestBridgeMessage(
    string Kind,
    string RunId,
    string? Phase = null,
    string? Category = null,
    string? ErrorMessage = null,
    int? HttpStatus = null,
    double? DownloadBps = null,
    double? UploadBps = null,
    double? LatencyMs = null,
    string? Location = null,
    double? Bps = null);

internal static class SpeedTestBridgeMessageParser
{
    private const int MaximumPayloadLength = 4096;
    private const int MaximumErrorLength = 500;
    private const int MaximumLocationLength = 100;

    public static bool TryParse(string payload, string expectedRunId, out SpeedTestBridgeMessage? message)
    {
        message = null;
        if (string.IsNullOrWhiteSpace(payload)
            || payload.Length > MaximumPayloadLength
            || string.IsNullOrWhiteSpace(expectedRunId))
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || HasDuplicateProperties(root))
            {
                return false;
            }

            if (!TryReadString(root, "kind", out var kind)
                || !TryReadString(root, "runId", out var runId)
                || !string.Equals(runId, expectedRunId, StringComparison.Ordinal))
            {
                return false;
            }

            switch (kind)
            {
                case "sample":
                    if (!HasOnlyProperties(root, "kind", "runId", "phase", "bps")
                        || !TryReadString(root, "phase", out var samplePhase)
                        || samplePhase is not ("download" or "upload")
                        || !TryReadPositiveNumber(root, "bps", out var bps))
                    {
                        return false;
                    }

                    message = new SpeedTestBridgeMessage(kind, runId, Phase: samplePhase, Bps: bps);
                    return true;

                case "progress":
                    if (!HasOnlyProperties(root, "kind", "runId", "phase")
                        || !TryReadString(root, "phase", out var phase)
                        || phase is not ("latency" or "latencyUnderLoad" or "download" or "upload"))
                    {
                        return false;
                    }

                    message = new SpeedTestBridgeMessage(kind, runId, Phase: phase);
                    return true;

                case "result":
                    if (!HasOnlyProperties(root, "kind", "runId", "downloadBps", "uploadBps", "latencyMs", "location")
                        || !TryReadPositiveNumber(root, "downloadBps", out var downloadBps)
                        || !TryReadPositiveNumber(root, "uploadBps", out var uploadBps)
                        || !TryReadPositiveNumber(root, "latencyMs", out var latencyMs)
                        || !TryReadOptionalLocation(root, out var location))
                    {
                        return false;
                    }

                    message = new SpeedTestBridgeMessage(
                        kind,
                        runId,
                        DownloadBps: downloadBps,
                        UploadBps: uploadBps,
                        LatencyMs: latencyMs,
                        Location: location);
                    return true;

                case "error":
                    if (!HasOnlyProperties(root, "kind", "runId", "category", "message", "status")
                        || !TryReadString(root, "category", out var category)
                        || category is not ("offline" or "rate-limited" or "rejected" or "timeout"
                            or "provider-unavailable" or "measurement" or "incomplete")
                        || !TryReadString(root, "message", out var error)
                        || error.Length > MaximumErrorLength
                        || error.Any(char.IsControl)
                        || !TryReadOptionalStatus(root, out var status))
                    {
                        return false;
                    }

                    message = new SpeedTestBridgeMessage(
                        kind,
                        runId,
                        Category: category,
                        ErrorMessage: error,
                        HttpStatus: status);
                    return true;

                case "cancelled":
                    if (!HasOnlyProperties(root, "kind", "runId"))
                    {
                        return false;
                    }

                    message = new SpeedTestBridgeMessage(kind, runId);
                    return true;

                default:
                    return false;
            }
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryReadString(JsonElement root, string propertyName, out string value)
    {
        value = string.Empty;
        if (!root.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return !string.IsNullOrWhiteSpace(value);
    }

    private static bool TryReadPositiveNumber(JsonElement root, string propertyName, out double value)
    {
        value = 0;
        return root.TryGetProperty(propertyName, out var property)
            && property.ValueKind == JsonValueKind.Number
            && property.TryGetDouble(out value)
            && double.IsFinite(value)
            && value > 0;
    }

    private static bool TryReadOptionalLocation(JsonElement root, out string? location)
    {
        location = null;
        if (!root.TryGetProperty("location", out var property) || property.ValueKind == JsonValueKind.Null)
        {
            return true;
        }

        if (property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        location = property.GetString();
        return !string.IsNullOrWhiteSpace(location)
            && location.Length <= MaximumLocationLength
            && !location.Any(char.IsControl);
    }

    private static bool TryReadOptionalStatus(JsonElement root, out int? status)
    {
        status = null;
        if (!root.TryGetProperty("status", out var property) || property.ValueKind == JsonValueKind.Null)
        {
            return true;
        }

        if (property.ValueKind != JsonValueKind.Number
            || !property.TryGetInt32(out var value)
            || value is < 100 or > 599)
        {
            return false;
        }

        status = value;
        return true;
    }

    private static bool HasDuplicateProperties(JsonElement root)
    {
        var propertyNames = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in root.EnumerateObject())
        {
            if (!propertyNames.Add(property.Name))
            {
                return true;
            }
        }

        return false;
    }

    private static bool HasOnlyProperties(JsonElement root, params string[] allowedProperties)
    {
        var allowed = new HashSet<string>(allowedProperties, StringComparer.Ordinal);
        return root.EnumerateObject().All(property => allowed.Contains(property.Name));
    }
}
