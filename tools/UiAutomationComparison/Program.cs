using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;

internal static class Program
{
    private static UIA3Automation? automation;
    private static AutomationElement? root;
    private static string phase = "attach";

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine("Usage: UiAutomationComparison <window-handle> <result-directory>");
            return 2;
        }

        var clock = Stopwatch.StartNew();
        var directory = args[1];
        Directory.CreateDirectory(directory);
        Exception? failure = null;
        double attachMilliseconds = 0;
        double navigationMilliseconds = 0;
        double assertionMilliseconds = 0;
        try
        {
            automation = new UIA3Automation();
            root = automation.FromHandle(new IntPtr(long.Parse(args[0], CultureInfo.InvariantCulture)));
            attachMilliseconds = clock.Elapsed.TotalMilliseconds;
            phase = "navigation";
            var navigation = Stopwatch.StartNew();
            try { OpenHistory(); }
            finally { navigationMilliseconds = navigation.Elapsed.TotalMilliseconds; }
            phase = "reachability";
            var assertion = Stopwatch.StartNew();
            try { AssertRows(); }
            finally { assertionMilliseconds = assertion.Elapsed.TotalMilliseconds; }
        }
        catch (Exception exception)
        {
            failure = exception;
            Console.Error.WriteLine($"{phase}: {exception}");
            try
            {
                if (root is not null)
                {
                    var tree = root.FindAllDescendants().Select(element => new
                    {
                        id = element.AutomationId,
                        name = element.Name,
                        type = element.ControlType.ToString(),
                        offscreen = element.IsOffscreen,
                        bounds = element.BoundingRectangle.ToString()
                    });
                    File.WriteAllText(Path.Combine(directory, "flaui-tree.json"),
                        JsonSerializer.Serialize(tree, new JsonSerializerOptions { WriteIndented = true }));
                }
            }
            catch (Exception diagnosticError)
            {
                Console.Error.WriteLine($"Tree diagnostics also failed: {diagnosticError}");
            }
        }
        finally
        {
            automation?.Dispose();
            File.WriteAllText(Path.Combine(directory, "flaui-result.json"), JsonSerializer.Serialize(new
            {
                success = failure is null,
                phase,
                error = failure?.ToString(),
                attachMilliseconds,
                navigationMilliseconds,
                assertionMilliseconds,
                workerMilliseconds = clock.Elapsed.TotalMilliseconds
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
        return failure is null ? 0 : 1;
    }

    private static AutomationElement Find(string value, bool byName = false, bool optional = false)
    {
        var element = root!.FindFirstDescendant(cf => byName ? cf.ByName(value) : cf.ByAutomationId(value));
        if (element is null && !optional)
            throw new InvalidOperationException($"Missing scan-history control '{value}'.");
        return element!;
    }

    private static void Wait(Func<bool> condition, string description, int milliseconds = 30000)
    {
        var clock = Stopwatch.StartNew();
        do
        {
            if (condition()) return;
            Thread.Sleep(100);
        } while (clock.ElapsedMilliseconds < milliseconds);
        throw new TimeoutException($"Timed out waiting for {description}.");
    }

    private static bool Visible(AutomationElement? element) =>
        element is not null && !element.IsOffscreen &&
        element.BoundingRectangle.Width > 0 && element.BoundingRectangle.Height > 0;

    private static bool Within(AutomationElement element, params AutomationElement[] containers)
    {
        if (!Visible(element) || containers.Any(container => !Visible(container))) return false;
        var bounds = element.BoundingRectangle;
        return containers.All(container =>
        {
            var area = container.BoundingRectangle;
            return bounds.Left >= area.Left && bounds.Right <= area.Right &&
                bounds.Top >= area.Top && bounds.Bottom <= area.Bottom;
        });
    }

    private static AutomationElement Show(string id)
    {
        var target = Find(id);
        var hasScrollItem = target.Patterns.ScrollItem.IsSupported;
        if (!target.Properties.IsKeyboardFocusable.Value && !hasScrollItem)
            throw new InvalidOperationException(
                $"Benchmark target '{id}' needs the baseline geometry fallback; this pilot does not implement it.");
        if (target.Properties.IsKeyboardFocusable.Value) target.Focus();
        if (hasScrollItem) target.Patterns.ScrollItem.Pattern.ScrollIntoView();
        AutomationElement? current = null;
        Wait(() =>
        {
            current = Find(id, optional: true);
            return current is not null && Within(current, Find("DeviceDetailsScroll"), root!);
        }, $"visible history section '{id}'", 10000);
        return current!;
    }

    private static void OpenHistory()
    {
        Wait(() => Find("DevicesNavItem", optional: true) is not null, "device navigation");
        Thread.Sleep(500);
        Find("DevicesNavItem").Patterns.SelectionItem.Pattern.Select();
        Wait(() => Visible(Find("ResultsList", optional: true)), "device list");
        var search = Find("Search devices", byName: true).Patterns.Value.Pattern;
        if (search.Value.Value != "History normal")
        {
            search.SetValue("History normal");
            Thread.Sleep(300);
        }
        var rows = Find("ResultsList").FindAllChildren(cf => cf.ByControlType(ControlType.ListItem));
        if (rows.Length != 1)
            throw new InvalidOperationException($"Expected one device matching 'History normal', got {rows.Length}.");
        var cell = rows[0].FindFirstDescendant(cf => cf.ByAutomationId("DeviceNameText"));
        if (!Visible(rows[0]) || cell is null || cell.Name != "History normal")
            throw new InvalidOperationException("The visible history row does not match 'History normal'.");
        rows[0].Focus();
        SendKeys.SendWait("{ENTER}");
        Wait(() => Visible(Find("DeviceDetailsScroll", optional: true)), "details for History normal");
        foreach (var id in new[] { "DeviceScanHistoryExpander", "DeviceImportedMetadata" })
        {
            if (Find(id).Patterns.ExpandCollapse.Pattern.ExpandCollapseState.Value != ExpandCollapseState.Collapsed)
                throw new InvalidOperationException($"{id} must start collapsed on opening a device.");
        }
        Show("DeviceScanHistoryExpander").Focus();
        SendKeys.SendWait(" ");
        Wait(() => Find("DeviceScanHistoryExpander").Patterns.ExpandCollapse.Pattern
            .ExpandCollapseState.Value == ExpandCollapseState.Expanded,
            "keyboard expansion of completed observations");
    }

    private static DateTimeOffset LocalTime(int index) =>
        DateTimeOffset.Parse($"2026-11-01T12:0{index}:00+00:00", CultureInfo.InvariantCulture).ToLocalTime();

    private static void AssertRows()
    {
        const int count = 2;
        if (Find("DeviceScanHistoryCount").Name != $"{count} completed scan observations")
            throw new InvalidOperationException($"Expected {count} individual completed scans.");
        var list = Show("DeviceScanHistoryList");
        var scroll = list.Patterns.Scroll.Pattern;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var observations = new List<object>();
        try
        {
            foreach (var percent in new[] { 0, 50, 100 })
            {
                if (scroll.VerticallyScrollable.Value) scroll.SetScrollPercent(-1, percent);
                Thread.Sleep(100);
                var times = new List<string>();
                foreach (var item in list.FindAllDescendants(cf => cf.ByControlType(ControlType.DataItem)))
                {
                    var within = Within(item, list, root!);
                    observations.Add(new
                    {
                        percent, item.Name, item.IsOffscreen, within,
                        bounds = item.BoundingRectangle.ToString(),
                        viewport = list.BoundingRectangle.ToString()
                    });
                    if (!within) continue;
                    var texts = item.FindAllDescendants(cf => cf.ByControlType(ControlType.Text))
                        .Select(element => element.Name).ToArray();
                    if (texts.Length == 0) continue;
                    if (texts.Length != 3)
                        throw new InvalidOperationException($"Each scan row must expose date, local time and state: {string.Join(", ", texts)}.");
                    var time = $"{texts[0]} {texts[1]}";
                    var matching = Enumerable.Range(0, count)
                        .Where(index => LocalTime(index).ToString("yyyy-MM-dd HH:mm:ss") == time).ToArray();
                    if (matching.Length != 1)
                        throw new InvalidOperationException($"Unexpected local scan timestamp '{time}'.");
                    if (texts[2] != "Present")
                        throw new InvalidOperationException($"Incorrect scan observation: {string.Join(", ", texts)}.");
                    var label = $"{LocalTime(matching[0]):yyyy-MM-dd HH:mm:ss zzz}; Observed present";
                    if (item.Name != label)
                        throw new InvalidOperationException("Scan row lacks an accessible full timestamp with UTC offset and observed state.");
                    seen.Add(time);
                    times.Add(time);
                }
                if (!times.SequenceEqual(times.OrderByDescending(time => time, StringComparer.Ordinal)))
                    throw new InvalidOperationException($"Scan rows are not newest first: {string.Join(", ", times)}.");
            }
            if (seen.Count != count)
                throw new InvalidOperationException($"Not all {count} scans are reachable in the native history list.");
            for (var index = 0; index < count; index++)
            {
                if (!seen.Contains(LocalTime(index).ToString("yyyy-MM-dd HH:mm:ss")))
                    throw new InvalidOperationException($"Scan {index} is missing from history.");
            }
            if (scroll.VerticallyScrollable.Value) scroll.SetScrollPercent(-1, 0);
        }
        finally
        {
            Console.WriteLine(JsonSerializer.Serialize(new { observations, seen }));
        }
    }
}
