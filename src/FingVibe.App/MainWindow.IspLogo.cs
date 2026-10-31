using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly IspLogoSession _ispLogoSession = new();
    private bool _networkIdentityClosed;

    private static string ReadLogoPublishableKey()
    {
        using var resource = typeof(MainWindow).Assembly.GetManifestResourceStream(
            "FingVibe.App.LogoDevPublishableKey")
            ?? throw new InvalidOperationException("The ISP logo build configuration is missing.");
        using var reader = new StreamReader(resource);
        return reader.ReadToEnd().Trim();
    }

    private void InitializeIspLogo()
    {
        Closed += (_, _) =>
        {
            _networkIdentityClosed = true;
            _ispLogoSession.Dispose();
        };
    }

    private void UpdateIspLogo(string? ispName)
    {
        if (!_ispLogoSession.Update(ispName, IsUiReview ? null : ReadLogoPublishableKey()))
        {
            return;
        }

        NetworkPage.ShowLogo(null);
        if (_ispLogoSession.Current is { } request)
        {
            _ = LoadIspLogoAsync(request);
        }
    }

    private async Task LoadIspLogoAsync(IspLogoSession.Request request)
    {
        try
        {
            // The Windows HTTP stack uses its normal HTTP cache; no application disk cache is created.
            using var client = new Windows.Web.Http.HttpClient();
            using var response = await client.GetAsync(request.Uri, Windows.Web.Http.HttpCompletionOption.ResponseHeadersRead)
                .AsTask(request.CancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                Trace.TraceWarning($"ISP logo request failed with HTTP {(int)response.StatusCode}.");
                return;
            }

            using var input = await response.Content.ReadAsInputStreamAsync().AsTask(request.CancellationToken);
            using var source = input.AsStreamForRead();
            using var content = new MemoryStream();
            var buffer = new byte[16 * 1024];
            int count;
            while ((count = await source.ReadAsync(buffer, request.CancellationToken)) != 0)
            {
                if (content.Length + count > 1024 * 1024)
                {
                    throw new InvalidDataException("The ISP logo exceeds the image size limit.");
                }

                content.Write(buffer, 0, count);
            }

            content.Position = 0;
            using var imageStream = content.AsRandomAccessStream();
            var bitmap = new BitmapImage { DecodePixelWidth = 128 };
            await bitmap.SetSourceAsync(imageStream).AsTask(request.CancellationToken);
            if (!_ispLogoSession.IsCurrent(request) || request.CancellationToken.IsCancellationRequested)
            {
                return;
            }

            NetworkPage.ShowLogo(bitmap);
        }
        catch (OperationCanceledException)
        {
            if (_ispLogoSession.IsCurrent(request))
            {
                Trace.TraceWarning("ISP logo loading timed out.");
            }
        }
        catch (Exception exception) when (exception is COMException or HttpRequestException or IOException or ArgumentException)
        {
            // Exception messages can contain the request URL and its publishable token.
            Trace.TraceWarning($"ISP logo loading failed ({exception.GetType().Name}, 0x{exception.HResult:X8}).");
        }
    }
}
