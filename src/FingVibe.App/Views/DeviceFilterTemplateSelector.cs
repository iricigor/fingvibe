using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed record DeviceFilterChoice(string Category, string Label, Guid? Id = null,
    bool All = false, bool Unassigned = false)
{
    public bool IsActive => !All;
    public override string ToString() => Label;
}

public sealed class DeviceFilterTemplateSelector : DataTemplateSelector
{
    public DataTemplate? OptionTemplate { get; set; }
    public DataTemplate? SelectionTemplate { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => SelectionTemplate;

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) =>
        container is ComboBoxItem ? OptionTemplate : SelectionTemplate;
}
