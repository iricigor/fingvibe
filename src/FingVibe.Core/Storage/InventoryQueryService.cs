using System.Diagnostics;
using System.Text;
using Microsoft.Data.Sqlite;
using SQLitePCL;

namespace FingVibe.Core.Storage;

public sealed record InventoryQueryResult(
    IReadOnlyList<string> Columns, IReadOnlyList<string?[]> Rows, TimeSpan Elapsed, string? Limit);

public sealed class InventoryQueryService(string databasePath)
{
    public const int MaximumRows = 1_000;
    public const int MaximumResultBytes = 1_048_576;
    public const int MaximumColumns = 64;
    public const int MaximumSqlBytes = 65_536;
    public const int MaximumValueBytes = 8_388_608;
    public static readonly TimeSpan ExecutionTimeout = TimeSpan.FromSeconds(5);

    private static readonly HashSet<string> Functions = new(StringComparer.OrdinalIgnoreCase)
    {
        "abs", "avg", "ceil", "ceiling", "char", "coalesce", "concat", "concat_ws", "count", "date",
        "datetime", "floor", "format", "glob", "group_concat", "hex", "if", "ifnull", "iif", "instr",
        "julianday", "length", "like", "likelihood", "likely", "lower", "ltrim", "max", "min", "nullif",
        "octet_length", "printf", "quote", "random", "randomblob", "replace", "round", "rtrim", "sign",
        "strftime", "string_agg", "substr", "substring", "sum", "time", "timediff", "total", "trim",
        "typeof", "unhex", "unicode", "unixepoch", "unlikely", "upper", "zeroblob", "sqlite_version",
        "row_number", "rank", "dense_rank", "percent_rank", "cume_dist", "ntile", "lag", "lead",
        "first_value", "last_value", "nth_value", "json", "json_array", "json_array_length",
        "json_extract", "json_group_array", "json_group_object", "json_object", "json_quote", "json_type",
        "json_valid", "json_each", "json_tree", "->", "->>"
    };
    private static readonly HashSet<string> ViewNames =
        InventoryReportingSchema.Views.Select(view => view.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
    private static readonly HashSet<string> StorageTables =
        InventoryReportingSchema.EntityTables.Append("scan_history").ToHashSet(StringComparer.OrdinalIgnoreCase);

    public Task<InventoryQueryResult> RunAsync(string sql, CancellationToken cancellationToken = default) =>
        Task.Run(() => Run(sql, cancellationToken), cancellationToken);

    private InventoryQueryResult Run(string sql, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sql);
        if (sql.Contains('\0') || Encoding.UTF8.GetByteCount(sql) > MaximumSqlBytes)
            throw new InvalidOperationException("SQL must be at most 64 KiB of UTF-8 text and contain no NUL characters.");
        var clock = Stopwatch.StartNew();
        using var deadline = new CancellationTokenSource(ExecutionTimeout);
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(databasePath))
            throw new FileNotFoundException("Saved inventory is unavailable. Save a scan or import before querying.", databasePath);
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 1
        }.ToString());
        connection.Open();
        var db = connection.Handle!;
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        using var registration = stop.Token.Register(() => raw.sqlite3_interrupt(db));
        raw.sqlite3_progress_handler(db, 1000,
            _ => stop.IsCancellationRequested || clock.Elapsed >= ExecutionTimeout ? 1 : 0, null);
        raw.sqlite3_busy_timeout(db, 100);
        raw.sqlite3_limit(db, raw.SQLITE_LIMIT_LENGTH, MaximumValueBytes);
        raw.sqlite3_limit(db, raw.SQLITE_LIMIT_SQL_LENGTH, MaximumSqlBytes);
        raw.sqlite3_limit(db, raw.SQLITE_LIMIT_COLUMN, MaximumColumns);
        raw.sqlite3_limit(db, raw.SQLITE_LIMIT_EXPR_DEPTH, 100);
        raw.sqlite3_limit(db, raw.SQLITE_LIMIT_COMPOUND_SELECT, 50);
        raw.sqlite3_limit(db, raw.SQLITE_LIMIT_VDBE_OP, 250_000);
        raw.sqlite3_limit(db, raw.SQLITE_LIMIT_ATTACHED, 0);

        void Check(int code)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (deadline.IsCancellationRequested || clock.Elapsed >= ExecutionTimeout)
                throw new TimeoutException("Query stopped: the 5-second execution limit was reached. No complete result is available.");
            if (code is not (raw.SQLITE_OK or raw.SQLITE_ROW or raw.SQLITE_DONE))
                throw new InvalidOperationException($"Query failed: {raw.sqlite3_errmsg(db).utf8_to_string()} (SQLite {code}).");
        }

        void ExecuteTrusted(string text)
        {
            var code = raw.sqlite3_prepare_v2(db, text, out var statement);
            using (statement)
            {
                Check(code);
                Check(raw.sqlite3_step(statement));
            }
        }

        try
        {
            ExecuteTrusted("PRAGMA temp_store=MEMORY");
            ExecuteTrusted("PRAGMA trusted_schema=OFF");
            foreach (var view in InventoryReportingSchema.Views)
                ExecuteTrusted($"CREATE TEMP VIEW {view.Name} AS {view.SelectSql}");
            ExecuteTrusted("PRAGMA query_only=ON");
            ExecuteTrusted("BEGIN");

            var code = raw.sqlite3_prepare_v2(db, "SELECT id,version,revision FROM main.inventory", out var metadata);
            using (metadata)
            {
                Check(code);
                var step = raw.sqlite3_step(metadata);
                Check(step);
                if (step != raw.SQLITE_ROW || raw.sqlite3_column_int(metadata, 0) != 1
                    || raw.sqlite3_column_int(metadata, 1) is not (2 or 3)
                    || !Guid.TryParse(raw.sqlite3_column_text(metadata, 2).utf8_to_string(), out var revision)
                    || revision == Guid.Empty)
                    throw new InvalidDataException("Saved inventory has an unsupported or incomplete format. Load it in FingVibe first.");
                step = raw.sqlite3_step(metadata);
                Check(step);
                if (step != raw.SQLITE_DONE) throw new InvalidDataException("Saved inventory has multiple revision records.");
            }
            // Validate every JSON entity in the same read snapshot, including queries whose projections
            // would otherwise let SQLite avoid evaluating malformed JSON (for example COUNT(*)).
            foreach (var table in InventoryReportingSchema.EntityTables)
            {
                code = raw.sqlite3_prepare_v2(db, $"SELECT id FROM main.{table} WHERE NOT json_valid(data) LIMIT 1", out var validation);
                using (validation)
                {
                    Check(code);
                    var step = raw.sqlite3_step(validation);
                    Check(step);
                    if (step == raw.SQLITE_ROW)
                        throw new InvalidDataException($"Saved inventory contains malformed JSON in {table}.");
                }
            }
            Check(raw.sqlite3_set_authorizer(db, (strdelegate_authorizer)Authorize, null));
            code = raw.sqlite3_prepare_v2(db, sql, out var query, out string tail);
            using (query)
            {
                Check(code);
                if (query.IsInvalid) throw new InvalidOperationException("Enter one SELECT statement.");
                while (!string.IsNullOrWhiteSpace(tail))
                {
                    code = raw.sqlite3_prepare_v2(db, tail, out var extra, out tail);
                    using (extra)
                    {
                        Check(code);
                        if (!extra.IsInvalid) throw new InvalidOperationException("Only one SQL statement is allowed per run.");
                    }
                }
                if (raw.sqlite3_stmt_readonly(query) != 1 || raw.sqlite3_column_count(query) == 0)
                    throw new InvalidOperationException("Only read-only queries returning columns are allowed.");
                var columns = Enumerable.Range(0, raw.sqlite3_column_count(query))
                    .Select(index => raw.sqlite3_column_name(query, index).utf8_to_string()).ToArray();
                var bytes = columns.Sum(Encoding.UTF8.GetByteCount);
                var rows = new List<string?[]>();
                while (true)
                {
                    var step = raw.sqlite3_step(query);
                    Check(step);
                    if (step == raw.SQLITE_DONE) return new(columns, rows, clock.Elapsed, null);
                    if (rows.Count == MaximumRows)
                        return new(columns, rows, clock.Elapsed, "Truncated: 1,000-row limit reached; more rows exist.");
                    var row = new string?[columns.Length];
                    var rowBytes = 0L;
                    for (var index = 0; index < row.Length; index++)
                    {
                        var type = raw.sqlite3_column_type(query, index);
                        var cellBytes = type == raw.SQLITE_NULL ? 4L
                            : (long)raw.sqlite3_column_bytes(query, index) * (type == raw.SQLITE_BLOB ? 2 : 1);
                        rowBytes += cellBytes;
                        if (bytes + rowBytes > MaximumResultBytes)
                            return new(columns, rows, clock.Elapsed, "Truncated: 1 MiB result limit reached; the next row was omitted.");
                        row[index] = type switch
                        {
                            raw.SQLITE_NULL => null,
                            raw.SQLITE_BLOB => Convert.ToHexString(raw.sqlite3_column_blob(query, index)),
                            raw.SQLITE_TEXT => Encoding.UTF8.GetString(raw.sqlite3_column_blob(query, index)),
                            _ => raw.sqlite3_column_text(query, index).utf8_to_string()
                        };
                    }
                    bytes += (int)rowBytes;
                    rows.Add(row);
                }
            }
        }
        finally
        {
            raw.sqlite3_set_authorizer(db, (strdelegate_authorizer)null!, null);
            raw.sqlite3_progress_handler(db, 0, null!, null);
            // Closing the non-pooled connection rolls back the read transaction and removes all TEMP views.
        }
    }

    private static int Authorize(object state, int action, string arg1, string arg2, string database, string source) =>
        action switch
        {
            raw.SQLITE_SELECT or raw.SQLITE_RECURSIVE => raw.SQLITE_OK,
            raw.SQLITE_FUNCTION when Functions.Contains(arg2) => raw.SQLITE_OK,
            raw.SQLITE_READ when database == "temp" && ViewNames.Contains(arg1) => raw.SQLITE_OK,
            raw.SQLITE_READ when database == "main" && StorageTables.Contains(arg1) => raw.SQLITE_OK,
            raw.SQLITE_READ when string.IsNullOrEmpty(database) => raw.SQLITE_OK,
            // JSON table-valued functions are read-only and have no filesystem capability.
            raw.SQLITE_READ when arg1 is "json_each" or "json_tree" => raw.SQLITE_OK,
            _ => raw.SQLITE_DENY
        };
}
