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
    private var names: [String: String] = [:]
    private var token: CancellationToken?

    var selectedChat: Conversation? { conversations.first { $0.id == selection } }
    var filtered: [Conversation] {
        search.isEmpty ? conversations : conversations.filter { $0.searchText.localizedCaseInsensitiveContains(search) }
    }
    func openMac() { load(Source.macMessages) }
    func openDemo() {
        do { load(try DemoLibrary.make()) } catch { self.error = error.localizedDescription }
    }
    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Messages database or iPhone backup"
        panel.message = "Select chat.db, or the device backup folder containing Manifest.db. Encrypted backups are not supported yet."
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        guard !busy else { return }
        busy = true; status = "Reading the conversation list…"; error = nil; result = nil; zipURL = nil
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
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        guard let engine = Bundle.main.url(forResource: "imessage-exporter", withExtension: nil) else {
            error = "The export engine is missing. Use the packaged Message Archive.app instead of the bare development executable."
            return
        }
        let cancellation = CancellationToken()
        token = cancellation; busy = true; status = "Starting export…"; result = nil; zipURL = nil; error = nil
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
            busy = false; token = nil
        }
    }
    func cancel() { token?.cancel(); status = "Stopping export…" }
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
