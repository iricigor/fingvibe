namespace FingVibe.App;

public static class RoomIconCatalog
{
    public const string FontFamily = "ms-appx:///Assets/Fonts/FontAwesomeFree-Solid.ttf#Font Awesome 6 Free";

    public static IReadOnlyList<string> Categories { get; } = Array.AsReadOnly(new[]
    {
        "All", "Living", "Bedrooms", "Bathroom", "Kitchen", "Work", "Hobbies",
        "Utility", "Outdoor", "Equipment", "Existing icons"
    });

    public static IReadOnlyList<PeopleRoomsIconChoice> Choices { get; } = Array.AsReadOnly(new[]
    {
        Choice("house", "House", "\uF015", "Living", "Whole home"),
        Choice("building", "Building", "\uF1AD", "Living", "Apartment"),
        Choice("couch", "Couch", "\uF4B8", "Living", "Living room", "lounge"),
        Choice("chair", "Chair", "\uF6C0", "Living", "Sitting room"),
        Choice("tv", "TV", "\uF26C", "Living", "TV room", "television cinema"),
        Choice("rug", "Rug", "\uE569", "Living", "Lounge"),
        Choice("bed", "Bed", "\uF236", "Bedrooms", "Master bedroom", "sleep primary bedroom"),
        Choice("child", "Child", "\uF1AE", "Bedrooms", "Children's room", "kids"),
        Choice("baby", "Baby", "\uF77C", "Bedrooms", "Nursery"),
        Choice("baby-carriage", "Baby carriage", "\uF77D", "Bedrooms", "Baby's room", "nursery"),
        Choice("puzzle-piece", "Puzzle piece", "\uF12E", "Hobbies", "Playroom", "kids toys"),
        Choice("door-open", "Open door", "\uF52B", "Living", "Corridor", "hall hallway"),
        Choice("door-closed", "Closed door", "\uF52A", "Living", "Entrance hall", "hallway"),
        Choice("stairs", "Stairs", "\uE289", "Living", "Stairwell", "landing"),
        Choice("elevator", "Elevator", "\uE16D", "Living", "Lift lobby"),
        Choice("key", "Key", "\uF084", "Living", "Entryway", "entrance"),
        Choice("bath", "Bath", "\uF2CD", "Bathroom", "Bathroom", "bathtub"),
        Choice("shower", "Shower", "\uF2CC", "Bathroom", "Shower room"),
        Choice("toilet", "Toilet", "\uF7D8", "Bathroom", "WC", "restroom"),
        Choice("sink", "Sink", "\uE06D", "Bathroom", "Washroom"),
        Choice("kitchen-set", "Kitchen set", "\uE51A", "Kitchen", "Kitchen", "cooking"),
        Choice("utensils", "Utensils", "\uF2E7", "Kitchen", "Dining room"),
        Choice("mug-hot", "Hot mug", "\uF7B6", "Kitchen", "Breakfast nook", "coffee"),
        Choice("wine-glass", "Wine glass", "\uF4E3", "Kitchen", "Home bar"),
        Choice("laptop", "Laptop", "\uF109", "Work", "Home office"),
        Choice("desktop", "Desktop", "\uF390", "Work", "Computer room"),
        Choice("briefcase", "Briefcase", "\uF0B1", "Work", "Office"),
        Choice("book", "Book", "\uF02D", "Work", "Study / library", "reading"),
        Choice("gamepad", "Gamepad", "\uF11B", "Hobbies", "Gaming room"),
        Choice("palette", "Palette", "\uF53F", "Hobbies", "Art studio"),
        Choice("music", "Music", "\uF001", "Hobbies", "Music room"),
        Choice("dumbbell", "Dumbbell", "\uF44B", "Hobbies", "Home gym", "fitness"),
        Choice("broom", "Broom", "\uF51A", "Utility", "Cleaning cupboard"),
        Choice("jug-detergent", "Detergent", "\uE519", "Utility", "Laundry room", "washing"),
        Choice("shirt", "Shirt", "\uF553", "Utility", "Dressing room", "wardrobe"),
        Choice("box", "Box", "\uF466", "Utility", "Storage room"),
        Choice("boxes-stacked", "Stacked boxes", "\uF468", "Utility", "Storeroom"),
        Choice("warehouse", "Warehouse", "\uF494", "Utility", "Storage building"),
        Choice("car", "Car", "\uF1B9", "Utility", "Garage"),
        Choice("screwdriver-wrench", "Tools", "\uF7D9", "Utility", "Workshop", "DIY repair"),
        Choice("tree", "Tree", "\uF1BB", "Outdoor", "Garden"),
        Choice("leaf", "Leaf", "\uF06C", "Outdoor", "Sunroom"),
        Choice("seedling", "Seedling", "\uF4D8", "Outdoor", "Greenhouse"),
        Choice("water-ladder", "Pool ladder", "\uF5C5", "Outdoor", "Pool area", "swimming"),
        Choice("server", "Server", "\uF233", "Equipment", "Server room"),
        Choice("network-wired", "Network", "\uF6FF", "Equipment", "Network closet"),
        Choice("plug", "Plug", "\uF1E6", "Equipment", "Utility room"),
        Choice("bolt", "Lightning", "\uF0E7", "Equipment", "Electrical room"),
        Choice("fire-extinguisher", "Extinguisher", "\uF134", "Equipment", "Safety equipment")
    });

    private static PeopleRoomsIconChoice Choice(
        string asset, string label, string glyph, string category, string suggestedRoom, string keywords = "") =>
        new("fa-solid:" + asset, label, glyph, category, Keywords: keywords,
            SuggestedRoom: suggestedRoom, IsFontAwesome: true);
}
