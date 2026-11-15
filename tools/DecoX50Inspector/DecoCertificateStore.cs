using System.IO;
using System.Text;

namespace DecoX50Inspector;

public sealed class DecoCertificateStore(string path)
{
    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe-DecoX50Inspector", "approved-certificate.sha256");

    public static string PathFor(DecoRouterPolicy router) => router.Ip == DecoRouterPolicy.DefaultIp
        ? DefaultPath
        : Path.Combine(Path.GetDirectoryName(DefaultPath)!, $"approved-certificate-{router.Ip}.sha256");

    public string? Load()
    {
        try
        {
            using var stream = File.OpenRead(path);
            if (stream.Length > 256)
                throw new InvalidDataException("The saved certificate fingerprint exceeds its 256-byte limit.");
            using var reader = new StreamReader(stream);
            return Validate(reader.ReadToEnd().Trim());
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    public void Save(string fingerprint)
    {
        fingerprint = Validate(fingerprint);
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath)
            ?? throw new ArgumentException("The certificate settings path requires a directory.", nameof(path));
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(Encoding.ASCII.GetBytes(fingerprint + "\n"));
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, fullPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static string Validate(string fingerprint)
    {
        if (fingerprint.Length != 64 || fingerprint.Any(character => !char.IsAsciiHexDigit(character)))
            throw new InvalidDataException("The saved certificate fingerprint must contain exactly 64 hexadecimal characters.");
        return fingerprint.ToUpperInvariant();
    }
}
