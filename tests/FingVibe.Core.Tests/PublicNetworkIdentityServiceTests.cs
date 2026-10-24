using System.Net;
using System.Text;
using FingVibe.App;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PublicNetworkIdentityServiceTests
{
    [Fact]
    public async Task GetAsync_ParsesPublicAddressAndIspName()
    {
        const string response = """
            {
              "success": true,
              "ip": "203.0.113.10",
              "connection": {
                "isp": "Example ISP"
              }
            }
            """;
        var service = CreateService(HttpStatusCode.OK, response);

        var identity = await service.GetAsync();

        Assert.Equal(IPAddress.Parse("203.0.113.10"), identity.PublicAddress);
        Assert.Equal("Example ISP", identity.IspName);
    }

    [Fact]
    public async Task GetAsync_TMobileCzechIdentityFlowsUnchangedIntoLogoRequest()
    {
        const string response = """
            {
              "success": true,
              "ip": "203.0.113.10",
              "connection": {
                "isp": "T-Mobile Czech Republic a.s."
              }
            }
            """;
        var service = CreateService(HttpStatusCode.OK, response);

        var identity = await service.GetAsync();
        using var session = new IspLogoSession();
        Assert.True(session.Update(identity.IspName, "pk_test_not_a_real_key"));
        var request = Assert.IsType<IspLogoSession.Request>(session.Current);

        Assert.Equal("T-Mobile Czech Republic a.s.", identity.IspName);
        Assert.Equal("https://img.logo.dev/name/T-Mobile%20Czech%20Republic%20a.s."
            + "?token=pk_test_not_a_real_key&format=png&size=128&fallback=404", request.Uri.AbsoluteUri);
        Assert.False(session.Update(identity.IspName, "pk_test_not_a_real_key"));
        Assert.Same(request, session.Current);
    }

    [Fact]
    public async Task GetAsync_ParsesLocation()
    {
        const string response = """
            {
              "success": true,
              "ip": "203.0.113.10",
              "city": "Belgrade",
              "region": "Belgrade",
              "country": "Serbia",
              "connection": {
                "isp": "Example ISP"
              }
            }
            """;
        var service = CreateService(HttpStatusCode.OK, response);

        var identity = await service.GetAsync();

        Assert.Equal("Belgrade, Serbia", identity.Location);
        Assert.Equal("Belgrade, Serbia", identity.LocationText);
    }

    [Fact]
    public async Task GetAsync_ReportsUnknownLocationWhenMissing()
    {
        const string response = """
            {
              "success": true,
              "ip": "203.0.113.10",
              "city": "",
              "connection": {
                "isp": "Example ISP"
              }
            }
            """;
        var service = CreateService(HttpStatusCode.OK, response);

        var identity = await service.GetAsync();

        Assert.Null(identity.Location);
        Assert.Equal("Unknown", identity.LocationText);
    }

    [Fact]
    public async Task GetAsync_RejectsUnsuccessfulProviderResponse()
    {
        const string response = """
            {
              "success": false,
              "message": "Rate limit exceeded"
            }
            """;
        var service = CreateService(HttpStatusCode.OK, response);

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.GetAsync());
    }

    private static PublicNetworkIdentityService CreateService(HttpStatusCode statusCode, string content)
    {
        var handler = new StubHttpMessageHandler(
            new HttpResponseMessage(statusCode)
            {
                Content = new StringContent(content, Encoding.UTF8, "application/json")
            });
        return new PublicNetworkIdentityService(new HttpClient(handler));
    }

    private sealed class StubHttpMessageHandler(HttpResponseMessage response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(response);
    }
}
