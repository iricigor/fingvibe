#if NET8_0_OR_GREATER
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Threading;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;
using Element = FlaUI.Core.AutomationElements.AutomationElement;

namespace FingVibe.UiComparison
{
    public static class CaptureDriver
    {
        private static readonly Dictionary<string, Element> elements = new Dictionary<string, Element>();
        private static Element? root;
        private static IntPtr windowHandle;
        private static string? session;
        public static int AppProcessId { get; private set; }
        public static long Requests { get; private set; }

        public static string Request(string method, string endpoint, string? json)
        {
            Requests++;
            method = method.ToUpperInvariant();
            if (method == "GET" && endpoint == "/status") return Reply(new { ready = true });
            using var body = JsonDocument.Parse(string.IsNullOrEmpty(json) ? "{}" : json);
            if (method == "POST" && endpoint == "/session")
            {
                if (session is not null) throw new InvalidOperationException("A capture session is already active.");
                var path = body.RootElement.GetProperty("desiredCapabilities").GetProperty("app").GetString()
                    ?? throw new InvalidOperationException("Capture app path is required.");
                var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })
                    ?? throw new InvalidOperationException("Capture app did not start.");
                AppProcessId = process.Id;
                var clock = Stopwatch.StartNew();
                while (true)
                {
                    process.Refresh();
                    if (process.HasExited)
                        throw new InvalidOperationException($"Capture app exited with code {process.ExitCode}.");
                    if (process.MainWindowHandle != IntPtr.Zero) break;
                    if (clock.ElapsedMilliseconds >= 30000) throw new TimeoutException("Capture app has no window.");
                    Thread.Sleep(100);
                }
                windowHandle = process.MainWindowHandle;
                root = AutomationElement.Automation.FromHandle(windowHandle);
                session = Guid.NewGuid().ToString("N");
                return JsonSerializer.Serialize(new { sessionId = session, status = 0, value = new { } });
            }
            if (session is null || root is null || !endpoint.StartsWith($"/session/{session}", StringComparison.Ordinal))
                throw new InvalidOperationException($"Unknown capture session endpoint '{endpoint}'.");
            var relative = endpoint.Substring($"/session/{session}".Length);
            if (method == "DELETE" && relative.Length == 0)
            {
                elements.Clear();
                root = null;
                windowHandle = IntPtr.Zero;
                session = null;
                return Reply(null);
            }
            if (method == "GET" && relative == "/window_handle")
                return Reply(windowHandle.ToInt64().ToString("x", CultureInfo.InvariantCulture));
            if (method == "POST" && relative == "/element")
            {
                var strategy = body.RootElement.GetProperty("using").GetString();
                var value = body.RootElement.GetProperty("value").GetString()
                    ?? throw new InvalidOperationException("Element locator is required.");
                Element? element = strategy switch
                {
                    "name" => root.FindFirstDescendant(cf => cf.ByName(value)),
                    "xpath" => root.FindFirstByXPath(value),
                    "accessibility id" => root.FindFirstDescendant(cf => cf.ByAutomationId(value)),
                    _ => throw new NotSupportedException($"Unsupported capture locator '{strategy}'.")
                };
                if (element is null) throw new InvalidOperationException($"No capture element matches '{value}'.");
                var id = Guid.NewGuid().ToString("N");
                elements.Add(id, element);
                return Reply(new Dictionary<string, string> { ["ELEMENT"] = id });
            }
            var parts = relative.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 3 || parts[0] != "element" || !elements.TryGetValue(parts[1], out var target))
                throw new NotSupportedException($"Unsupported capture endpoint '{endpoint}'.");
            if (method == "GET")
            {
                return parts[2] switch
                {
                    "enabled" => Reply(target.IsEnabled),
                    "displayed" => Reply(!target.IsOffscreen && target.BoundingRectangle.Width > 0 &&
                        target.BoundingRectangle.Height > 0),
                    "selected" => Reply(target.Patterns.SelectionItem.Pattern.IsSelected.Value),
                    "text" => Reply(target.Patterns.Value.IsSupported ? target.Patterns.Value.Pattern.Value.Value : target.Name),
                    _ => throw new NotSupportedException($"Unsupported capture read '{parts[2]}'.")
                };
            }
            if (method != "POST") throw new NotSupportedException($"Unsupported capture method '{method}'.");
            switch (parts[2])
            {
                case "click":
                    target.Click();
                    break;
                case "clear":
                    target.Focus();
                    Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
                    Keyboard.Type(VirtualKeyShort.DELETE);
                    break;
                case "value":
                    target.Focus();
                    foreach (var item in body.RootElement.GetProperty("value").EnumerateArray())
                    {
                        foreach (var character in item.GetString() ?? throw new InvalidOperationException("Keys must be text."))
                        {
                            if (character == '\uE010') Keyboard.Type(VirtualKeyShort.END);
                            else if (character == '\uE007') Keyboard.Type(VirtualKeyShort.RETURN);
                            else if (character >= '\uE000' && character <= '\uE05D')
                                throw new NotSupportedException($"Unsupported WebDriver key U+{(int)character:X4}.");
                            else Keyboard.Type(character);
                        }
                    }
                    break;
                default:
                    throw new NotSupportedException($"Unsupported capture write '{parts[2]}'.");
            }
            return Reply(null);
        }

        private static string Reply(object? value) => JsonSerializer.Serialize(new { status = 0, value });
    }
}
#endif
