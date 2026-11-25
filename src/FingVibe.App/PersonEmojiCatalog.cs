using System.Text;

namespace FingVibe.App;

public static class PersonEmojiCatalog
{
    public static IReadOnlyList<string> Categories { get; } =
        Array.AsReadOnly(new[] { "All", "People", "Hair", "Professions", "Fantasy", "Existing icons" });

    public static IReadOnlyList<PeopleRoomsIconChoice> Choices { get; } = Create();

    public static bool IsAvailable(PeopleRoomsIconChoice choice, int windowsBuild) =>
        windowsBuild >= choice.MinimumWindowsBuild;

    public static IReadOnlyList<PeopleRoomsIconChoice> Filter(
        IEnumerable<PeopleRoomsIconChoice> choices, string? search, string category, bool includeVariants)
    {
        var terms = (search ?? string.Empty).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return choices.Where(choice =>
            (includeVariants || choice.IsPrimary)
            && (category == "All" || choice.Category == category)
            && terms.All(term =>
                $"{choice.Label} {choice.Variant} {choice.Category} {choice.Keywords}"
                    .Contains(term, StringComparison.OrdinalIgnoreCase))).ToArray();
    }

    private static IReadOnlyList<PeopleRoomsIconChoice> Create()
    {
        var choices = new List<PeopleRoomsIconChoice>();
        void Add(string label, string category, string person, string suffix = "",
            string? gender = null, bool primary = true, string keywords = "", int minimumWindowsBuild = 17763)
        {
            for (var tone = 1; tone <= 2; tone++)
            {
                var glyph = person + char.ConvertFromUtf32(0x1F3FA + tone) + suffix;
                var id = "emoji:" + string.Join("-", glyph.EnumerateRunes().Select(rune => rune.Value.ToString("x")));
                choices.Add(new(id, label, glyph, category,
                    $"{(gender is null ? "Variant" : gender)} {tone}",
                    primary && tone == 1, true, keywords, minimumWindowsBuild));
            }
        }

        void Gendered(string label, string category, string suffix, string keywords = "")
        {
            Add(label, category, "\U0001F468", suffix, "Man", keywords: keywords);
            Add(label, category, "\U0001F469", suffix, "Woman", primary: false, keywords: keywords);
        }

        foreach (var (label, glyph) in new[]
        {
            ("Baby", "\U0001F476"), ("Child", "\U0001F9D2"),
            ("Boy", "\U0001F466"), ("Girl", "\U0001F467"),
            ("Person", "\U0001F9D1"), ("Man", "\U0001F468"), ("Woman", "\U0001F469"),
            ("Older person", "\U0001F9D3"), ("Older man", "\U0001F474"), ("Older woman", "\U0001F475")
        })
            Add(label, "People", glyph);

        Add("Blond person", "Hair", "\U0001F471");
        Add("Blond man", "Hair", "\U0001F471", "\u200D\u2642\uFE0F");
        Add("Blond woman", "Hair", "\U0001F471", "\u200D\u2640\uFE0F");
        Add("Bearded person", "Hair", "\U0001F9D4");
        Add("Bearded man", "Hair", "\U0001F9D4", "\u200D\u2642\uFE0F", minimumWindowsBuild: 22000);
        Add("Bearded woman", "Hair", "\U0001F9D4", "\u200D\u2640\uFE0F", minimumWindowsBuild: 22000);
        foreach (var (hair, component) in new[]
        {
            ("Red hair", "\U0001F9B0"), ("Curly hair", "\U0001F9B1"),
            ("White hair", "\U0001F9B3"), ("Bald", "\U0001F9B2")
        })
        {
            Add($"{hair} person", "Hair", "\U0001F9D1", "\u200D" + component, minimumWindowsBuild: 19041);
            Add($"{hair} man", "Hair", "\U0001F468", "\u200D" + component);
            Add($"{hair} woman", "Hair", "\U0001F469", "\u200D" + component);
        }

        foreach (var (label, symbol, keywords) in new[]
        {
            ("Manager", "\U0001F4BC", "office worker business"),
            ("Health worker", "\u2695\uFE0F", "doctor nurse medical"),
            ("Student", "\U0001F393", "school graduate"),
            ("Teacher", "\U0001F3EB", "school professor"),
            ("Judge", "\u2696\uFE0F", "justice lawyer"),
            ("Farmer", "\U0001F33E", "gardener agriculture"),
            ("Cook", "\U0001F373", "chef kitchen"),
            ("Mechanic", "\U0001F527", "repair engineer"),
            ("Factory worker", "\U0001F3ED", "industrial"),
            ("Scientist", "\U0001F52C", "laboratory researcher"),
            ("Technologist", "\U0001F4BB", "developer programmer computer"),
            ("Singer", "\U0001F3A4", "musician rock star"),
            ("Artist", "\U0001F3A8", "painter"),
            ("Pilot", "\u2708\uFE0F", "aviator"),
            ("Astronaut", "\U0001F680", "space"),
            ("Firefighter", "\U0001F692", "fire rescue")
        })
            Gendered(label, "Professions", "\u200D" + symbol, keywords);

        foreach (var (label, glyph, category) in new[]
        {
            ("Police officer", "\U0001F46E", "Professions"),
            ("Detective", "\U0001F575", "Professions"),
            ("Guard", "\U0001F482", "Professions"),
            ("Construction worker", "\U0001F477", "Professions"),
            ("Person wearing a turban", "\U0001F473", "People"),
            ("Person in a tuxedo", "\U0001F935", "People"),
            ("Person with a veil", "\U0001F470", "People"),
            ("Mage", "\U0001F9D9", "Fantasy"),
            ("Elf", "\U0001F9DD", "Fantasy"),
            ("Vampire", "\U0001F9DB", "Fantasy"),
            ("Superhero", "\U0001F9B8", "Fantasy"),
            ("Supervillain", "\U0001F9B9", "Fantasy")
        })
        {
            var minimumBuild = label is "Person in a tuxedo" or "Person with a veil" ? 22000 : 17763;
            Add(label, category, glyph, "\u200D\u2642\uFE0F", "Man", minimumWindowsBuild: minimumBuild);
            Add(label, category, glyph, "\u200D\u2640\uFE0F", "Woman", primary: false, minimumWindowsBuild: minimumBuild);
        }

        Add("Woman with a headscarf", "People", "\U0001F9D5");
        Add("Person with a skullcap", "People", "\U0001F472");
        Add("Person with a crown", "People", "\U0001FAC5", minimumWindowsBuild: 22621);
        Add("Prince", "People", "\U0001F934");
        Add("Princess", "People", "\U0001F478");
        Add("Ninja", "Professions", "\U0001F977", minimumWindowsBuild: 22000);
        Add("Santa", "Fantasy", "\U0001F385");
        Add("Mrs. Claus", "Fantasy", "\U0001F936");
        Add("Mx Claus", "Fantasy", "\U0001F9D1", "\u200D\U0001F384", minimumWindowsBuild: 22000);
        return choices.AsReadOnly();
    }
}
