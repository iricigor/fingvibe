using System.Collections.ObjectModel;

namespace FingVibe.App;

internal static class InventoryPresentation
{
    internal static bool ShouldStartUsageRefresh<T>(
        T currentKey, T nextKey, bool force, bool explicitRefresh)
        where T : IEquatable<T> =>
        explicitRefresh || force || !currentKey.Equals(nextKey);

    internal static void Reconcile<T>(ObservableCollection<T> current, IReadOnlyList<T> desired)
    {
        for (var index = 0; index < desired.Count; index++)
        {
            var item = desired[index];
            var existing = current.IndexOf(item);
            if (existing < 0) current.Insert(index, item);
            else if (existing != index) current.Move(existing, index);
        }
        while (current.Count > desired.Count) current.RemoveAt(current.Count - 1);
    }
}
