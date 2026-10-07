import XCTest
import CryptoKit
@testable import ArchiveCore

final class ArchiveCoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func fixture() throws -> URL {
        let demo = try DemoLibrary.make()
        let destination = root.appendingPathComponent("demo")
        try FileManager.default.moveItem(at: demo.deletingLastPathComponent(), to: destination)
        // The demo attachment URL needs updating after the fixture is moved.
        let db = try Database(destination.appendingPathComponent("chat.db"), writable: true)
        try db.execute("UPDATE attachment SET filename=?", [.text(destination.appendingPathComponent("Itinerary.txt").path)])
        return destination.appendingPathComponent("chat.db")
    }
    func engine() throws -> URL {
        let path = ProcessInfo.processInfo.environment["MESSAGE_ARCHIVE_TEST_ENGINE"]
        guard let path, FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set MESSAGE_ARCHIVE_TEST_ENGINE to an official imessage-exporter executable for integration tests.")
        }
        return URL(fileURLWithPath: path)
    }
    func testConversationCountsAndGroupClassification() throws {
        let source = try Source.resolve(fixture())
        let chats = try Library.load(source)
        XCTAssertEqual(chats.count, 4)
        XCTAssertTrue(chats.allSatisfy { $0.count == 8 })
        XCTAssertEqual(chats.filter(\.isGroup).count, 2)
        XCTAssertEqual(chats.first?.title, "Book club")
    }
    func testExactFilteringPreservesOriginalAndUnjoinedReaction() throws {
        let original = try Database(fixture(), writable: true)
        try original.execute("INSERT INTO message (ROWID,guid,date,associated_message_guid,associated_message_type) VALUES (99,'reaction',790100000000000000,'p:0/synthetic-1',2001)")
        try original.execute("CREATE TRIGGER apple_hook AFTER DELETE ON message BEGIN SELECT private_apple_function(OLD.ROWID); END")
        let selected = try Database(root.appendingPathComponent("selected.db"), writable: true)
        try original.backup(to: selected)
        try Exporter(engine: URL(fileURLWithPath: "/unused")).filter(selected, chatID: 1, token: CancellationToken())
        XCTAssertEqual(try selected.rows("SELECT COUNT(*) AS n FROM chat").first?["n"]?.integer, 1)
        XCTAssertEqual(try selected.rows("SELECT COUNT(*) AS n FROM message").first?["n"]?.integer, 9)
        XCTAssertEqual(try original.rows("SELECT COUNT(*) AS n FROM message").first?["n"]?.integer, 33)
        XCTAssertEqual(try original.rows("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='trigger'").first?["n"]?.integer, 1)
        XCTAssertEqual(try selected.rows("PRAGMA integrity_check").first?.values.first?.string, "ok")
    }
    func testMissingAttachmentsAreReportedRatherThanLostSilently() throws {
        let source = try Source.resolve(fixture())
        let db = try Database(source.database, writable: true)
        try db.execute("UPDATE attachment SET filename='/not-a-real-file'")
        let result = try Exporter(engine: URL(fileURLWithPath: "/unused")).writeStructured(db, source: source, output: root, token: CancellationToken())
        XCTAssertEqual(result.attachments, 1)
        XCTAssertEqual(result.copiedAttachments, 0)
        XCTAssertEqual(result.warnings.count, 1)
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("messages.json"))) as! [String: Any]
        XCTAssertEqual((data["attachments"] as! [[String: Any]]).first?["status"] as? String, "missing_or_unreadable")
    }
    func testMalformedBodyPreservesRawData() throws {
        let source = try Source.resolve(fixture())
        let db = try Database(source.database, writable: true)
        try db.execute("UPDATE message SET text=NULL,attributedBody=? WHERE ROWID=1", [.blob(Data("malformed".utf8))])
        let result = try Exporter(engine: URL(fileURLWithPath: "/unused")).writeStructured(db, source: source, output: root, token: CancellationToken())
        XCTAssertEqual(result.unresolvedText, 1)
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("messages.json"))) as! [String: Any]
        let message = (data["messages"] as! [[String: Any]]).first!
        XCTAssertEqual(message["text_status"] as? String, "unresolved")
        XCTAssertNotNil((message["raw"] as? [String: Any])?["attributedBody"])
    }
    func testFullExportMarksMissingAttachmentAsPartial() throws {
        let executable = try engine()
        let source = try Source.resolve(fixture())
        let db = try Database(source.database, writable: true)
        try db.execute("UPDATE attachment SET filename='/not-a-real-file'")
        let chat = try XCTUnwrap(Library.load(source).first { $0.id == 1 })
        let result = try Exporter(engine: executable).export(source: source, chat: chat, parent: root,
                    token: CancellationToken()) { _ in }
        XCTAssertTrue(result.needsAttention)
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: result.folder.appendingPathComponent("export-report.json"))) as! [String: Any]
        XCTAssertEqual(report["status"] as? String, "partial")
        XCTAssertEqual(report["attachments_copied"] as? Int, 0)
    }
    func testAttributedTextDecoderKeepsUnicodeAndLineBreaks() throws {
        let text = "Invented sample 🌿\nSecond line"
        let data = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: text), requiringSecureCoding: true)
        XCTAssertEqual(decode(data), text)
    }
    func testReadOnlySourceWithWALIncludesNewestMessage() throws {
        let url = try fixture()
        let writer = try Database(url, writable: true)
        try writer.execute("PRAGMA journal_mode=WAL")
        try writer.execute("INSERT INTO message (ROWID,guid,text,date,handle_id,service) VALUES (100,'wal-new','New synthetic record',790200000000000000,1,'iMessage')")
        try writer.execute("INSERT INTO chat_message_join VALUES (1,100,790200000000000000)")
        let source = try Source.resolve(url)
        XCTAssertEqual(try Library.load(source).first { $0.id == 1 }?.count, 9)
        let reader = try Database(url)
        let copy = try Database(root.appendingPathComponent("wal-snapshot.db"), writable: true)
        try reader.backup(to: copy)
        XCTAssertEqual(try copy.rows("SELECT text FROM message WHERE ROWID=100").first?["text"]?.string, "New synthetic record")
    }
    func testRealEngineWithSyntheticIPhoneBackup() throws {
        let executable = try engine()
        let original = try fixture()
        let backup = root.appendingPathComponent("iphone-backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        func hash(_ value: String) -> String {
            Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        func put(_ url: URL, id: String) throws {
            let directory = backup.appendingPathComponent(String(id.prefix(2)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(id))
        }
        let smsID = hash("HomeDomain-Library/SMS/sms.db")
        let contactID = hash("HomeDomain-Library/AddressBook/AddressBook.sqlitedb")
        let mediaPath = "Library/SMS/Attachments/demo/Itinerary.txt"
        let attachmentID = hash("MediaDomain-" + mediaPath)
        let sms = try Database(original, writable: true)
        try sms.execute("UPDATE attachment SET filename=?", [.text("~/" + mediaPath)])
        try put(original, id: smsID)
        try put(original.deletingLastPathComponent().appendingPathComponent("Itinerary.txt"), id: attachmentID)
        let contactURL = root.appendingPathComponent("contacts.db")
        let contacts = try Database(contactURL, writable: true)
        try contacts.execute("CREATE TABLE ABPerson (ROWID INTEGER PRIMARY KEY,First TEXT,Last TEXT,Organization TEXT)")
        try contacts.execute("CREATE TABLE ABMultiValue (record_id INTEGER,property INTEGER,value TEXT)")
        try contacts.execute("INSERT INTO ABPerson VALUES (1,'Avery','Example',NULL)")
        try contacts.execute("INSERT INTO ABMultiValue VALUES (1,3,'+15550001001')")
        try put(contactURL, id: contactID)
        let manifest = try Database(backup.appendingPathComponent("Manifest.db"), writable: true)
        try manifest.execute("CREATE TABLE Files (fileID TEXT,domain TEXT,relativePath TEXT,flags INTEGER,file BLOB)")
        for (id, domain, path) in [(smsID,"HomeDomain","Library/SMS/sms.db"),
                                    (contactID,"HomeDomain","Library/AddressBook/AddressBook.sqlitedb"),
                                    (attachmentID,"MediaDomain",mediaPath)] {
            try manifest.execute("INSERT INTO Files VALUES (?,?,?,1,NULL)", [.text(id), .text(domain), .text(path)])
        }
        let backupMetadata: [String: Any] = [
            "IsEncrypted": false,
            "Applications": [:] as [String: Any],
            "Lockdown": ["BuildVersion": "22A000", "DeviceName": "Synthetic iPhone",
                         "ProductType": "iPhone15,2", "ProductVersion": "18.0",
                         "SerialNumber": "SYNTHETIC", "UniqueDeviceID": "synthetic-test-device"]
        ]
        for (filename, data) in [("Manifest.plist", backupMetadata),
                                  ("Status.plist", ["SnapshotState": "finished"] as [String: Any]),
                                  ("Info.plist", ["Device Name": "Synthetic iPhone"] as [String: Any])] {
            try PropertyListSerialization.data(fromPropertyList: data, format: .binary, options: 0)
                .write(to: backup.appendingPathComponent(filename))
        }
        let source = try Source.resolve(backup)
        let chat = try XCTUnwrap(Library.load(source).first { $0.id == 1 })
        let output = root.appendingPathComponent("backup-output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let before = try Data(contentsOf: source.database)
        let result = try Exporter(engine: executable).export(source: source, chat: chat, parent: output, token: CancellationToken()) { _ in }
        XCTAssertEqual(result.records, 8)
        XCTAssertEqual(result.copiedAttachments, 1)
        let logs = try ["html-export.log", "txt-export.log"].map { try String(contentsOf: result.folder.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        XCTAssertFalse(result.needsAttention, "\(result.warnings)\n\(logs)")
        XCTAssertEqual(try Data(contentsOf: source.database), before)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.folder.appendingPathComponent("messages.json"))) as! [String: Any]
        XCTAssertEqual((json["attachments"] as? [[String: Any]])?.first?["status"] as? String, "copied")
    }
    func testDatesAndFilenameSafety() {
        XCTAssertEqual(appleDate(800_000_000_000_000_000), appleDate(800_000_000))
        XCTAssertNil(appleDate(0))
        XCTAssertEqual(safeName("../../example:/file"), "_.._example__file")
        XCTAssertEqual(normalize("+1 (555) 000-1001"), "5550001001")
        XCTAssertEqual(normalize("Person@EXAMPLE.invalid"), "person@example.invalid")
    }
    func testCancellationLeavesOriginalUntouched() throws {
        let source = try Source.resolve(fixture())
        let bytes = try Data(contentsOf: source.database)
        let token = CancellationToken(); token.cancel()
        let chat = try XCTUnwrap(Library.load(source).first)
        XCTAssertThrowsError(try Exporter(engine: URL(fileURLWithPath: "/unused")).export(source: source, chat: chat, parent: root, token: token) { _ in })
        XCTAssertEqual(try Data(contentsOf: source.database), bytes)
    }
    func testEncryptedBackupGivesActionableError() throws {
        try PropertyListSerialization.data(fromPropertyList: ["IsEncrypted": true], format: .binary, options: 0)
            .write(to: root.appendingPathComponent("Manifest.plist"))
        XCTAssertThrowsError(try Source.resolve(root)) { error in XCTAssertTrue(error.localizedDescription.contains("Keep encryption enabled")) }
    }
    func testRealEngineExportWithSyntheticDataOnly() throws {
        let executable = try engine()
        let source = try Source.resolve(fixture())
        let before = try Data(contentsOf: source.database)
        let chat = try XCTUnwrap(Library.load(source).first { $0.id == 1 })
        let parent = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let result = try Exporter(engine: executable).export(source: source, chat: chat, parent: parent, token: CancellationToken()) { _ in }
        XCTAssertEqual(result.records, 8)
        XCTAssertEqual(result.copiedAttachments, 1)
        XCTAssertFalse(result.needsAttention, "\(result.warnings)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent("conversation.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent("conversation.txt").path))
        XCTAssertEqual(try Data(contentsOf: source.database), before)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.folder.appendingPathComponent("messages.json"))) as! [String: Any]
        let attachment = try XCTUnwrap((json["attachments"] as? [[String: Any]])?.first?["exported_path"] as? String)
        XCTAssertEqual(try Data(contentsOf: result.folder.appendingPathComponent(attachment)), try Data(contentsOf: source.database.deletingLastPathComponent().appendingPathComponent("Itinerary.txt")))
    }
}
