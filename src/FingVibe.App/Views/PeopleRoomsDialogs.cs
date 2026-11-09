using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

internal static class PeopleRoomsDialogs
{
    internal static async Task<ManagedPerson?> ShowPersonEditorAsync(
        XamlRoot root, ManagedPerson? existing, Func<PeopleRoomsData> current,
        Func<ManagedPerson, Task<bool>> save)
    {
        var nameBox = new TextBox { Header = "Full name", Text = existing?.Name ?? string.Empty };
        var shortNameBox = new TextBox { Header = "Short name", Text = existing?.ShortName ?? string.Empty, MaxLength = 12 };
        var notesBox = CreateNotesBox(existing?.Notes);
        var validation = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var iconPicker = PeopleRoomsIconPicker.Create(PeopleRoomsIcons.People, existing?.IconId);
        var dialog = CreateEditorDialog(root, existing is null ? "Add person" : "Edit person",
            nameBox, shortNameBox, notesBox, iconPicker, validation);
        ManagedPerson? saved = null;

        void Validate()
        {
            var message = PeopleRoomsPresentation.ValidatePerson(current(), existing, nameBox.Text, shortNameBox.Text);
            validation.Text = message ?? string.Empty;
            dialog.IsPrimaryButtonEnabled = message is null;
        }

        WireNameValidation(nameBox, shortNameBox, existing is not null, Validate);
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                Validate();
                if (!dialog.IsPrimaryButtonEnabled)
                {
                    args.Cancel = true;
                    return;
                }

                var candidate = new ManagedPerson(
                    existing?.Id ?? Guid.NewGuid(), nameBox.Text.Trim(), shortNameBox.Text.Trim(),
                    string.IsNullOrWhiteSpace(notesBox.Text) ? null : notesBox.Text.Trim(),
                    iconPicker.SelectedValue as string ?? throw new ArgumentException("Choose a person icon."));
                if (await save(candidate))
                {
                    saved = candidate;
                }
                else
                {
                    validation.Text = "The person could not be saved.";
                    args.Cancel = true;
                }
            }
            catch (ArgumentException exception)
            {
                validation.Text = exception.Message;
                args.Cancel = true;
            }
            finally
            {
                deferral.Complete();
            }
        };

        await dialog.ShowAsync();
        return saved;
    }

    internal static async Task<ManagedRoom?> ShowRoomEditorAsync(
        XamlRoot root, ManagedRoom? existing, Func<PeopleRoomsData> current,
        Func<ManagedRoom, Task<bool>> save)
    {
        var nameBox = new TextBox { Header = "Full name", Text = existing?.Name ?? string.Empty };
        var shortNameBox = new TextBox
        {
            Header = "Short name",
            Text = existing?.ShortName ?? string.Empty,
            MaxLength = 12,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe UI Emoji")
        };
        var notesBox = CreateNotesBox(existing?.Notes);
        var validation = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var iconPicker = PeopleRoomsIconPicker.Create(PeopleRoomsIcons.Rooms, existing?.IconId);
        var dialog = CreateEditorDialog(root, existing is null ? "Add room" : "Edit room",
            nameBox, shortNameBox, notesBox, iconPicker, validation);
        ManagedRoom? saved = null;

        void Validate()
        {
            var message = PeopleRoomsPresentation.ValidateRoom(current(), existing, nameBox.Text, shortNameBox.Text);
            validation.Text = message ?? string.Empty;
            dialog.IsPrimaryButtonEnabled = message is null;
        }

        WireNameValidation(nameBox, shortNameBox, existing is not null, Validate);
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                Validate();
                if (!dialog.IsPrimaryButtonEnabled)
                {
                    args.Cancel = true;
                    return;
                }

                var candidate = new ManagedRoom(
                    existing?.Id ?? Guid.NewGuid(), nameBox.Text.Trim(), shortNameBox.Text.Trim(),
                    string.IsNullOrWhiteSpace(notesBox.Text) ? null : notesBox.Text.Trim(),
                    iconPicker.SelectedValue as string ?? throw new ArgumentException("Choose a room icon."));
                if (await save(candidate))
                {
                    saved = candidate;
                }
                else
                {
                    validation.Text = "The room could not be saved.";
                    args.Cancel = true;
                }
            }
            catch (ArgumentException exception)
            {
                validation.Text = exception.Message;
                args.Cancel = true;
            }
            finally
            {
                deferral.Complete();
            }
        };

        await dialog.ShowAsync();
        return saved;
    }

    private static TextBox CreateNotesBox(string? notes) => new()
    {
        Header = "Notes (optional)",
        Text = notes ?? string.Empty,
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        MinHeight = 72
    };

    private static void WireNameValidation(TextBox nameBox, TextBox shortNameBox, bool editing, Action validate)
    {
        var manuallyEditedShortName = editing;
        var applyingSuggestion = false;
        nameBox.TextChanging += (_, _) =>
        {
            if (!manuallyEditedShortName && !editing)
            {
                applyingSuggestion = true;
                shortNameBox.Text = PeopleRoomsPresentation.SuggestShortName(nameBox.Text);
                applyingSuggestion = false;
            }

            validate();
        };
        shortNameBox.TextChanging += (_, _) =>
        {
            if (!applyingSuggestion)
            {
                manuallyEditedShortName = true;
            }

            validate();
        };
        validate();
    }

    private static ContentDialog CreateEditorDialog(
        XamlRoot root, string title, TextBox nameBox, TextBox shortNameBox, TextBox notesBox,
        ComboBox iconPicker, TextBlock validation)
    {
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(nameBox, "Full name");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(shortNameBox, "Short name");
        var content = new StackPanel { Spacing = 10, MinWidth = 320 };
        content.Children.Add(nameBox);
        content.Children.Add(shortNameBox);
        content.Children.Add(iconPicker);
        content.Children.Add(notesBox);
        content.Children.Add(validation);
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = content,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(dialog, "PeopleRoomsDialog");
        return dialog;
    }

    internal static async Task<bool> ConfirmDeleteAsync(XamlRoot root, string name, string category)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = $"Delete {category}?",
            Content = $"Delete {name}? Device assignments will be cleared; devices and scan history will remain.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(dialog, "PeopleRoomsDialog");
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    internal static async Task<ScanResultRow?> ChooseDeviceAsync(XamlRoot root, IReadOnlyList<ScanResultRow> available)
    {
        var picker = new ComboBox { MinWidth = 300 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picker, "Choose a device");
        foreach (var row in available)
        {
            picker.Items.Add(new ComboBoxItem
            {
                Content = $"{row.NameText} · {row.AddressText} · {row.StatusLabel}", Tag = row
            });
        }

        picker.SelectedIndex = 0;
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(picker);
        content.Children.Add(new TextBlock
        {
            Text = "Ordinary devices use their MAC address. Virtual-device assignments follow their inferred connections.",
            TextWrapping = TextWrapping.Wrap
        });
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = "Assign device",
            Content = content,
            PrimaryButtonText = "Assign",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(dialog, "PeopleRoomsDialog");
        return await dialog.ShowAsync() == ContentDialogResult.Primary
            ? (picker.SelectedItem as ComboBoxItem)?.Tag as ScanResultRow : null;
    }
}
