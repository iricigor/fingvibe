using Ex220Inspector;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class Ex220ClientCaptureTests
{
    private static RouterClient Client(string mac = "aa-bb-cc-dd-ee-ff", string ip = "192.168.0.2") =>
        new("Desktop", mac, ip);

    [Fact]
    public void WirelessRequiresCapturedWiredListAndExplicitCompletion()
    {
        var capture = new ClientCapture();
        capture.Add(ClientSource.Clients, [Client()]);
        Assert.Equal("Unknown", Assert.Single(capture.Rows(true)).Connection);
        capture.Add(ClientSource.Wired, []);
        Assert.Equal("Unknown", Assert.Single(capture.Rows(false)).Connection);
        Assert.Equal("Wireless", Assert.Single(capture.Rows(true)).Connection);
    }

    [Fact]
    public void NormalizedMacJoinsSourcesAndArpCannotImplyWireless()
    {
        var capture = new ClientCapture();
        capture.Add(ClientSource.Clients, [Client()]);
        capture.Add(ClientSource.Wired, [Client("AA:BB:CC:DD:EE:FF")]);
        capture.Add(ClientSource.Arp, [Client("AA:BB:CC:DD:EE:FF", "192.168.0.3"), Client("00:11:22:33:44:55")]);
        var rows = capture.Rows(true);
        Assert.Equal("Unknown", rows[0].Connection);
        Assert.Equal("No Client List entry", rows[0].ArpComparison);
        Assert.Equal("Wired", rows[1].Connection);
        Assert.Equal("Different IP: ARP 192.168.0.3", rows[1].ArpComparison);
        Assert.Equal("192.168.0.2", rows[1].Ip);
    }

    [Fact]
    public void FailedCaptureDoesNotSavePartialRows()
    {
        var capture = new ClientCapture();
        Assert.Throws<InvalidDataException>(() => capture.Add(ClientSource.Clients,
            [Client(), Client("bad")]));
        Assert.False(capture.Has(ClientSource.Clients));
        Assert.Throws<InvalidDataException>(() => capture.Add(ClientSource.Clients,
            [Client(ip: "999.1.1.1")]));
    }

    [Fact]
    public void PaginationAccumulatesAndClearResetsCompleteness()
    {
        var capture = new ClientCapture();
        capture.Add(ClientSource.Clients, [Client()]);
        capture.Add(ClientSource.Clients, [Client("00:11:22:33:44:55")]);
        capture.Add(ClientSource.Clients, [Client(ip: "192.168.0.4")]);
        Assert.Equal(2, capture.Count(ClientSource.Clients));
        Assert.Equal("192.168.0.4", capture.Rows(false)[1].Ip);
        capture.Clear();
        Assert.Empty(capture.Rows(true));
        Assert.False(capture.Has(ClientSource.Clients));
    }

    [Fact]
    public void IndividualReplacementRemovesStaleRowsAndPreservesOtherSources()
    {
        var capture = new ClientCapture();
        capture.Add(ClientSource.Clients, [Client()]);
        capture.Add(ClientSource.Wired, [Client("00:11:22:33:44:55")]);
        capture.Add(ClientSource.Arp, [Client()]);
        var completed = new ClientCapture();
        completed.Add(ClientSource.Wired, [Client()]);
        capture.ReplaceSource(ClientSource.Wired, completed);
        completed.Clear();

        var row = Assert.Single(capture.Rows(true));
        Assert.Equal("Wired", row.Connection);
        Assert.Equal("Client List, Wired Clients, ARP", row.Sources);
        Assert.Equal("Same IP", row.ArpComparison);
    }

    [Fact]
    public void EmptyCompleteWiredReplacementRemovesOldWiredMembership()
    {
        var capture = new ClientCapture();
        capture.Add(ClientSource.Clients, [Client()]);
        capture.Add(ClientSource.Wired, [Client()]);
        var empty = new ClientCapture();
        empty.Add(ClientSource.Wired, []);
        capture.ReplaceSource(ClientSource.Wired, empty);

        Assert.True(capture.Has(ClientSource.Wired));
        Assert.Equal(0, capture.Count(ClientSource.Wired));
        Assert.Equal("Wireless", Assert.Single(capture.Rows(true)).Connection);
    }

    [Fact]
    public void MultipleArpAddressesPreserveEvidenceWithoutOverwritingClientIp()
    {
        var capture = new ClientCapture();
        capture.Add(ClientSource.Clients, [Client()]);
        capture.Add(ClientSource.Arp, [Client(), Client(ip: "192.168.0.3")]);
        capture.Add(ClientSource.Arp, [Client()]);

        var row = Assert.Single(capture.Rows(false));
        Assert.Equal("192.168.0.2", row.Ip);
        Assert.Equal("Multiple ARP IPs: 192.168.0.2, 192.168.0.3", row.ArpComparison);
        Assert.Equal(2, capture.Count(ClientSource.Arp));
        var replacement = new ClientCapture();
        replacement.Add(ClientSource.Arp, [Client()]);
        capture.ReplaceSource(ClientSource.Arp, replacement);
        Assert.Equal("Same IP", Assert.Single(capture.Rows(false)).ArpComparison);
    }

    [Fact]
    public void DifferencesFilterHidesOnlyConfirmedMatchesAndPreservesOtherEvidence()
    {
        var statuses = new[] { "Same in DB", "Different in DB", "Not in DB", "Cannot compare", "DB not loaded", "Not compared" };
        var rows = statuses.Select(status => new ClientDisplay("Desktop", "AA:BB:CC:DD:EE:FF",
            "192.168.0.2", "Wired", "Client List", "Same IP", status, "Saved name", "192.168.0.2")).ToArray();
        var filtered = ClientCapture.FilterRows(rows, true);
        Assert.Equal(statuses.Skip(1), filtered.Select(row => row.DbComparison));
        Assert.All(filtered, row => Assert.Equal("Saved name", row.DbName));
        Assert.Equal(rows, ClientCapture.FilterRows(rows, false));
    }
}
