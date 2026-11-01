using System.Net;
using FingVibe.Core.Formatting;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkDiagnosticFormatterTests
{
    [Fact]
    public void HopResponderIsNotConfusedWithTraceDestination()
    {
        var observation = new DiagnosticObservation(DiagnosticCheckpoint.Hop2, "1.1.1.1",
            DiagnosticState.Responded, "Router responded (TTL expired).", IPAddress.Parse("100.79.10.1"), 7);

        Assert.Equal("100.79.10.1", NetworkDiagnosticFormatter.CheckpointAddress(observation));
        Assert.StartsWith("Responder: 100.79.10.1 | Trace target: 1.1.1.1", NetworkDiagnosticFormatter.Describe(observation));
        Assert.Contains("7 ms", NetworkDiagnosticFormatter.Describe(observation));
    }

    [Theory]
    [InlineData(DiagnosticState.Untested)]
    [InlineData(DiagnosticState.Running)]
    [InlineData(DiagnosticState.Unanswered)]
    [InlineData(DiagnosticState.Unavailable)]
    [InlineData(DiagnosticState.Cancelled)]
    public void MissingHopResponseNeverUsesDestinationAsResponder(DiagnosticState state)
    {
        var observation = new DiagnosticObservation(DiagnosticCheckpoint.Hop2, "1.1.1.1", state, "No observed address.");
        Assert.Equal("Not observed", NetworkDiagnosticFormatter.CheckpointAddress(observation));
        Assert.StartsWith("Responder: Not observed | Trace target: 1.1.1.1", NetworkDiagnosticFormatter.Describe(observation));
    }

    [Theory]
    [InlineData(DiagnosticCheckpoint.CloudflareDns, "1.1.1.1")]
    [InlineData(DiagnosticCheckpoint.GoogleDns, "8.8.8.8")]
    public void DnsPortAddressIdentifiesResolverNotResolvedHostname(DiagnosticCheckpoint checkpoint, string resolver)
    {
        var observation = new DiagnosticObservation(checkpoint, $"example.com via {resolver}",
            DiagnosticState.Responded, "Resolved", IPAddress.Parse("93.184.215.14"));
        Assert.Equal(resolver, NetworkDiagnosticFormatter.CheckpointAddress(observation));
    }

    [Fact]
    public void OptionalWanAddressIsExplicitlyMissingOrUsesUserInput()
    {
        Assert.Equal("Not supplied", NetworkDiagnosticFormatter.CheckpointAddress(
            new(DiagnosticCheckpoint.RouterWan, "Not available", DiagnosticState.Unavailable, "Not supplied.")));
        Assert.Equal("203.0.113.10", NetworkDiagnosticFormatter.CheckpointAddress(
            new(DiagnosticCheckpoint.RouterWan, "203.0.113.10", DiagnosticState.Untested, "Not tested.")));
    }
}
