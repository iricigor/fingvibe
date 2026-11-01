using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DiagnosticDnsPacketTests
{
    private static byte[] Response()
    {
        var query = DiagnosticDnsPacket.CreateQuery(123, NetworkDiagnosticService.DnsHostname).ToList();
        query[2] = 0x81;
        query[3] = 0x80;
        query[7] = 1;
        query.AddRange([0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 215, 14]);
        return query.ToArray();
    }

    [Fact]
    public void MatchingCompressedIpv4AnswerIsParsed()
    {
        var addresses = DiagnosticDnsPacket.ReadResponse(Response(), 123, NetworkDiagnosticService.DnsHostname);
        Assert.Equal("93.184.215.14", Assert.Single(addresses).ToString());
    }

    [Fact]
    public void MismatchedTransactionQuestionAndTruncationFailExplicitly()
    {
        Assert.Throws<InvalidDataException>(() => DiagnosticDnsPacket.ReadResponse(Response(), 124, NetworkDiagnosticService.DnsHostname));
        Assert.Throws<InvalidDataException>(() => DiagnosticDnsPacket.ReadResponse(Response(), 123, "other.example"));
        Assert.Throws<InvalidDataException>(() => DiagnosticDnsPacket.ReadResponse(Response()[..^1], 123, NetworkDiagnosticService.DnsHostname));
        var truncated = Response();
        truncated[2] |= 2;
        Assert.Throws<InvalidDataException>(() => DiagnosticDnsPacket.ReadResponse(truncated, 123, NetworkDiagnosticService.DnsHostname));
    }

    [Fact]
    public void NegativeDnsReplyIsNotNumericReachabilitySuccess()
    {
        var packet = Response();
        packet[3] |= 3;
        Assert.Throws<InvalidDataException>(() => DiagnosticDnsPacket.ReadResponse(packet, 123, NetworkDiagnosticService.DnsHostname));
    }

    [Fact]
    public void CompressionLoopsAreBounded()
    {
        var packet = Response();
        packet[12] = 0xC0;
        packet[13] = 12;
        Assert.Throws<InvalidDataException>(() => DiagnosticDnsPacket.ReadResponse(packet, 123, NetworkDiagnosticService.DnsHostname));
    }
}
