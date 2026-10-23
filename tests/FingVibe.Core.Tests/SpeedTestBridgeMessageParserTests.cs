using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SpeedTestBridgeMessageParserTests
{
    private const string RunId = "test-run-1";

    [Theory]
    [InlineData("""{"kind":"progress","runId":"test-run-1","phase":"download"}""", "progress")]
    [InlineData("""{"kind":"cancelled","runId":"test-run-1"}""", "cancelled")]
    [InlineData("""{"kind":"error","runId":"test-run-1","category":"rate-limited","message":"HTTP 429","status":429}""", "error")]
    [InlineData("""{"kind":"result","runId":"test-run-1","downloadBps":125000000,"uploadBps":80000000,"latencyMs":12.5,"location":null}""", "result")]
    public void ParsesValidMessages(string payload, string expectedKind)
    {
        Assert.True(SpeedTestBridgeMessageParser.TryParse(payload, RunId, out var message));
        Assert.Equal(expectedKind, message!.Kind);
    }

    [Theory]
    [InlineData("""{"kind":"progress","runId":"old-run","phase":"download"}""")]
    [InlineData("""{"kind":"progress","runId":"test-run-1","phase":"packetLoss"}""")]
    [InlineData("""{"kind":"progress","runId":"test-run-1","phase":"download","percent":100}""")]
    [InlineData("""{"kind":"result","runId":"test-run-1","downloadBps":0,"uploadBps":80000000,"latencyMs":12.5}""")]
    [InlineData("""{"kind":"result","runId":"test-run-1","downloadBps":125000000,"uploadBps":-1,"latencyMs":12.5}""")]
    [InlineData("""{"kind":"result","runId":"test-run-1","downloadBps":1e999,"uploadBps":1,"latencyMs":12.5}""")]
    [InlineData("""{"kind":"result","runId":"test-run-1","downloadBps":125000000,"uploadBps":80000000,"latencyMs":0}""")]
    [InlineData("""{"kind":"error","runId":"test-run-1","category":"unknown","message":"failed"}""")]
    [InlineData("""{"kind":"error","runId":"test-run-1","category":"measurement","message":"bad\u0001message"}""")]
    [InlineData("""{"kind":"cancelled","runId":"test-run-1","nativeMethod":"evil"}""")]
    [InlineData("""{"kind":"cancelled","kind":"result","runId":"test-run-1"}""")]
    [InlineData("""not json""")]
    public void RejectsMalformedStaleOrOutOfContractMessages(string payload)
    {
        Assert.False(SpeedTestBridgeMessageParser.TryParse(payload, RunId, out _));
    }

    [Fact]
    public void RejectsOversizedMessages()
    {
        var payload = $$"""{"kind":"error","runId":"{{RunId}}","category":"measurement","message":"{{new string('x', 5000)}}"}""";

        Assert.False(SpeedTestBridgeMessageParser.TryParse(payload, RunId, out _));
    }
}
