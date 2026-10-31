using System.Net;

namespace FingVibe.Core.Models;

public enum DiagnosticState { Untested, Running, Responded, Unanswered, Unavailable, Error, Cancelled }
public enum DiagnosticCheckpoint { Loopback, LocalAddress, Gateway, RouterWan, Hop2, CloudflarePing, GooglePing, ConfiguredDns, CloudflareDns, GoogleDns }
public enum DiagnosticSummaryKind { Neutral, Good, Warning, Problem }

public sealed record DiagnosticObservation(
    DiagnosticCheckpoint Checkpoint,
    string Target,
    DiagnosticState State,
    string Detail,
    IPAddress? RespondingAddress = null,
    long? RoundtripMilliseconds = null);

public sealed record TraceHop(int Number, DiagnosticObservation Observation, bool ReachedDestination);

public sealed record NetworkDiagnosticReport(
    IReadOnlyList<DiagnosticObservation> Observations,
    IReadOnlyList<TraceHop> Hops,
    bool TraceComplete,
    bool Cancelled);

public sealed record DiagnosticSummary(DiagnosticSummaryKind Kind, string Status, string Explanation);
