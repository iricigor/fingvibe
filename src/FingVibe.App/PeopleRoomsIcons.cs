using System.Diagnostics;

namespace FingVibe.App;

public sealed record PeopleRoomsIconChoice(
    string Id, string Label, string Glyph, string Category = "Existing icons",
    string? Variant = null, bool IsPrimary = true, bool IsEmoji = false, string Keywords = "",
    int MinimumWindowsBuild = 0, string? SuggestedRoom = null, bool IsFontAwesome = false)
{
    public string AccessibleName => SuggestedRoom is not null ? $"{Label}, suggested room: {SuggestedRoom}"
        : Variant is null ? Label : $"{Label}, {Variant}";
}

public static class PeopleRoomsIcons
{
    public static IReadOnlyList<PeopleRoomsIconChoice> People { get; } = Array.AsReadOnly(new[]
    {
        new PeopleRoomsIconChoice("person", "Person", "\uE77B"),
        new PeopleRoomsIconChoice("profile", "Profile", "\uE8D4"),
        new PeopleRoomsIconChoice("person-filled", "Person (filled)", "\uEA8C")
    }.Concat(PersonEmojiCatalog.Choices).ToArray());

    public static IReadOnlyList<PeopleRoomsIconChoice> Rooms { get; } = Array.AsReadOnly(new[]
    {
        new PeopleRoomsIconChoice("room", "Room", "\uE707"),
        new PeopleRoomsIconChoice("home", "Home", "\uE80F"),
        new PeopleRoomsIconChoice("bedroom", "Bedroom (sleep)", "\uF4BD"),
        new PeopleRoomsIconChoice("kitchen", "Kitchen (cup)", "\uEC32"),
        new PeopleRoomsIconChoice("living-room", "Living room (TV)", "\uE7F4"),
        new PeopleRoomsIconChoice("office", "Office (briefcase)", "\uE821"),
        new PeopleRoomsIconChoice("garage", "Garage (car)", "\uE804"),
        new PeopleRoomsIconChoice("garden", "Garden (leaf)", "\uE8BE")
    }.Concat(RoomIconCatalog.Choices).ToArray());

    public static IReadOnlyList<PeopleRoomsIconChoice> Filter(
        IEnumerable<PeopleRoomsIconChoice> choices, string? search, string category, bool includeVariants = true)
    {
        var terms = (search ?? string.Empty).Split((char[]?)null,
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return choices.Where(choice =>
            (includeVariants || choice.IsPrimary)
            && (category == "All" || choice.Category == category)
            && terms.All(term =>
                $"{choice.Label} {choice.Variant} {choice.SuggestedRoom} {choice.Category} {choice.Keywords}"
                    .Contains(term, StringComparison.OrdinalIgnoreCase))).ToArray();
    }

    public static PeopleRoomsIconChoice Resolve(IReadOnlyList<PeopleRoomsIconChoice> choices, string? id)
    {
        ArgumentNullException.ThrowIfNull(choices);
        if (choices.Count == 0)
        {
            throw new ArgumentException("An icon palette must contain a default.", nameof(choices));
        }

        if (id is null)
        {
            return choices[0];
        }

        var choice = choices.FirstOrDefault(item => item.Id == id);
        if (choice is not null)
        {
            return choice;
        }

        // Preserve newer saved IDs while rendering a compatible generic icon.
        Trace.TraceWarning("Unavailable People/Rooms icon ID '{0}'; displaying the generic icon.", id);
        return choices[0];
    }
}
