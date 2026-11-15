import Foundation
import SQLite3

/// A single search hit or recent entry returned by `ScreenMemoryDatabase`.
public struct ScreenMemorySearchResult: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let timestamp: Date
    public let appPackageName: String
    public let extractedText: String
    public let highlightedSnippet: String
    public let thumbnailURL: URL
}

/// Thread-safe on-device SQLite3 + FTS5 database for Semantic Screen Memory.
public final class ScreenMemoryDatabase: @unchecked Sendable {
    public static let shared = ScreenMemoryDatabase()

    public static let defaultRetentionDays: Int = 7
    public static let defaultMaxThumbnailBytes: Int64 = 250 * 1024 * 1024 // 250 MB

    public let baseDirectoryURL: URL
    public let thumbnailsDirectoryURL: URL
    public let databaseURL: URL

    private let queue = DispatchQueue(label: "com.andonmac.screenmemory.db", qos: .utility)
    private var db: OpaquePointer?

    public static var defaultBaseDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("AndOnMac", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
    }

    public init(baseDirectoryURL: URL = ScreenMemoryDatabase.defaultBaseDirectoryURL) {
        self.baseDirectoryURL = baseDirectoryURL
        self.thumbnailsDirectoryURL = baseDirectoryURL.appendingPathComponent("thumbnails", isDirectory: true)
        self.databaseURL = baseDirectoryURL.appendingPathComponent("memory.sqlite", isDirectory: false)

        queue.sync {
            openAndMigrateLocked()
        }
    }

    deinit {
        queue.sync {
            if let db {
                sqlite3_close(db)
            }
            self.db = nil
        }
    }

