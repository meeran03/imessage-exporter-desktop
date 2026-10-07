import XCTest
@testable import ArchiveCore

final class PhoneBackupTests: XCTestCase {
    let device = ConnectedPhone(id: "00000000-0000000000000000", name: "Synthetic iPhone")
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    static func completed(_ url: URL, encrypted: Bool = false) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data().write(to: url.appendingPathComponent("Manifest.db"))
        for (name, value) in [("Status.plist", ["SnapshotState": "finished"] as [String: Any]),
                              ("Manifest.plist", ["IsEncrypted": encrypted] as [String: Any])] {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url.appendingPathComponent(name))
        }
    }
    func testUSBDiscoveryUsesNamesAndExcludesInvalidIdentifiers() throws {
        let id = device.id
        let service = PhoneBackup(tools: root) { executable, args, input, _, _ in
            XCTAssertNil(input)
            if executable.lastPathComponent == "idevice_id" { XCTAssertEqual(args, ["-l"]); return .init(code: 0, output: id + "\n") }
            XCTAssertEqual(args, ["-u",id,"-k","DeviceName"])
            return .init(code: 0, output: "Synthetic iPhone\n")
        }
        XCTAssertEqual(try service.devices(token: CancellationToken()), [device])
        let invalid = PhoneBackup(tools: root) { _,_,_,_,_ in .init(code: 0, output: "../escape") }
        XCTAssertThrowsError(try invalid.devices(token: CancellationToken()))
    }
    func testFreshBackupPairsThenRequiresFinishedSnapshot() throws {
        let id = device.id
        let service = PhoneBackup(tools: root) { executable,args,input,_,progress in
            XCTAssertNil(input)
            if args.last == "validate" { return .init(code: 1, output: "") }
            if args.last == "pair" { return .init(code: 0, output: "") }
            XCTAssertEqual(executable.lastPathComponent, "idevicebackup2")
            XCTAssertEqual(Array(args.prefix(4)), ["-u",id,"backup","--full"])
            try Self.completed(URL(fileURLWithPath: args[4]).appendingPathComponent(id), encrypted: true)
            progress("50%")
            return .init(code: 0, output: "")
        }
        let backup = try service.create(device: device, parent: root, token: CancellationToken()) { _ in }
        XCTAssertTrue(try PhoneBackup.encrypted(backup))
        XCTAssertTrue(backup.path.hasPrefix(root.path + "/iPhone-Backup-"))
    }
    func testSuccessfulExitWithoutCompleteBackupIsRejected() throws {
        let service = PhoneBackup(tools: root) { _,_,_,_,_ in .init(code: 0, output: "") }
        XCTAssertThrowsError(try service.create(device: device, parent: root, token: CancellationToken()) { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("has not been loaded"))
        }
    }
    func testBackupFailureAndCancellationNeverReturnSnapshot() throws {
        let service = PhoneBackup(tools: root) { executable,_,_,_,_ in
            .init(code: executable.lastPathComponent == "idevicebackup2" ? 1 : 0, output: "Private raw tool output")
        }
        XCTAssertThrowsError(try service.create(device: device, parent: root, token: CancellationToken()) { _ in }) { error in
            XCTAssertFalse(error.localizedDescription.contains("Private raw"))
        }
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try service.create(device: device, parent: root, token: token) { _ in })
    }
    func testCancellationAtBackupCompletionStillRejectsSnapshot() throws {
        let id = device.id
        let service = PhoneBackup(tools: root) { executable,args,_,token,_ in
            if executable.lastPathComponent == "idevicebackup2" {
                try Self.completed(URL(fileURLWithPath: args[4]).appendingPathComponent(id))
                token.cancel()
            }
            return .init(code: 0, output: "")
        }
        XCTAssertThrowsError(try service.create(device: device, parent: root, token: CancellationToken()) { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Backup cancelled"))
        }
    }
    func testCommandDrainsLargeOutputAndCancellationKillsChild() throws {
        let script = root.appendingPathComponent("large-output")
        try Data("#!/bin/sh\n/usr/bin/yes synthetic | /usr/bin/head -c 400000\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let output = try runPhoneCommand(script, [], nil, CancellationToken()) { _ in }
        XCTAssertEqual(output.code, 0)
        XCTAssertLessThanOrEqual(output.output.utf8.count, 262144)
        let token = CancellationToken()
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try token.launch(child); token.cancel()
        XCTAssertFalse(child.isRunning)
        let later = Process(); later.executableURL = URL(fileURLWithPath: "/bin/sleep"); later.arguments = ["60"]
        XCTAssertThrowsError(try token.launch(later))
    }
    func testEncryptedBackupUnlockAndRealExport() throws {
        guard let reader = ProcessInfo.processInfo.environment["MESSAGE_ARCHIVE_TEST_BACKUP_READER"],
              let engine = ProcessInfo.processInfo.environment["MESSAGE_ARCHIVE_TEST_ENGINE"] else { throw XCTSkip("Set both integration tool paths") }
        let demo = try DemoLibrary.make(); defer { try? FileManager.default.removeItem(at: demo.deletingLastPathComponent()) }
        let backup = root.appendingPathComponent("encrypted")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/make-encrypted-fixture.py")
        let make = Process(); make.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        make.arguments = ["python3",script.path,demo.deletingLastPathComponent().path,backup.path]
        try make.run(); make.waitUntilExit(); XCTAssertEqual(make.terminationStatus, 0)
        let before = try Data(contentsOf: backup.appendingPathComponent("Manifest.db"))
        let service = PhoneBackup(tools: URL(fileURLWithPath: reader).deletingLastPathComponent())
        let dest = root.appendingPathComponent("decrypted")
        try service.unlock(source: backup, destination: dest, password: "synthetic-fixture-password", token: CancellationToken()) { _ in }
        XCTAssertFalse(try PhoneBackup.encrypted(dest))
        let source = try Source.resolve(dest)
        XCTAssertEqual(try Library.backupContacts(dest)[normalize("+15550001001")], "Avery Example")
        let chat = try XCTUnwrap(Library.load(source).first { $0.id == 1 })
        let result = try Exporter(engine: URL(fileURLWithPath: engine)).export(source: source, chat: chat, parent: root, token: CancellationToken()) { _ in }
        XCTAssertEqual(result.records, 8); XCTAssertEqual(result.copiedAttachments, 1)
        XCTAssertFalse(result.needsAttention, "\(result.warnings)")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.folder.appendingPathComponent("messages.json"))) as! [String: Any]
        let attachment = try XCTUnwrap((json["attachments"] as? [[String: Any]])?.first?["exported_path"] as? String)
        XCTAssertEqual(try Data(contentsOf: result.folder.appendingPathComponent(attachment)), try Data(contentsOf: demo.deletingLastPathComponent().appendingPathComponent("Itinerary.txt")))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("Manifest.db")), before)
        let rejected = root.appendingPathComponent("wrong-password")
        XCTAssertThrowsError(try service.unlock(source: backup, destination: rejected, password: "wrong", token: CancellationToken()) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("crabapple-Manifest.db").path))
    }
}
