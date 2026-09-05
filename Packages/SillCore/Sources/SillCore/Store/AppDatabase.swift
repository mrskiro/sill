import Foundation
import GRDB

public enum StoreError: Error, Equatable {
    case corruptRow(String)
}

/// Owns the SQLite connection and the schema. Everything else goes through `NoteStore`.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// In-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return AppDatabase(writer: queue)
    }

    /// On-disk database (WAL mode via `DatabasePool`). Creates parent directories.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path)
        try migrator.migrate(pool)
        return AppDatabase(writer: pool)
    }

    /// `~/Library/Application Support/<appName>/sill.sqlite` (inside the sandbox container when sandboxed).
    public static func defaultURL(appName: String = "Sill") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("sill.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE note (
                    id            TEXT PRIMARY KEY NOT NULL,
                    content       TEXT NOT NULL,
                    created_at    REAL NOT NULL,
                    updated_at    REAL NOT NULL,
                    deleted_at    REAL,
                    origin_device TEXT NOT NULL,
                    origin_seq    INTEGER NOT NULL
                );
                CREATE INDEX note_origin ON note(origin_device, origin_seq);
                CREATE INDEX note_updated ON note(updated_at);

                CREATE TABLE device (
                    id   TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL
                );

                CREATE TABLE seen (
                    device_id TEXT PRIMARY KEY NOT NULL,
                    max_seq   INTEGER NOT NULL
                );

                CREATE TABLE peer (
                    id               TEXT PRIMARY KEY NOT NULL,
                    name             TEXT NOT NULL,
                    cert_fingerprint BLOB NOT NULL,
                    paired_at        REAL NOT NULL,
                    last_sync_at     REAL
                );
                """)
        }
        // A (device, seq) pair is a version and must never repeat; make the database enforce it.
        migrator.registerMigration("v2-unique-version") { db in
            try db.execute(sql: """
                DROP INDEX IF EXISTS note_origin;
                CREATE UNIQUE INDEX note_origin ON note(origin_device, origin_seq);
                """)
        }
        return migrator
    }
}
