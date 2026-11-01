using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.Core.Formatting;

public static class NetworkDiagnosticFormatter
{
    public static string CheckpointAddress(DiagnosticObservation observation) => observation.Checkpoint switch
    {
        DiagnosticCheckpoint.Hop2 => observation.RespondingAddress?.ToString() ?? "Not observed",
        DiagnosticCheckpoint.CloudflareDns => NetworkDiagnosticService.Cloudflare.ToString(),
        DiagnosticCheckpoint.GoogleDns => NetworkDiagnosticService.Google.ToString(),
        _ => IPAddress.TryParse(observation.Target, out var address) ? address.ToString() : "Not supplied"
    };

    public static string Describe(DiagnosticObservation observation)
    {
        var address = observation.Checkpoint == DiagnosticCheckpoint.Hop2
            ? $"Responder: {CheckpointAddress(observation)} | Trace target: {observation.Target}"
            : observation.Target;
        return $"{address} | {observation.State} | {observation.Detail}"
            + (observation.Checkpoint != DiagnosticCheckpoint.Hop2 && observation.RespondingAddress is { } responder
                ? $" | response from {responder}" : string.Empty)
            + (observation.RoundtripMilliseconds is { } time ? $" | {time} ms" : string.Empty);
    }
}
