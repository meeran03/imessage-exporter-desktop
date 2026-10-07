import Foundation

public struct ConnectedPhone: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct PhoneCommandResult: Sendable {
    public let code: Int32
    public let output: String
    public init(code: Int32, output: String) { self.code = code; self.output = output }
}
public typealias PhoneRunner = @Sendable (URL, [String], String?, CancellationToken, @escaping @Sendable (String) -> Void) throws -> PhoneCommandResult

public struct PhoneBackup: Sendable {
    let tools: URL
    let runner: PhoneRunner
    public init(tools: URL, runner: @escaping PhoneRunner = { executable, arguments, input, token, progress in
        try runPhoneCommand(executable, arguments, input, token, progress)
    }) {
        self.tools = tools; self.runner = runner
    }
    func run(_ tool: String, _ arguments: [String], input: String? = nil, token: CancellationToken,
             progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> PhoneCommandResult {
        try token.check()
        return try runner(tools.appendingPathComponent(tool), arguments, input, token, progress)
    }
    public func devices(token: CancellationToken) throws -> [ConnectedPhone] {
        let result = try run("idevice_id", ["-l"], token: token)
        guard result.code == 0 else { throw ArchiveError.message("Could not detect iPhones. Connect by USB, unlock the phone, and try again.") }
        return try result.output.split(whereSeparator: \.isNewline).map { line in
            let id = String(line).trimmingCharacters(in: .whitespaces)
            guard Self.validDeviceID(id) else { throw ArchiveError.message("The device service returned an invalid iPhone identifier.") }
            let info = try run("ideviceinfo", ["-u", id, "-k", "DeviceName"], token: token)
            let name = info.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConnectedPhone(id: id, name: info.code == 0 && !name.isEmpty ? name : "iPhone")
        }
    }
    public func create(device: ConnectedPhone, parent: URL, token: CancellationToken,
                       progress: @escaping @Sendable (String) -> Void) throws -> URL {
        guard Self.validDeviceID(device.id) else { throw ArchiveError.message("Invalid iPhone identifier.") }
        progress("Checking iPhone pairing. Unlock your phone and approve Trust if asked…")
        let validation = try run("idevicepair", ["-u", device.id, "validate"], token: token)
        if validation.code != 0 {
            let pairing = try run("idevicepair", ["-u", device.id, "pair"], token: token)
            guard pairing.code == 0 else { throw ArchiveError.message("Unlock your iPhone and tap Trust on the phone, then try again.") }
        }
        try token.check()
        let root = parent.appendingPathComponent("iPhone-Backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            progress("Creating a fresh backup. Keep your iPhone connected and approve any passcode prompt…")
            let result = try run("idevicebackup2", ["-u", device.id, "backup", "--full", root.path], token: token, progress: { label in
                // Do not surface raw paths, app names, or message data from tool output in the UI.
                if let percentage = Self.progressPercent(label) { progress("Backing up iPhone: \(percentage)% · Keep it connected…") }
            })
            try token.check()
            guard result.code == 0 else { throw ArchiveError.message("Backup failed. Check the phone for a passcode prompt, reconnect it, and try again.") }
            let backup = root.appendingPathComponent(device.id)
            try Self.validateCompleted(backup)
            try token.check()
            return backup
        } catch {
            throw ArchiveError.message((error is CancellationError ? "Backup cancelled." : error.localizedDescription) + " The partial backup is in \(root.path). It has not been loaded as current Messages.")
        }
    }
    public func unlock(source: URL, destination: URL, password: String, token: CancellationToken,
                       progress: @escaping @Sendable (String) -> Void) throws {
        try Self.validateCompleted(source)
        guard !password.isEmpty else { throw ArchiveError.message("Enter the backup encryption password.") }
        do {
            progress("Unlocking the Messages files in this backup…")
            let result = try run("backup-reader", [source.path, destination.path], input: password, token: token, progress: { _ in
                progress("Reading encrypted Messages and attachments…")
            })
            try token.check()
            guard result.code == 0 else { throw ArchiveError.message("The backup could not be unlocked. Check its backup encryption password and try again.") }
            _ = try Source.resolve(destination)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    public static func encrypted(_ source: URL) throws -> Bool {
        let data = try Data(contentsOf: source.appendingPathComponent("Manifest.plist"))
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let encrypted = dictionary["IsEncrypted"] as? Bool else { throw ArchiveError.message("Invalid iPhone backup manifest.") }
        return encrypted
    }
    public static func validateCompleted(_ source: URL) throws {
        let data = try Data(contentsOf: source.appendingPathComponent("Status.plist"))
        let status = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard status?["SnapshotState"] as? String == "finished",
              FileManager.default.fileExists(atPath: source.appendingPathComponent("Manifest.db").path) else {
            throw ArchiveError.message("The iPhone backup is unfinished. Only a successfully completed backup can be loaded.")
        }
        _ = try encrypted(source)
    }
    static func validDeviceID(_ id: String) -> Bool {
        (16...80).contains(id.count) && id.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45 }
    }
    static func progressPercent(_ output: String) -> Int? {
        let pattern = #"(?:^|\s)(\d{1,3})(?:\.\d+)?\s*%"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
              let range = Range(match.range(at: 1), in: output), let value = Int(output[range]), (0...100).contains(value) else { return nil }
        return value
    }
}

/// Drain both output streams together so large backups cannot deadlock a full pipe.
/// Passwords travel through stdin, never argv, environment variables, or saved logs.
public func runPhoneCommand(_ executable: URL, _ arguments: [String], _ input: String?, _ token: CancellationToken,
                            _ progress: @escaping @Sendable (String) -> Void) throws -> PhoneCommandResult {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw ArchiveError.message("The bundled iPhone tools are missing. Download the complete iMessage Exporter app.")
    }
    let process = Process(); let pipe = Pipe(); let stdin = Pipe()
    process.executableURL = executable; process.arguments = arguments
    process.standardOutput = pipe; process.standardError = pipe
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    if executable.lastPathComponent == "backup-reader", arguments.count == 2 {
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = URL(fileURLWithPath: arguments[1]).deletingLastPathComponent().path
        process.environment = environment
    }
    let collected = PhoneOutput()
    let drained = DispatchGroup()
    defer { try? pipe.fileHandleForReading.close() }
    try token.launch(process)
    defer { token.finished(process) }
    try? pipe.fileHandleForWriting.close()
    drained.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { drained.leave() }
        while let data = try? pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
            collected.append(data); progress(String(decoding: data, as: UTF8.self))
        }
    }
    if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try stdin.fileHandleForWriting.close() }
    do {
        while process.isRunning { try token.check(); Thread.sleep(forTimeInterval: 0.1) }
        process.waitUntilExit(); try token.check()
    } catch {
        process.terminate()
        // Never let a stalled USB service trap cancellation indefinitely.
        for _ in 0..<30 where process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit(); throw error
    }
    guard drained.wait(timeout: .now() + 2) == .success else { throw ArchiveError.message("The iPhone service did not finish responding. Reconnect the phone and try again.") }
    return PhoneCommandResult(code: process.terminationStatus, output: collected.text)
}
private final class PhoneOutput: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(value)
        if data.count > 262_144 { data.removeFirst(data.count - 262_144) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
