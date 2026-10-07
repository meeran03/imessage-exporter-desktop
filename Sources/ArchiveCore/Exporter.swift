import Foundation
import BodyDecoder

public struct ExportResult: Sendable {
    public let folder: URL
    public let records: Int
    public let attachments: Int
    public let copiedAttachments: Int
    public let unresolvedText: Int
    public let warnings: [String]
    public var needsAttention: Bool { !warnings.isEmpty || copiedAttachments != attachments || unresolvedText > 0 }
}

public final class Exporter {
    let engine: URL
    public init(engine: URL) { self.engine = engine }
    public func export(source: Source, chat: Conversation, parent: URL, token: CancellationToken,
                       progress: @escaping @Sendable (String) -> Void) throws -> ExportResult {
        try token.check()
        let protectedRoot = (source.backup ?? source.database.deletingLastPathComponent()).resolvingSymlinksInPath().path + "/"
        if parent.resolvingSymlinksInPath().path.hasPrefix(protectedRoot) ||
            parent.resolvingSymlinksInPath().path + "/" == protectedRoot {
            throw ArchiveError.message("Choose an export folder outside the source database or backup.")
        }
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            throw ArchiveError.message("The bundled export engine is missing. Download a complete iMessage Exporter app bundle.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("message-archive-" + UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        progress("Preparing this conversation…")
        let original = try Database(source.database, immutable: source.backup != nil)
        let filteredURL = work.appendingPathComponent("chat.db")
        let filtered = try Database(filteredURL, writable: true)
        try original.backup(to: filtered, token: token)
        try filter(filtered, chatID: chat.id, token: token)
        let filename = safeName(chat.title)
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = parent.appendingPathComponent(filename + "-" + date + "-" + String(UUID().uuidString.prefix(6)))
        try manager.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var warnings: [String] = []
        do {
            progress("Saving messages and original attachments…")
            let archive = try writeStructured(filtered, source: source, output: output, token: token)
            var engineSource = filteredURL
            if let backup = source.backup, let fileID = source.fileID {
                progress("Preparing backup attachments…")
                engineSource = work.appendingPathComponent("backup")
                try stageBackup(backup, id: fileID, filtered: filteredURL, to: engineSource, token: token)
            }
            var rendered: [String: Any] = [:]
            for format in ["html", "txt"] {
                try token.check()
                progress("Creating the \(format == "html" ? "readable" : "plain text") transcript…")
                let folder = output.appendingPathComponent("readable-" + format)
                let log = output.appendingPathComponent(format + "-export.log")
                var arguments = ["-f", format, "-c", "clone", "-p", engineSource.path,
                                 "-a", source.backup == nil ? "macOS" : "iOS", "-o", folder.path]
                if source.backup == nil { arguments += ["-r", source.database.deletingLastPathComponent().path] }
                let code = try run(arguments, log: log, token: token)
                let files = try children(folder, extension: format)
                rendered[format] = ["exit_code": code, "files": files.map { relative($0, to: output) }]
                if code != 0 || files.isEmpty { warnings.append("The \(format.uppercased()) transcript needs attention. See \(log.lastPathComponent).") }
                if format == "html", !files.isEmpty {
                    let links = files.map { file in
                        "<li><a href=\"\(html(relative(file, to: output).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))\">\(html(file.deletingPathExtension().lastPathComponent))</a></li>"
                    }.joined()
                    let content = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>\(html(chat.title))</title><style>body{font:17px system-ui;max-width:720px;margin:60px auto;padding:24px;line-height:1.6}a{color:#08695f}li{margin:16px 0}</style><h1>\(html(chat.title))</h1><p>Open your conversation below. Keep this entire folder together so attachments work.</p><ul>\(links)</ul>"
                    try content.write(to: output.appendingPathComponent("conversation.html"), atomically: true, encoding: .utf8)
                } else if format == "txt", !files.isEmpty {
                    let content = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n")
                    try content.write(to: output.appendingPathComponent("conversation.txt"), atomically: true, encoding: .utf8)
                }
            }
            let report: [String: Any] = [
                "schema_version": 1, "status": warnings.isEmpty && !archive.needsAttention ? "complete" : "partial",
                "exported_at": ISO8601DateFormatter().string(from: Date()), "chat_id": chat.id,
                "database_record_count": archive.records, "attachment_count": archive.attachments,
                "attachments_copied": archive.copiedAttachments, "unresolved_json_text_count": archive.unresolvedText,
                "warnings": warnings + archive.warnings, "readable_exports": rendered,
                "limitations": ["Only records and files available in the source can be exported.",
                                "Binary metadata is preserved as base64. Interactive effects are rendered as supported by imessage-exporter."]
            ]
            try writeJSON(report, to: output.appendingPathComponent("export-report.json"))
            return ExportResult(folder: output, records: archive.records, attachments: archive.attachments,
                                copiedAttachments: archive.copiedAttachments, unresolvedText: archive.unresolvedText,
                                warnings: warnings + archive.warnings)
        } catch {
            // A cancellation or disk error may leave useful files. Never label them complete.
            try? writeJSON(["status": error is CancellationError ? "cancelled" : "failed",
                            "reason": error.localizedDescription], to: output.appendingPathComponent("export-report.json"))
            throw ArchiveError.message(error is CancellationError ? "Export cancelled. Partial files are in \(output.path)." :
                "\(error.localizedDescription) Partial files, if any, are in \(output.path).")
        }
    }

    func filter(_ db: Database, chatID: Int64, token: CancellationToken) throws {
        let tableNames = try db.tables()
        try db.execute("BEGIN IMMEDIATE")
        do {
            for row in try db.rows("SELECT name FROM sqlite_master WHERE type='trigger'") {
                if let name = row["name"]?.string { try db.execute("DROP TRIGGER " + quote(name)) }
            }
            try db.execute("CREATE TEMP TABLE selected_messages (id INTEGER PRIMARY KEY)")
            try db.execute("INSERT INTO selected_messages SELECT DISTINCT message_id FROM chat_message_join WHERE chat_id=?", [.integer(chatID)])
            if tableNames.contains("chat_recoverable_message_join") {
                try db.execute("INSERT OR IGNORE INTO selected_messages SELECT message_id FROM chat_recoverable_message_join WHERE chat_id=?", [.integer(chatID)])
            }
            let messageColumns = try db.columns("message")
            if messageColumns.isSuperset(of: ["guid", "associated_message_guid"]) {
                let guids = Set(try db.rows("SELECT guid FROM message WHERE ROWID IN (SELECT id FROM selected_messages)").compactMap { $0["guid"]?.string })
                for row in try db.rows("SELECT ROWID AS message_id,associated_message_guid FROM message WHERE associated_message_guid IS NOT NULL") {
                    try token.check()
                    if let associated = row["associated_message_guid"]?.string,
                       let suffix = associated.split(separator: "/").last, guids.contains(String(suffix)),
                       let id = row["message_id"]?.integer {
                        try db.execute("INSERT OR IGNORE INTO selected_messages VALUES (?)", [.integer(id)])
                    }
                }
            }
            for table in tableNames where !table.hasPrefix("sqlite_") {
                try token.check()
                let columns = try db.columns(table)
                if columns.contains("chat_id") { try db.execute("DELETE FROM \(quote(table)) WHERE chat_id != ?", [.integer(chatID)]) }
                if columns.contains("chat") { try db.execute("DELETE FROM \(quote(table)) WHERE chat != ?", [.integer(chatID)]) }
                if columns.contains("message_id") { try db.execute("DELETE FROM \(quote(table)) WHERE message_id NOT IN (SELECT id FROM selected_messages)") }
            }
            try db.execute("DELETE FROM message WHERE ROWID NOT IN (SELECT id FROM selected_messages)")
            try db.execute("DELETE FROM chat WHERE ROWID != ?", [.integer(chatID)])
            if tableNames.contains("attachment") && tableNames.contains("message_attachment_join") {
                try db.execute("DELETE FROM attachment WHERE ROWID NOT IN (SELECT attachment_id FROM message_attachment_join)")
            }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
        try db.execute("PRAGMA journal_mode=DELETE")
    }

    func writeStructured(_ db: Database, source: Source, output: URL, token: CancellationToken) throws -> ExportResult {
        let tables = try db.tables()
        let manifest = try source.backup.map { try Database($0.appendingPathComponent("Manifest.db"), immutable: true) }
        let originals = output.appendingPathComponent("attachments/originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attachments: [[String: Any]] = []
        var warnings: [String] = []
        var copied = 0
        if tables.contains("attachment") {
            for row in try db.rows("SELECT ROWID AS attachment_id,* FROM attachment") {
                try token.check()
                let id = row["attachment_id"]?.integer ?? 0
                var entry = row.mapValues { $0.json }
                let name = row["transfer_name"]?.string ?? row["filename"]?.string ?? "attachment"
                let destination = originals.appendingPathComponent("\(id)-" + safeName(URL(fileURLWithPath: name).lastPathComponent))
                do {
                    guard let file = try attachmentURL(row["filename"]?.string, source: source, manifest: manifest) else {
                        throw ArchiveError.message("The attachment is absent from the source.")
                    }
                    try FileManager.default.copyItem(at: file, to: destination)
                    entry["exported_path"] = relative(destination, to: output)
                    entry["status"] = "copied"; copied += 1
                } catch {
                    entry["status"] = "missing_or_unreadable"
                    entry["error"] = error.localizedDescription
                    warnings.append("Attachment \(id) could not be copied.")
                }
                attachments.append(entry)
            }
        }
        var handles: [Int64: String] = [:]
        for row in try db.rows("SELECT ROWID AS handle_id,id FROM handle") {
            if let id = row["handle_id"]?.integer { handles[id] = row["id"]?.string }
        }
        var joins: [Int64: [Int64]] = [:]
        if tables.contains("message_attachment_join") {
            for row in try db.rows("SELECT message_id,attachment_id FROM message_attachment_join") {
                if let id = row["message_id"]?.integer, let aid = row["attachment_id"]?.integer { joins[id, default: []].append(aid) }
            }
        }
        var messages: [[String: Any]] = []
        var unresolved = 0
        for row in try db.rows("SELECT ROWID AS message_id,* FROM message ORDER BY date,ROWID") {
            try token.check()
            let id = row["message_id"]?.integer ?? 0
            var text = row["text"]?.string
            var state = "stored_or_no_text"
            if (text == nil || text?.isEmpty == true), let body = row["attributedBody"]?.data, !body.isEmpty {
                text = decode(body)
                state = text == nil ? "unresolved" : "decoded"
                if text == nil { unresolved += 1 }
            }
            let isFromMe = row["is_from_me"]?.integer == 1
            var entry: [String: Any] = ["id": id, "is_from_me": isFromMe, "text_status": state,
                                       "attachment_ids": joins[id] ?? [], "raw": row.mapValues { $0.json }]
            entry["text"] = text.map { $0 as Any } ?? NSNull()
            entry["sender"] = isFromMe ? "Me" : (handles[row["handle_id"]?.integer ?? -1] ?? "Unknown")
            entry["timestamp"] = appleDate(row["date"]?.number).map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull()
            messages.append(entry)
        }
        try writeJSON(["schema_version": 1, "messages": messages, "attachments": attachments], to: output.appendingPathComponent("messages.json"))
        return ExportResult(folder: output, records: messages.count, attachments: attachments.count,
                            copiedAttachments: copied, unresolvedText: unresolved, warnings: warnings)
    }

    func run(_ arguments: [String], log: URL, token: CancellationToken) throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stream = try FileHandle(forWritingTo: log)
        defer { try? stream.close() }
        let process = Process()
        process.executableURL = engine
        process.arguments = arguments
        process.standardOutput = stream; process.standardError = stream
        // Native copies and HTML keep files inside the user-selected export folder.
        try process.run()
        while process.isRunning {
            do { try token.check() } catch { process.terminate(); process.waitUntilExit(); throw error }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

func stageBackup(_ source: URL, id: String, filtered: URL, to destination: URL, token: CancellationToken) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let nested = fm.fileExists(atPath: source.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id).path)
    for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
        try token.check()
        let target = destination.appendingPathComponent(entry.lastPathComponent)
        if entry.lastPathComponent == "Manifest.db" {
            let original = try Database(entry, immutable: true)
            let copy = try Database(target, writable: true)
            try original.backup(to: copy, token: token)
            try copy.execute("PRAGMA journal_mode=DELETE")
        } else if nested && entry.lastPathComponent == String(id.prefix(2)) {
            try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in try fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) where file.lastPathComponent != id {
                try fm.createSymbolicLink(at: target.appendingPathComponent(file.lastPathComponent), withDestinationURL: file)
            }
            try fm.copyItem(at: filtered, to: target.appendingPathComponent(id))
        } else if !nested && entry.lastPathComponent == id {
            try fm.copyItem(at: filtered, to: target)
        } else if !["Manifest.db-wal", "Manifest.db-shm"].contains(entry.lastPathComponent) {
            try fm.createSymbolicLink(at: target, withDestinationURL: entry)
        }
    }
}

func attachmentURL(_ filename: String?, source: Source, manifest: Database?) throws -> URL? {
    guard var filename, !filename.isEmpty else { return nil }
    if let backup = source.backup, let manifest {
        if let range = filename.range(of: "/var/mobile/") { filename = String(filename[range.upperBound...]) }
        if filename.hasPrefix("~/") { filename = String(filename.dropFirst(2)) }
        filename = filename.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidates = filename.hasPrefix("Media/") ? [String(filename.dropFirst(6)), filename] : [filename]
        for candidate in candidates {
            if let id = try manifest.rows("SELECT fileID FROM Files WHERE relativePath=? AND domain IN ('HomeDomain','MediaDomain') AND flags=1 LIMIT 1", [.text(candidate)]).first?["fileID"]?.string,
               validFileID(id) { return fileURL(id, in: backup) }
        }
        return nil
    }
    let path = (filename as NSString).expandingTildeInPath
    return URL(fileURLWithPath: path)
}
func validFileID(_ id: String) -> Bool { id.count == 40 && id.allSatisfy { "0123456789abcdef".contains($0) } }
func decode(_ data: Data) -> String? {
    data.withUnsafeBytes { bytes in
        guard let raw = ma_decode_body(bytes.baseAddress, bytes.count) else { return nil }
        defer { free(raw) }
        return String(validatingUTF8: raw)
    }
}
func safeName(_ name: String) -> String {
    let cleaned = name.map { character -> Character in
        if character == "/" || character == ":" || character == "\\" || character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "_" }
        return character
    }
    let value = String(cleaned.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return value.isEmpty ? "Conversation" : value
}
func relative(_ file: URL, to root: URL) -> String { String(file.path.dropFirst(root.path.count + 1)) }
func html(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}
func writeJSON(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
func children(_ root: URL, extension ext: String) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    return iterator.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }.sorted { $0.path < $1.path }
}
