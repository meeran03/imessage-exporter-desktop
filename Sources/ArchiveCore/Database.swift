import Foundation
import CSQLite

public enum ArchiveError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

enum Cell {
    case null, integer(Int64), real(Double), text(String), blob(Data)
    var string: String? { if case .text(let v) = self { return v }; return nil }
    var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
    var number: Double? {
        switch self { case .integer(let v): return Double(v); case .real(let v): return v; default: return nil }
    }
    var data: Data? { if case .blob(let v) = self { return v }; return nil }
    var json: Any {
        switch self {
        case .null: return NSNull()
        case .integer(let v): return v
        case .real(let v): return v
        case .text(let v): return v
        case .blob(let v): return ["encoding": "base64", "data": v.base64EncodedString()]
        }
    }
}
typealias Row = [String: Cell]

final class Database {
    private(set) var handle: OpaquePointer?
    init(_ url: URL, writable: Bool = false, immutable: Bool = false) throws {
        var path = url.path
        if immutable {
            // URL encoding prevents paths containing '?' or '#' from changing SQLite URI options.
            path = url.absoluteString + "?mode=ro&immutable=1"
        }
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let code = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil)
        if code != SQLITE_OK {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Access denied"
            if let handle { sqlite3_close(handle) }; handle = nil
            throw ArchiveError.message("Cannot read this source: \(reason). For Mac Messages, enable Full Disk Access for Message Archive, then quit and reopen the app.")
        }
        sqlite3_busy_timeout(handle, 5000)
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func rows(_ sql: String, _ bindings: [Cell] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
            case .blob(let v): v.withUnsafeBytes { _ = sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), transient) }
            }
        }
        var result: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            var row: Row = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, i)!, count: count))
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }
    func execute(_ sql: String, _ bindings: [Cell] = []) throws { _ = try rows(sql, bindings) }
    func tables() throws -> Set<String> {
        Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.string })
    }
    func columns(_ table: String) throws -> Set<String> {
        Set(try rows("PRAGMA table_info(\(quote(table)))").compactMap { $0["name"]?.string })
    }
    func backup(to destination: Database, token: CancellationToken? = nil) throws {
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else { throw destination.failure() }
        var code: Int32 = SQLITE_OK
        var retries = 0
        do {
            while code == SQLITE_OK || code == SQLITE_BUSY || code == SQLITE_LOCKED {
                try token?.check()
                code = sqlite3_backup_step(backup, 512)
                if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                    retries += 1
                    guard retries <= 100 else { throw ArchiveError.message("Messages is busy. Wait a moment and try again.") }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        } catch { sqlite3_backup_finish(backup); throw error }
        let finish = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE && finish == SQLITE_OK else { throw destination.failure() }
    }
    func failure() -> ArchiveError { .message("Message database: \(String(cString: sqlite3_errmsg(handle)))") }
}
func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