    /// Inserts a new screen memory snapshot and returns its row ID.
    @discardableResult
    public func insertSnapshot(
        timestamp: Date = Date(),
        appPackageName: String,
        extractedText: String,
        thumbnailFilename: String,
        frameHash: UInt64
    ) -> Int64? {
        queue.sync {
            guard let db else { return nil }
            let sql = """
            INSERT INTO snapshots (timestamp, app_package_name, extracted_text, thumbnail_path, frame_hash)
            VALUES (?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, appPackageName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, extractedText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, thumbnailFilename, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, Int64(bitPattern: frameHash))

            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Performs real-time FTS5 search with `snippet()` highlighting, or returns recent snapshots when `query` is empty.
    public func search(query: String, limit: Int = 40) -> [ScreenMemorySearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue.sync {
            guard let db else { return [] }
            if trimmed.isEmpty {
                return fetchRecentLocked(db: db, limit: min(limit, 25))
            }
            guard let ftsQuery = Self.buildSafeFTS5Query(from: trimmed) else {
                return []
            }

            let sql = """
            SELECT s.id, s.timestamp, s.app_package_name, s.extracted_text,
                   snippet(snapshots_fts, 0, '«', '»', '…', 14), s.thumbnail_path
            FROM snapshots_fts
            JOIN snapshots s ON s.id = snapshots_fts.rowid
            WHERE snapshots_fts MATCH ?
            ORDER BY s.timestamp DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [ScreenMemorySearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_double(stmt, 1)
                let pkg = columnString(stmt, index: 2)
                let text = columnString(stmt, index: 3)
                let snippetText = columnString(stmt, index: 4)
                let thumbRel = columnString(stmt, index: 5)
                results.append(ScreenMemorySearchResult(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: ts),
                    appPackageName: pkg,
                    extractedText: text,
                    highlightedSnippet: snippetText.isEmpty ? String(text.prefix(160)) : snippetText,
                    thumbnailURL: resolveThumbnailURL(thumbRel)
                ))
            }
            return results
        }
    }

    /// Enforces 7-day retention and `maxThumbnailBytes` cap, deleting expired rows and `.jpg` files.
    @discardableResult
    public func pruneRetention(
        now: Date = Date(),
        olderThanDays: Int = ScreenMemoryDatabase.defaultRetentionDays,
        maxThumbnailBytes: Int64 = ScreenMemoryDatabase.defaultMaxThumbnailBytes
    ) -> Int {
        queue.sync {
            guard let db else { return 0 }
            var deletedCount = 0
            let cutoff = now.addingTimeInterval(-TimeInterval(olderThanDays * 86_400)).timeIntervalSince1970

            // 1. Delete rows older than retention window
            let expired = selectRows(db: db, sql: "SELECT id, thumbnail_path FROM snapshots WHERE timestamp < ?;", bindDouble: cutoff)
            for row in expired {
                if deleteRowLocked(db: db, id: row.id, thumbnailPath: row.thumb) {
                    deletedCount += 1
                }
            }

            // 2. Enforce thumbnail disk cap by pruning oldest snapshots first
            var totalBytes = directorySizeBytes(thumbnailsDirectoryURL)
            if totalBytes > maxThumbnailBytes {
                let oldest = selectRows(db: db, sql: "SELECT id, thumbnail_path FROM snapshots ORDER BY timestamp ASC;", bindDouble: nil)
                for row in oldest {
                    guard totalBytes > maxThumbnailBytes else { break }
                    let fileURL = resolveThumbnailURL(row.thumb)
                    let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    if deleteRowLocked(db: db, id: row.id, thumbnailPath: row.thumb) {
                        totalBytes = max(0, totalBytes - fileSize)
                        deletedCount += 1
                    }
                }
            }

            if deletedCount > 0 {
                _ = execSQL(db: db, "PRAGMA optimize;")
            }
            return deletedCount
        }
    }

    /// Deletes all indexed screen memory records and thumbnails.
    public func clearAll() {
        queue.sync {
            guard let db else { return }
            _ = execSQL(db: db, "DELETE FROM snapshots;")
            _ = execSQL(db: db, "VACUUM;")
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: thumbnailsDirectoryURL, includingPropertiesForKeys: nil) {
                for url in files {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    /// Returns total snapshot count and thumbnail storage size in bytes.
    public func stats() -> (count: Int, totalBytes: Int64) {
        queue.sync {
            guard let db else { return (0, 0) }
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM snapshots;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int64(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return (count, directorySizeBytes(thumbnailsDirectoryURL))
        }
    }

    /// Converts arbitrary user input into a safe FTS5 prefix query (`"word1"* "word2"*`).
    public static func buildSafeFTS5Query(from raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Private SQLite Helpers

    private func openAndMigrateLocked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbnailsDirectoryURL, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            return
        }
        self.db = handle

        _ = execSQL(db: handle, "PRAGMA journal_mode = WAL;")
        _ = execSQL(db: handle, "PRAGMA synchronous = NORMAL;")

        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            app_package_name TEXT NOT NULL,
            extracted_text TEXT NOT NULL,
            thumbnail_path TEXT NOT NULL,
            frame_hash INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON snapshots(timestamp DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS snapshots_fts USING fts5(
            extracted_text,
            app_package_name,
            content='snapshots',
            content_rowid='id',
            tokenize='porter unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS snapshots_ai AFTER INSERT ON snapshots BEGIN
            INSERT INTO snapshots_fts(rowid, extracted_text, app_package_name)
            VALUES (new.id, new.extracted_text, new.app_package_name);
        END;
        CREATE TRIGGER IF NOT EXISTS snapshots_ad AFTER DELETE ON snapshots BEGIN
            INSERT INTO snapshots_fts(snapshots_fts, rowid, extracted_text, app_package_name)
            VALUES ('delete', old.id, old.extracted_text, old.app_package_name);
        END;
        """
        _ = execSQL(db: handle, schemaSQL)
    }

    private func fetchRecentLocked(db: OpaquePointer, limit: Int) -> [ScreenMemorySearchResult] {
        let sql = """
        SELECT id, timestamp, app_package_name, extracted_text, thumbnail_path
        FROM snapshots
        ORDER BY timestamp DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [ScreenMemorySearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let pkg = columnString(stmt, index: 2)
            let text = columnString(stmt, index: 3)
            let thumbRel = columnString(stmt, index: 4)
            results.append(ScreenMemorySearchResult(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                appPackageName: pkg,
                extractedText: text,
                highlightedSnippet: String(text.prefix(160)),
                thumbnailURL: resolveThumbnailURL(thumbRel)
            ))
        }
        return results
    }

    private func selectRows(db: OpaquePointer, sql: String, bindDouble: Double?) -> [(id: Int64, thumb: String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let bindDouble {
            sqlite3_bind_double(stmt, 1, bindDouble)
        }
        var rows: [(Int64, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0), columnString(stmt, index: 1)))
        }
        return rows
    }

    private func deleteRowLocked(db: OpaquePointer, id: Int64, thumbnailPath: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM snapshots WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }

        let fileURL = resolveThumbnailURL(thumbnailPath)
        try? FileManager.default.removeItem(at: fileURL)
        return true
    }

    private func execSQL(db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func columnString(_ stmt: OpaquePointer?, index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private func resolveThumbnailURL(_ filenameOrPath: String) -> URL {
        if filenameOrPath.hasPrefix("/") {
            return URL(fileURLWithPath: filenameOrPath)
        }
        return thumbnailsDirectoryURL.appendingPathComponent(filenameOrPath, isDirectory: false)
    }

    private func directorySizeBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return files.reduce(0) { sum, fileURL in
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return sum + size
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
