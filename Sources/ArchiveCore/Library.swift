import Foundation

public struct Source: Sendable {
    public let database: URL
    public let backup: URL?
    let fileID: String?
    public var title: String { backup?.lastPathComponent ?? "Messages on this Mac" }
    public var location: URL { backup ?? database }
    public static var macMessages: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }
    public static func resolve(_ url: URL) throws -> Source {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
            throw ArchiveError.message("This source is unavailable. Select a Messages database or an existing iPhone backup.")
        }
        if !directory.boolValue { return Source(database: url, backup: nil, fileID: nil) }
        let manifestPlist = url.appendingPathComponent("Manifest.plist")
        if let data = try? Data(contentsOf: manifestPlist),
           let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           plist["IsEncrypted"] as? Bool == true {
            throw ArchiveError.message("This version cannot read encrypted iPhone backups. Keep encryption enabled and use Messages synced to your Mac instead.")
        }
        let status = url.appendingPathComponent("Status.plist")
        if let data = try? Data(contentsOf: status),
           let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           plist["SnapshotState"] as? String != "finished" {
            throw ArchiveError.message("This iPhone backup is unfinished. Let Finder complete the backup before selecting it.")
        }
        let manifest = try Database(url.appendingPathComponent("Manifest.db"), immutable: true)
        guard let id = try manifest.rows("SELECT fileID FROM Files WHERE domain='HomeDomain' AND relativePath='Library/SMS/sms.db'").first?["fileID"]?.string else {
            throw ArchiveError.message("This backup has no Messages database. Messages kept in iCloud may be absent from a Finder backup. Use Messages synced to your Mac.")
        }
        guard validFileID(id) else { throw ArchiveError.message("This backup has an invalid Messages file identifier.") }
        let database = fileURL(id, in: url)
        return Source(database: database, backup: url, fileID: id)
    }
}

public struct Conversation: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let title: String
    public let participants: [String]
    public let count: Int
    public let firstDate: Date?
    public let lastDate: Date?
    public var isGroup: Bool { participants.count > 1 }
    public var searchText: String { ([title] + participants).joined(separator: " ") }
}

public enum Library {
    public static func load(_ source: Source, contactNames: [String: String] = [:]) throws -> [Conversation] {
        let db = try Database(source.database, immutable: source.backup != nil)
        guard try db.tables().isSuperset(of: ["chat", "handle", "chat_handle_join", "chat_message_join", "message"]) else {
            throw ArchiveError.message("This file is not a supported Apple Messages database.")
        }
        var names = contactNames
        if let backup = source.backup { names.merge(try backupContacts(backup)) { old, _ in old } }
        var participants: [Int64: [String]] = [:]
        for row in try db.rows("SELECT DISTINCT j.chat_id,h.id FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id") {
            if let id = row["chat_id"]?.integer, let handle = row["id"]?.string { participants[id, default: []].append(handle) }
        }
        let rows = try db.rows("""
            SELECT c.ROWID AS chat_id,c.display_name,c.chat_identifier,COUNT(DISTINCT m.ROWID) AS record_count,
                   MIN(m.date) AS first_date,MAX(m.date) AS last_date
            FROM chat c JOIN chat_message_join j ON c.ROWID=j.chat_id JOIN message m ON m.ROWID=j.message_id
            GROUP BY c.ROWID ORDER BY MAX(m.date) DESC
            """)
        return rows.compactMap { row in
            guard let id = row["chat_id"]?.integer else { return nil }
            let handles = (participants[id] ?? []).sorted()
            let resolvedNames = handles.map { names[normalize($0)] ?? $0 }
            let display = row["display_name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = display.isEmpty ? (resolvedNames.isEmpty ? row["chat_identifier"]?.string ?? "Conversation" : resolvedNames.joined(separator: ", ")) : display
            return Conversation(id: id, title: title, participants: handles,
                                count: Int(row["record_count"]?.integer ?? 0),
                                firstDate: appleDate(row["first_date"]?.number), lastDate: appleDate(row["last_date"]?.number))
        }
    }
    static func backupContacts(_ root: URL) throws -> [String: String] {
        let manifest = try Database(root.appendingPathComponent("Manifest.db"), immutable: true)
        let matches = try manifest.rows("SELECT fileID FROM Files WHERE domain='HomeDomain' AND relativePath LIKE '%AddressBook.sqlitedb'")
        var names: [String: String] = [:]
        for match in matches {
            guard let id = match["fileID"]?.string, validFileID(id),
                  let contacts = try? Database(fileURL(id, in: root), immutable: true),
                  (try? contacts.tables().contains("ABPerson")) == true else { continue }
            let people = try contacts.rows("SELECT ROWID AS person_id,First,Last,Organization FROM ABPerson")
            let values = try contacts.rows("SELECT record_id,value FROM ABMultiValue WHERE property IN (3,4)")
            var personNames: [Int64: String] = [:]
            for person in people {
                let full = [person["First"]?.string, person["Last"]?.string].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if let id = person["person_id"]?.integer { personNames[id] = full.isEmpty ? person["Organization"]?.string : full }
            }
            for value in values {
                if let id = value["record_id"]?.integer, let name = personNames[id], !name.isEmpty, let identifier = value["value"]?.string {
                    names[normalize(identifier)] = name
                }
            }
        }
        return names
    }
}

public func normalize(_ value: String) -> String {
    if value.contains("@") { return value.lowercased() }
    let digits = value.filter { $0.isNumber }
    return digits.count == 11 && digits.first == "1" ? String(digits.dropFirst()) : digits
}
func appleDate(_ value: Double?) -> Date? {
    guard let value, value != 0 else { return nil }
    let seconds = abs(value) > 1e12 ? value / 1e9 : value
    guard seconds.isFinite, abs(seconds) < 3e11 else { return nil }
    return Date(timeIntervalSinceReferenceDate: seconds)
}
func fileURL(_ id: String, in backup: URL) -> URL {
    let nested = backup.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id)
    return FileManager.default.fileExists(atPath: nested.path) ? nested : backup.appendingPathComponent(id)
}
