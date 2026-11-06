using System.Collections;
using System.Collections.Immutable;

namespace FingVibe.Core.Models;

internal sealed class AppendedScanHistory : IReadOnlyList<DeviceScanObservation>
{
    private readonly ImmutableList<DeviceScanObservation> _items;
    internal IReadOnlyList<DeviceScanObservation> Previous { get; }
    internal DeviceScanObservation Added { get; }
    internal IReadOnlyList<DeviceScanObservation> Committed => _items;

    internal AppendedScanHistory(IReadOnlyList<DeviceScanObservation> previous, DeviceScanObservation added)
    {
        Previous = previous;
        Added = added;
        _items = (previous is AppendedScanHistory history
            ? history._items : previous.ToImmutableList()).Add(added);
    }

    public int Count => _items.Count;
    public DeviceScanObservation this[int index] => _items[index];
    public IEnumerator<DeviceScanObservation> GetEnumerator() => _items.GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}
