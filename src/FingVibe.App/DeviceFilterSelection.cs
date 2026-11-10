namespace FingVibe.App;

internal sealed class DeviceFilterSelection<T>
{
    private readonly T _missingValue;
    private readonly Func<T, bool> _isKnown;
    private readonly HashSet<T> _selected;
    private List<(T Value, string Label)> _choices = [];

    internal DeviceFilterSelection(T missingValue, IEqualityComparer<T>? comparer = null,
        Func<T, bool>? isKnown = null)
    {
        _missingValue = missingValue;
        _selected = new(comparer);
        _isKnown = isKnown ?? (value => !IsMissing(value));
    }

    internal IReadOnlySet<T> Selected => _selected;
    internal IReadOnlyList<(T Value, string Label)> Choices => _choices;
    internal bool AnyKnown { get; private set; }
    internal bool HasRestriction => AnyKnown || _selected.Count > 0;
    internal bool ShowAnyChoice => _choices.Count(choice => _isKnown(choice.Value)) >= 2;
    internal bool IsMissing(T value) => _selected.Comparer.Equals(value, _missingValue);

    internal bool SetChoices(IEnumerable<(T Value, string Label)> values)
    {
        var choices = values.DistinctBy(choice => choice.Value, _selected.Comparer).ToList();
        // A refresh must not silently discard a selected value that is temporarily unavailable.
        choices.AddRange(_choices.Where(choice => _selected.Contains(choice.Value)
            && !choices.Any(value => _selected.Comparer.Equals(value.Value, choice.Value))));
        if (_choices.SequenceEqual(choices)) return false;
        _choices = choices;
        return true;
    }

    internal bool SetSelected(T value, bool selected)
    {
        if (!selected) return _selected.Remove(value);
        var changed = AnyKnown;
        AnyKnown = false;
        return _selected.Add(value) || changed;
    }

    internal bool SetAnyKnown(bool selected)
    {
        var changed = AnyKnown != selected || selected && _selected.Count > 0;
        AnyKnown = selected;
        if (selected) _selected.Clear();
        return changed;
    }

    internal void SelectOnly(IEnumerable<T> values)
    {
        AnyKnown = false;
        _selected.Clear();
        _selected.UnionWith(values);
    }

    internal void Clear() => SelectOnly([]);
}
