using System.Collections.Concurrent;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed class ScanResultBuffer : IProgress<ScanResult>
{
    private readonly ConcurrentQueue<ScanResult> _results = new();

    public void Report(ScanResult result)
    {
        if (result.Status == HostStatus.Alive)
        {
            _results.Enqueue(result);
        }
    }

    public IReadOnlyList<ScanResult> Results => _results.ToArray();
}
