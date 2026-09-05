import Foundation

/// Append-only text log next to the database, so sync problems on a device can be read
/// by pulling one file (unified logging is not reachable from the command line for iPhones).
public enum SyncLog {
    nonisolated(unsafe) public static var url: URL = AppDatabase.defaultURL().deletingLastPathComponent()
        .appendingPathComponent("sync.log")
    private static let lock = NSLock()
    private static let maxBytes = 512 * 1024

    public static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        lock.withLock {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
                    size > maxBytes
                {
                    try? FileManager.default.removeItem(at: url)
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(entry.utf8))
                    try handle.close()
                } else {
                    try Data(entry.utf8).write(to: url)
                }
            } catch {
                // Diagnostics must never break the app.
            }
        }
    }
}
