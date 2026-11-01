using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class RouterWanSettingsStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-wan-{Guid.NewGuid():N}");
    private string FilePath => Path.Combine(_directory, "router-wan.json");

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void BlankWanIsOptional(string input) => Assert.Null(RouterWanAddress.Parse(input));

    [Theory]
    [InlineData("203.0.113.10")]
    [InlineData("100.64.1.2")]
    [InlineData("192.168.1.2")]
    public void PublicCgnatAndPrivateWanValuesAreAllowed(string input) =>
        Assert.Equal(input, RouterWanAddress.Parse(input)!.ToString());

    [Theory]
    [InlineData("not an address")]
    [InlineData("::1")]
    [InlineData("1.2.3")]
    [InlineData("1.2.3.256")]
    [InlineData("0x01.2.3.4")]
    [InlineData("01.2.3.4")]
    [InlineData("127.0.0.1")]
    [InlineData("0.0.0.0")]
    [InlineData("224.0.0.1")]
    [InlineData("255.255.255.255")]
    public void InvalidWanValuesHaveExplicitErrors(string input) =>
        Assert.Throws<ArgumentException>(() => RouterWanAddress.Parse(input));

    [Fact]
    public void NetworkIdentitySeparatesNetworksEvenWithIdenticalPrivateAddressingAndSurvivesRestart()
    {
        var homeProfile = Guid.NewGuid();
        var workProfile = Guid.NewGuid();
        var store = new RouterWanSettingsStore(FilePath);
        store.Save(homeProfile, "203.0.113.10");
        store.Save(workProfile, "198.51.100.20");
        var restarted = new RouterWanSettingsStore(FilePath);
        Assert.Equal("203.0.113.10", restarted.Load(homeProfile));
        Assert.Equal("198.51.100.20", restarted.Load(workProfile));
        Assert.Equal(string.Empty, restarted.Load(Guid.NewGuid()));
        restarted.Save(homeProfile, "");
        Assert.Equal(string.Empty, store.Load(homeProfile));
        Assert.Equal("198.51.100.20", store.Load(workProfile));
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Fact]
    public void InvalidEditPreservesPreviouslySavedValue()
    {
        var id = Guid.NewGuid();
        var store = new RouterWanSettingsStore(FilePath);
        store.Save(id, "203.0.113.10");
        Assert.Throws<ArgumentException>(() => store.Save(id, "invalid"));
        Assert.Equal("203.0.113.10", store.Load(id));
    }

    [Fact]
    public void MissingIdentityIsNotAReusableGlobalKey()
    {
        var store = new RouterWanSettingsStore(FilePath);
        Assert.Throws<ArgumentException>(() => store.Load(Guid.Empty));
        Assert.Throws<ArgumentException>(() => store.Save(Guid.Empty, "203.0.113.10"));
    }

    [Fact]
    public void CorruptSettingsFailExplicitlyAndCannotBeOverwritten()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, "broken JSON");
        var store = new RouterWanSettingsStore(FilePath);
        Assert.Throws<System.Text.Json.JsonException>(() => store.Load(Guid.NewGuid()));
        Assert.Throws<System.Text.Json.JsonException>(() => store.Save(Guid.NewGuid(), "203.0.113.10"));
        Assert.Equal("broken JSON", File.ReadAllText(FilePath));
    }

    [Fact]
    public void InvalidSavedAddressFailsExplicitly()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, $"{{\"{Guid.NewGuid()}\":\"invalid\"}}");
        Assert.Throws<InvalidDataException>(() => new RouterWanSettingsStore(FilePath).Load(Guid.NewGuid()));
    }

    [Fact]
    public void SettingsReadFailureIsNotTreatedAsMissingSettingsOrOverwritten()
    {
        Directory.CreateDirectory(FilePath);
        var store = new RouterWanSettingsStore(FilePath);
        Assert.Throws<UnauthorizedAccessException>(() => store.Load(Guid.NewGuid()));
        Assert.Throws<UnauthorizedAccessException>(() => store.Save(Guid.NewGuid(), "203.0.113.10"));
        Assert.True(Directory.Exists(FilePath));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, true);
    }
}
