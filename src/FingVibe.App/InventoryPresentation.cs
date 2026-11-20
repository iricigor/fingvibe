using System.Collections.ObjectModel;

namespace FingVibe.App;

internal static class InventoryPresentation
{
    internal static bool ShouldStartUsageRefresh<T>(
        T currentKey, T nextKey, bool force, bool explicitRefresh)
    {
        // Automatic force requests refresh timezone state; only an explicit user retry bypasses the same key.
        _ = force;
        return explicitRefresh || !EqualityComparer<T>.Default.Equals(currentKey, nextKey);
    }

    internal static void Reconcile<T>(
        ObservableCollection<T> current, IReadOnlyList<T> desired, Action<T, int>? present = null)
    {
        if (HasSameSequence(current, desired))
        {
            for (var index = 0; index < desired.Count; index++)
                present?.Invoke(desired[index], index);
            return;
        }

        ReconcileChanged(current, desired, present);
    }

    internal static void ReconcileChanged<T>(
        ObservableCollection<T> current, IReadOnlyList<T> desired, Action<T, int>? present = null)
    {
        for (var index = 0; index < desired.Count; index++)
        {
            var item = desired[index];
            present?.Invoke(item, index);
            var existing = current.IndexOf(item);
            if (existing < 0) current.Insert(index, item);
            else if (existing != index) current.Move(existing, index);
        }
        while (current.Count > desired.Count) current.RemoveAt(current.Count - 1);
    }

    internal static bool HasSameSequence<T>(IReadOnlyList<T> current, IReadOnlyList<T> desired)
    {
        if (current.Count != desired.Count) return false;
        for (var index = 0; index < desired.Count; index++)
        {
            if (!EqualityComparer<T>.Default.Equals(current[index], desired[index])) return false;
        }
        return true;
    }
}
