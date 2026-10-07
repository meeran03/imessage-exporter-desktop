import AppKit
import ArchiveCore
import Contacts
import SwiftUI

@MainActor final class AppModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selection: Int64?
    @Published var search = ""
    @Published var source: Source?
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var result: ExportResult?
    @Published var zipURL: URL?
    @Published var makeZIP = true
    @Published var isDemo = false
    @Published var phoneSheet = false
    @Published var passwordSheet = false
    @Published var phones: [ConnectedPhone] = []
    @Published var phoneSelection: String?
    @Published var backupPassword = ""
    @Published var pendingEncryptedBackup: URL?
    @Published var lastPhoneBackup: URL?
    @Published var canCancel = false
    @Published var snapshotDate: Date?
    private var names: [String: String] = [:]
    private var token: CancellationToken?
    private var encryptedWorkspace: URL?

    private var phoneService: PhoneBackup {
        PhoneBackup(tools: Bundle.main.resourceURL!.appendingPathComponent("iphone/bin"))
    }
    func cleanup() {
        token?.cancel()
        if let encryptedWorkspace { try? FileManager.default.removeItem(at: encryptedWorkspace) }
        encryptedWorkspace = nil
    }
    func connectPhone() {
        guard !busy else { return }
        phoneSheet = true
        refreshPhones()
    }
    func refreshPhones() {
        guard !busy else { return }
        let service = phoneService; let cancellation = CancellationToken()
        token = cancellation; busy = true; canCancel = true; status = "Looking for USB-connected iPhones…"
        Task {
            do {
                phones = try await Task.detached { try service.devices(token: cancellation) }.value
                if !phones.contains(where: { $0.id == phoneSelection }) { phoneSelection = phones.first?.id }
            } catch { phoneSheet = false; self.error = error is CancellationError ? "Device lookup cancelled." : error.localizedDescription }
            busy = false; canCancel = false; token = nil; status = ""
        }
    }
    func startPhoneBackup() {
        guard let phone = phones.first(where: { $0.id == phoneSelection }), !busy else { return }
        phoneSheet = false
        let panel = NSOpenPanel()
        panel.title = "Choose where to save the full iPhone backup"
        panel.message = "This creates a fresh device backup, including data beyond Messages. Existing encryption stays enabled. The backup remains here until you delete it."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        present(panel) { parent in self.performPhoneBackup(phone: phone, parent: parent) }
    }
    private func performPhoneBackup(phone: ConnectedPhone, parent: URL) {
        guard !busy else { return }
        cleanup(); source = nil; conversations = []; selection = nil; result = nil; zipURL = nil
        pendingEncryptedBackup = nil; snapshotDate = nil; lastPhoneBackup = nil
        let cancellation = CancellationToken(); let service = phoneService
        token = cancellation; busy = true; canCancel = true; isDemo = false; error = nil
        Task {
            do {
                let backup = try await Task.detached { [self] in
                    try service.create(device: phone, parent: parent, token: cancellation) { label in
                        Task { @MainActor in self.status = label }
                    }
                }.value
                try cancellation.check()
                lastPhoneBackup = backup; snapshotDate = Date()
                busy = false; canCancel = false; token = nil; status = ""
                openBackup(backup)
            } catch {
                self.error = error.localizedDescription
                busy = false; canCancel = false; token = nil; status = ""
            }
        }
    }
    func openBackup(_ url: URL) {
        guard !busy else { return }
        do {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Manifest.plist").path),
               try PhoneBackup.encrypted(url) {
                try PhoneBackup.validateCompleted(url)
                cleanup(); source = nil; conversations = []; selection = nil; result = nil; zipURL = nil
                pendingEncryptedBackup = url; backupPassword = ""; passwordSheet = true
            } else { pendingEncryptedBackup = nil; load(url) }
        } catch { self.error = error.localizedDescription }
    }
    func unlockBackup() {
        guard let original = pendingEncryptedBackup, !backupPassword.isEmpty, !busy else { return }
        let password = backupPassword; backupPassword = ""; passwordSheet = false
        let cancellation = CancellationToken(); let service = phoneService
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("imessage-encrypted-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { self.error = error.localizedDescription; return }
        encryptedWorkspace = work
        let destination = work.appendingPathComponent("messages")
        token = cancellation; busy = true; canCancel = true
        Task {
            do {
                try await Task.detached { [self] in
                    try service.unlock(source: original, destination: destination, password: password, token: cancellation) { label in
                        Task { @MainActor in self.status = label }
                    }
                }.value
                try cancellation.check()
                pendingEncryptedBackup = nil; busy = false; canCancel = false; token = nil
                load(destination)
            } catch {
                cleanup(); self.error = error is CancellationError ? "Reading the encrypted backup was cancelled." : error.localizedDescription
                busy = false; canCancel = false; token = nil; status = ""
            }
        }
    }

    var selectedChat: Conversation? { conversations.first { $0.id == selection } }
    var filtered: [Conversation] {
        search.isEmpty ? conversations : conversations.filter { $0.searchText.localizedCaseInsensitiveContains(search) }
    }
    func openMac() { snapshotDate = nil; pendingEncryptedBackup = nil; backupPassword = ""; load(Source.macMessages) }
    func openDemo() {
        snapshotDate = nil; pendingEncryptedBackup = nil; backupPassword = ""
        do { load(try DemoLibrary.make()) } catch { self.error = error.localizedDescription }
    }
    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Messages database or iPhone backup"
        panel.message = "Select chat.db, or the device backup folder containing Manifest.db. Encrypted backups require their backup password."
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        present(panel) { url in self.snapshotDate = nil; self.openBackup(url) }
    }
    private func present(_ panel: NSOpenPanel, chosen: @escaping @MainActor (URL) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in chosen(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    func load(_ url: URL) {
        guard !busy else { return }
        if let encryptedWorkspace, !url.resolvingSymlinksInPath().path.hasPrefix(encryptedWorkspace.path + "/") { cleanup() }
        busy = true; status = "Reading the conversation list…"; error = nil; result = nil; zipURL = nil
        source = nil; conversations = []; selection = nil
        let contactNames = names
        Task {
            do {
                let library = try await Task.detached(priority: .userInitiated) {
                    let source = try Source.resolve(url)
                    return (source, try Library.load(source, contactNames: contactNames))
                }.value
                source = library.0; conversations = library.1; selection = nil; search = ""
                if library.1.isEmpty { status = "No conversations were found in this source." } else { status = "" }
                isDemo = url.path.contains("message-archive-demo-")
            } catch { self.error = error.localizedDescription; status = "" }
            busy = false
        }
    }
    func loadContactNames() {
        guard !busy else { return }
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, requestError in
            Task { @MainActor in
                guard granted else {
                    self.error = requestError?.localizedDescription ?? "Contacts access wasn't granted. You can still search chats by phone number or email."
                    return
                }
                var lookup: [String: String] = [:]
                do {
                    let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey, CNContactFamilyNameKey,
                        CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor])
                    try CNContactStore().enumerateContacts(with: request) { contact, _ in
                        let personal = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                        let fullName = personal.isEmpty ? contact.organizationName : personal
                        guard !fullName.isEmpty else { return }
                        for phone in contact.phoneNumbers { lookup[normalize(phone.value.stringValue)] = fullName }
                        for email in contact.emailAddresses { lookup[normalize(email.value as String)] = fullName }
                    }
                    self.names = lookup
                    if let source = self.source { self.load(source.location) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func startExport() {
        guard let source, let chat = selectedChat, !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where to save this conversation"
        panel.message = "A new folder will contain the transcripts, original attachments, and export report."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        present(panel) { parent in self.performExport(source: source, chat: chat, parent: parent) }
    }
    private func performExport(source: Source, chat: Conversation, parent: URL) {
        guard !busy else { return }
        guard let engine = Bundle.main.url(forResource: "imessage-exporter", withExtension: nil) else {
            error = "The export engine is missing. Use the packaged iMessage Exporter.app instead of the bare development executable."
            return
        }
        let cancellation = CancellationToken()
        token = cancellation; busy = true; canCancel = true; status = "Starting export…"; result = nil; zipURL = nil; error = nil
        let zip = makeZIP
        Task {
            do {
                let export = try await Task.detached(priority: .userInitiated) { [self] in
                    let result = try Exporter(engine: engine).export(source: source, chat: chat, parent: parent, token: cancellation) { label in
                        Task { @MainActor in self.status = label }
                    }
                    var archiveURL: URL?
                    if zip {
                        try cancellation.check()
                        Task { @MainActor in self.status = "Packaging the conversation as a ZIP…" }
                        let archive = result.folder.appendingPathExtension("zip")
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        process.arguments = ["-c", "-k", "--keepParent", result.folder.path, archive.path]
                        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                        try process.run()
                        while process.isRunning {
                            do { try cancellation.check() } catch {
                                process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at: archive)
                                throw error
                            }
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else {
                            try? FileManager.default.removeItem(at: archive)
                            throw ArchiveError.message("The folder was exported, but ZIP creation failed. Your exported files are in \(result.folder.path).")
                        }
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
                        archiveURL = archive
                    }
                    return (result, archiveURL)
                }.value
                result = export.0; zipURL = export.1; status = ""
            } catch {
                self.error = error is CancellationError ? "ZIP creation cancelled. The exported conversation folder was kept." : error.localizedDescription
                status = ""
            }
            busy = false; canCancel = false; token = nil
        }
    }
    func cancel() { token?.cancel(); status = "Stopping…" }
    func showOutput() { if let result { NSWorkspace.shared.activateFileViewerSelecting([zipURL ?? result.folder]) } }
    func openTranscript() {
        if let result {
            let index = result.folder.appendingPathComponent("conversation.html")
            if FileManager.default.fileExists(atPath: index.path) { NSWorkspace.shared.open(index) }
        }
    }
    func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
    func showBackups() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) }
        else { error = "No Finder backup folder exists yet. Connect your iPhone, open Finder, select the phone, and make a local backup. Keep existing backup encryption settings enabled." }
    }
}
