using System.IO.Compression;
using System.Net;
using System.Net.NetworkInformation;
using System.Xml;
using System.Xml.Linq;
using FingVibe.Core.Models;

namespace FingVibe.Core.Import;

public sealed record FingDeviceRecord(int Row, string Mac, ImportedDeviceMetadata Metadata, string? Owner, string? Location);
public sealed record FingExport(IReadOnlyList<FingDeviceRecord> Devices, IReadOnlyList<string> Warnings, int DeviceRows);

public static class FingWorkbookReader
{
    private static readonly XNamespace Spreadsheet = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private static readonly XNamespace Relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const long MaximumXmlBytes = 32 * 1024 * 1024;
    private const int MaximumRows = 20_000;

    public static FingExport Read(Stream stream)
    {
        try
        {
            using var archive = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: true);
            if (archive.Entries.Count > 200 || archive.Entries.Sum(entry => entry.Length) > 64 * 1024 * 1024)
                throw new InvalidDataException("The workbook is too large. Export a smaller device inventory.");
            var workbook = ReadXml(archive, "xl/workbook.xml");
            var sheets = workbook.Descendants(Spreadsheet + "sheet")
                .Where(sheet => string.Equals((string?)sheet.Attribute("name"), "Devices", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (sheets.Length != 1)
                throw new InvalidDataException("Select a Fing Excel export containing exactly one Devices sheet.");
            var id = (string?)sheets[0].Attribute(Relationships + "id");
            var targets = ReadXml(archive, "xl/_rels/workbook.xml.rels").Root!.Elements()
                .Where(item => (string?)item.Attribute("Id") == id).ToArray();
            if (targets.Length != 1 || (string?)targets[0].Attribute("TargetMode") == "External")
                throw new InvalidDataException("The Devices worksheet reference is invalid.");
            var target = (string?)targets[0].Attribute("Target") ?? string.Empty;
            var path = target.StartsWith('/') ? target.TrimStart('/') : "xl/" + target;
            if (path.Contains("..", StringComparison.Ordinal) || path.Contains('\\') || !path.StartsWith("xl/worksheets/", StringComparison.Ordinal))
                throw new InvalidDataException("The Devices worksheet path is unsupported.");

            var strings = archive.GetEntry("xl/sharedStrings.xml") is null ? [] : ReadXml(archive, "xl/sharedStrings.xml")
                .Descendants(Spreadsheet + "si").Select(item => string.Concat(item.Descendants(Spreadsheet + "t").Select(text => text.Value))).ToArray();
            var rows = ReadXml(archive, path).Descendants(Spreadsheet + "sheetData").Elements(Spreadsheet + "row").ToArray();
            if (rows.Length > MaximumRows + 1)
                throw new InvalidDataException($"At most {MaximumRows:N0} device rows can be analyzed at once.");
            var warnings = new List<string>();
            var devices = new List<FingDeviceRecord>();
            var macRows = new Dictionary<string, List<int>>();
            Dictionary<string, string>? headers = null;
            var deviceRows = 0;
            foreach (var row in rows)
            {
                var rowNumber = (int?)row.Attribute("r") ?? throw new InvalidDataException("A worksheet row has no number.");
                var cells = new Dictionary<string, string>();
                foreach (var cell in row.Elements(Spreadsheet + "c"))
                {
                    var reference = (string?)cell.Attribute("r") ?? throw new InvalidDataException("A worksheet cell has no reference.");
                    var column = new string(reference.TakeWhile(char.IsAsciiLetter).ToArray());
                    if (column.Length == 0 || !cells.TryAdd(column, CellText(cell, strings)))
                        throw new InvalidDataException("The Devices sheet contains ambiguous cell references.");
                }
                if (headers is null)
                {
                    if (!cells.Values.Any(value => value.Trim().Equals("MAC", StringComparison.OrdinalIgnoreCase))) continue;
                    headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var (column, text) in cells)
                        if (!string.IsNullOrWhiteSpace(text) && !headers.TryAdd(text.Trim(), column))
                            throw new InvalidDataException($"The Devices sheet has duplicate '{text.Trim()}' column headers.");
                    continue;
                }
                if (cells.Values.All(string.IsNullOrWhiteSpace)) continue;
                deviceRows++;
                string? Get(string header) => headers.TryGetValue(header, out var column)
                    && cells.TryGetValue(column, out var text) && !string.IsNullOrWhiteSpace(text) ? text.Trim() : null;
                string mac;
                try
                {
                    mac = PeopleRoomsData.NormalizeMacAddress(Get("MAC") ?? string.Empty);
                    var bytes = PhysicalAddress.Parse(mac).GetAddressBytes();
                    if (bytes.All(value => value == 0) || (bytes[0] & 1) != 0)
                        throw new FormatException("A device must have a nonzero unicast MAC.");
                    if ((bytes[0] & 2) != 0)
                        warnings.Add($"Row {rowNumber}: private/randomized MAC; links survive only while this MAC remains the same.");
                }
                catch (FormatException)
                {
                    warnings.Add($"Row {rowNumber}: missing or invalid six-byte device MAC; record skipped.");
                    continue;
                }
                if (!macRows.TryGetValue(mac, out var occurrences))
                    macRows[mac] = occurrences = [];
                occurrences.Add(rowNumber);
                if (row.Elements(Spreadsheet + "c").Any(cell => cell.Element(Spreadsheet + "f") is not null))
                {
                    warnings.Add($"Row {rowNumber}: formulas are unsupported; the entire record is skipped.");
                    continue;
                }
                var address = Get("IP");
                if (address is not null && (!IPAddress.TryParse(address, out var parsed)
                    || parsed.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork))
                {
                    warnings.Add($"Row {rowNumber}: invalid IPv4 address skipped; the device's other fields remain eligible.");
                    address = null;
                }
                devices.Add(new(rowNumber, mac, new(Get("Name"), Get("Hostname"), Get("Type"), Get("Brand"),
                    Get("Family"), Get("Model"), Get("OS"), Get("OS Version"), address), Get("Owner"), Get("Location")));
            }
            if (headers is null) throw new InvalidDataException("The Devices sheet has no MAC header row.");
            var supported = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                "MAC", "IP", "Name", "Hostname", "Type", "Brand", "Family", "Model", "OS", "OS Version",
                "Owner", "Location", "State", "Group", "Alerted", "Last change", "First seen"
            };
            var unsupported = headers.Keys.Where(header => !supported.Contains(header)).ToArray();
            if (unsupported.Length > 0)
                warnings.Add($"Unsupported columns skipped: {string.Join(", ", unsupported)}.");
            var duplicates = macRows.Where(pair => pair.Value.Count > 1).ToArray();
            foreach (var duplicate in duplicates)
                warnings.Add($"Rows {string.Join(", ", duplicate.Value)}: duplicate MAC; all matching records skipped.");
            var duplicateMacs = duplicates.Select(pair => pair.Key).ToHashSet();
            warnings.Add("Fing State, Group, Alerted, timestamps, Network, and Log are not imported. Imported IPs are historical, not local observations.");
            return new(devices.Where(device => !duplicateMacs.Contains(device.Mac)).ToArray(), warnings, deviceRows);
        }
        catch (Exception exception) when (exception is XmlException or InvalidOperationException or OverflowException)
        {
            throw new InvalidDataException("The workbook's XML is invalid or unsupported. Export a new .xlsx file from Fing.", exception);
        }
    }

    private static XDocument ReadXml(ZipArchive archive, string path)
    {
        var entries = archive.Entries.Where(entry => entry.FullName == path).ToArray();
        if (entries.Length != 1 || entries[0].Length > MaximumXmlBytes)
            throw new InvalidDataException($"The workbook is missing or has an invalid {path} part.");
        using var stream = entries[0].Open();
        using var reader = XmlReader.Create(stream, new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = MaximumXmlBytes
        });
        return XDocument.Load(reader);
    }

    private static string CellText(XElement cell, string[] strings)
    {
        var value = cell.Element(Spreadsheet + "v")?.Value ?? string.Empty;
        return (string?)cell.Attribute("t") switch
        {
            "s" => int.TryParse(value, out var index) && index >= 0 && index < strings.Length
                ? strings[index] : throw new InvalidDataException("A workbook shared-string reference is invalid."),
            "inlineStr" => string.Concat(cell.Descendants(Spreadsheet + "t").Select(text => text.Value)),
            "e" => throw new InvalidDataException("The Devices sheet contains an Excel error cell. Correct it and export again."),
            _ => value
        };
    }
}
