using System.Net;
using System.Text;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class MdnsDeviceDiscoveryTests
{
    [Fact]
    public void Parser_ReadsServiceAndModelAdvertisements()
    {
        var packet = Packet(
            ("_ipp._tcp.local", 12, Name("Office._ipp._tcp.local")),
            ("Office._device-info._tcp.local", 16, Txt("model=Macmini9,1")));

        var result = MdnsDeviceDiscoveryService.ParseResponse(packet);
        Assert.Equal("_ipp._tcp.local", Assert.Single(result.Services));
        Assert.Equal("Macmini9,1", result.Model);
    }

    [Fact]
    public void Parser_RejectsEveryTruncationAndPointerLoopWithoutThrowing()
    {
        var packet = Packet(("_ipp._tcp.local", 12, Name("Office._ipp._tcp.local")));
        for (var length = 0; length < packet.Length; length++)
        {
            var result = MdnsDeviceDiscoveryService.ParseResponse(packet[..length]);
            Assert.Empty(result.Services);
        }

        byte[] loop = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xC0, 12];
        Assert.Empty(MdnsDeviceDiscoveryService.ParseResponse(loop).Services);
    }

    [Fact]
    public void Parser_HandlesCompressedRecordNames()
    {
        var packet = Packet(
            ("_ipp._tcp.local", 12, Name("Office._ipp._tcp.local")),
            ("_ipp._tcp.local", 12, Name("Second._ipp._tcp.local")));
        var secondOffset = 12 + Name("_ipp._tcp.local").Length + 10 + Name("Office._ipp._tcp.local").Length;
        var compressed = packet[..secondOffset].Concat(new byte[] { 0xC0, 12 })
            .Concat(packet[(secondOffset + Name("_ipp._tcp.local").Length)..]).ToArray();
        Assert.Equal("_ipp._tcp.local",
            Assert.Single(MdnsDeviceDiscoveryService.ParseResponse(compressed).Services));
    }

    [Fact]
    public void Parser_IgnoresQueriesUnrelatedTxtAndMalformedTxt()
    {
        var query = Packet(("_ipp._tcp.local", 12, Name("Office._ipp._tcp.local")));
        query[2] = 0;
        Assert.Empty(MdnsDeviceDiscoveryService.ParseResponse(query).Services);
        Assert.Null(MdnsDeviceDiscoveryService.ParseResponse(
            Packet(("Office._http._tcp.local", 16, Txt("model=iPhone15,2")))).Model);
        Assert.Null(MdnsDeviceDiscoveryService.ParseResponse(
            Packet(("Office._device-info._tcp.local", 16, [255, 1]))).Model);
    }

    [Fact]
    public void Parser_DoesNotGuessBetweenConflictingModels()
    {
        var packet = Packet(
            ("Office._device-info._tcp.local", 16, Txt("model=Macmini9,1")),
            ("Office._airplay._tcp.local", 16, Txt("model=AppleTV6,2")));
        var result = MdnsDeviceDiscoveryService.ParseResponse(packet);
        Assert.Null(result.Model);
        Assert.True(result.HasConflictingModels);
        Assert.Equal(Models.DeviceOperatingSystem.Unknown,
            DeviceClassifier.Classify(null, result).OperatingSystem);
    }

    [Fact]
    public async Task Discovery_PropagatesCancellation()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new MdnsDeviceDiscoveryService().DiscoverAsync(IPAddress.Loopback, cancellation.Token));
    }

    private static byte[] Name(string name) => name.Split('.')
        .SelectMany(label => new[] { (byte)Encoding.UTF8.GetByteCount(label) }.Concat(Encoding.UTF8.GetBytes(label)))
        .Append((byte)0).ToArray();

    private static byte[] Txt(string text) =>
        new[] { (byte)Encoding.UTF8.GetByteCount(text) }.Concat(Encoding.UTF8.GetBytes(text)).ToArray();

    private static byte[] Packet(params (string Name, int Type, byte[] Data)[] records)
    {
        var bytes = new List<byte> { 0, 0, 0x84, 0, 0, 0, 0, (byte)records.Length, 0, 0, 0, 0 };
        foreach (var record in records)
        {
            bytes.AddRange(Name(record.Name));
            bytes.AddRange([(byte)(record.Type >> 8), (byte)record.Type, 0, 1, 0, 0, 0, 120,
                (byte)(record.Data.Length >> 8), (byte)record.Data.Length]);
            bytes.AddRange(record.Data);
        }

        return bytes.ToArray();
    }
}
