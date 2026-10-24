using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class PeopleRoomsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private readonly string _filePath;

    public PeopleRoomsStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public async Task<PeopleRoomsData> LoadAsync(CancellationToken cancellationToken = default)
    {
        PeopleRoomsDocument? document;
        try
        {
            await using var stream = new FileStream(
                _filePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            document = await JsonSerializer.DeserializeAsync<PeopleRoomsDocument>(
                stream,
                JsonOptions,
                cancellationToken).ConfigureAwait(false);
        }
        catch (FileNotFoundException)
        {
            return new PeopleRoomsData();
        }
        catch (DirectoryNotFoundException)
        {
            return new PeopleRoomsData();
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException("The saved people and rooms are invalid.", exception);
        }

        if (document?.People is null || document.Rooms is null || document.Assignments is null)
        {
            throw new InvalidDataException("The saved people and rooms are invalid.");
        }

        try
        {
            return new PeopleRoomsData(document.People, document.Rooms, document.Assignments);
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException)
        {
            throw new InvalidDataException("The saved people and rooms contain invalid details.", exception);
        }
    }

    public async Task SaveAsync(PeopleRoomsData data, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(data);
        var directory = Path.GetDirectoryName(_filePath)
            ?? throw new ArgumentException("The people and rooms path must include a directory.", nameof(_filePath));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_filePath)}.{Guid.NewGuid():N}.tmp");
        var document = new PeopleRoomsDocument(data.People, data.Rooms, data.Assignments);

        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await JsonSerializer.SerializeAsync(stream, document, JsonOptions, cancellationToken)
                    .ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            File.Move(temporaryPath, _filePath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private sealed record PeopleRoomsDocument(
        IReadOnlyList<ManagedPerson>? People,
        IReadOnlyList<ManagedRoom>? Rooms,
        IReadOnlyDictionary<string, DeviceAssignment>? Assignments);
}
