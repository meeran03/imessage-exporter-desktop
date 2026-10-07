import SwiftUI
import AppKit
import ArchiveCore

@main struct MessageArchiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("iMessage Exporter") {
            ArchiveWindow(model: model)
                .frame(minWidth: 880, minHeight: 600)
                .task {
                    if CommandLine.arguments.contains("--demo"), model.source == nil {
                        do { model.load(try DemoLibrary.make()) } catch { model.error = error.localizedDescription }
                    }
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Mac Messages", action: model.openMac).keyboardShortcut("o").disabled(model.busy)
                Button("Choose a Database or Backup…", action: model.chooseSource).disabled(model.busy)
                Button("Open Sample Library", action: model.openDemo).disabled(model.busy)
            }
            CommandGroup(after: .appInfo) {
                Button("Open-Source License") {
                    if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(url) }
                }
                Button("Project on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/meeranmalik/imessage-exporter-desktop")!) }
            }
            CommandMenu("Export") {
                Button("Export Selected Conversation…", action: model.startExport)
                    .keyboardShortcut("e").disabled(model.busy || model.selectedChat == nil)
                Button("Use Contact Names…", action: model.loadContactNames).disabled(model.busy)
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ArchiveWindow: View {
    @ObservedObject var model: AppModel
    private let accent = Color(red: 0.08, green: 0.42, blue: 0.45)
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 320).frame(maxHeight: .infinity, alignment: .top)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(accent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Label("iMessage Exporter", systemImage: "archivebox").font(.headline)
            }
            ToolbarItemGroup {
                if model.isDemo { Text("Sample library").font(.caption).foregroundStyle(.orange) }
                Menu {
                    Button("Messages on this Mac", action: model.openMac)
                    Button("Choose a Database or Backup…", action: model.chooseSource)
                    Button("Open Sample Library", action: model.openDemo)
                    Divider()
                    Button("Use Contact Names…", action: model.loadContactNames)
                    Button("Find iPhone Backups", action: model.showBackups)
                } label: { Label("Source", systemImage: "externaldrive") }
                .disabled(model.busy)
            }
        }
        .alert("iMessage Exporter", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
            if model.error?.contains("Full Disk Access") == true { Button("Open Privacy Settings", action: model.openPermissions) }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Conversations").font(.title3.weight(.semibold))
                    Spacer()
                    if model.source != nil { Text(model.conversations.count.formatted()).font(.caption).foregroundStyle(.secondary) }
                }
                TextField("Search names, numbers, or emails", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search conversations")
            }.padding(18)
            if model.source == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Your conversations will appear here.").font(.callout).foregroundStyle(.secondary)
                }.padding(22)
                Spacer()
            } else {
                List(selection: $model.selection) {
                    ForEach(model.filtered) { conversation in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: conversation.isGroup ? "person.2.fill" : "bubble.left.fill")
                                .font(.system(size: 14)).foregroundStyle(accent)
                                .frame(width: 32, height: 32)
                                .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                HStack {
                                    Text("\(conversation.count.formatted()) records")
                                    Spacer()
                                    if let date = conversation.lastDate { Text(date, format: .dateTime.month(.abbreviated).day()) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7).tag(conversation.id)
                    }
                }.listStyle(.sidebar).overlay {
                    if model.filtered.isEmpty && !model.busy { Text("No matching conversations").foregroundStyle(.secondary) }
                }.disabled(model.busy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Label(model.source?.backup == nil ? "Local to this Mac" : "Local iPhone backup", systemImage: "lock.shield")
                    .font(.caption.weight(.medium))
                Text("No account. No uploads. No analytics.").font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    @ViewBuilder private var detail: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: result.needsAttention ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(result.needsAttention ? .orange : accent)
                Text(result.needsAttention ? "Exported with some missing content" : "Your conversation is saved.")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("\(result.records.formatted()) records and \(result.copiedAttachments.formatted()) of \(result.attachments.formatted()) original attachments.")
                    .foregroundStyle(.secondary)
                if result.needsAttention {
                    Text("Check export-report.json for missing attachments, undecoded text, or transcript errors.").font(.callout)
                }
                Text(result.folder.lastPathComponent).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 12) {
                    Button("Open Conversation", action: model.openTranscript).buttonStyle(.borderedProminent).controlSize(.large)
                    Button(model.zipURL == nil ? "Show Folder" : "Show ZIP in Finder", action: model.showOutput).controlSize(.large)
                }
                Button("Export Another Conversation") { model.result = nil; model.zipURL = nil }
            }.frame(maxWidth: 530, alignment: .leading).padding(48)
        } else if model.busy {
            VStack(spacing: 20) {
                ProgressView().controlSize(.large)
                Text(model.status).font(.title3)
                Text("Keep the source available until the export finishes.").font(.callout).foregroundStyle(.secondary)
                if model.selectedChat != nil { Button("Cancel Export", action: model.cancel) }
            }.padding(40)
        } else if let chat = model.selectedChat {
            VStack(alignment: .leading, spacing: 24) {
                Label(chat.isGroup ? "Group conversation" : "Conversation", systemImage: chat.isGroup ? "person.2" : "bubble.left")
                    .font(.callout).foregroundStyle(.secondary)
                Text(chat.title).font(.system(size: 32, weight: .semibold, design: .rounded)).lineLimit(3)
                if chat.title != chat.participants.joined(separator: ", ") {
                    Text(chat.participants.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(spacing: 32) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(chat.count.formatted()).font(.title2.weight(.semibold))
                        Text("Message records").font(.caption).foregroundStyle(.secondary)
                    }
                    if let first = chat.firstDate, let last = chat.lastDate {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(first.formatted(date: .abbreviated, time: .omitted) + " to " + last.formatted(date: .abbreviated, time: .omitted)).font(.callout.weight(.medium))
                            Text("Available in this source").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    exportLine("Readable conversation", "HTML with supported reactions, replies, and edits", "text.bubble")
                    exportLine("Original attachments", "Photos, videos, audio, and files are copied by default", "paperclip")
                    exportLine("Text, JSON, and an export report", "Searchable copies, structured data, and missing-content details", "doc.text")
                }
                Toggle("Also create a ZIP to keep or share", isOn: $model.makeZIP).font(.callout)
                Button(action: model.startExport) { Label("Export Conversation…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("e")
                Text("Only this thread is exported. The source stays unchanged.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 580, alignment: .leading).padding(44)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 52, weight: .light)).foregroundStyle(accent)
                Text(model.source == nil ? "Keep a copy of your conversations." : "Pick a conversation to keep.")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(model.source == nil ? "Choose Messages on your Mac or an existing iPhone backup. Export a chat with its original photos, videos, audio, and files." :
                     "Search the list on the left, then select one thread. You can export it with all the attachments available in this source.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
                if model.source == nil {
                    HStack(spacing: 12) {
                        Button("Open Mac Messages", action: model.openMac).buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Choose iPhone Backup…", action: model.chooseSource).controlSize(.large)
                    }
                    Button("Try a Sample Library", action: model.openDemo).buttonStyle(.link)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("Mac Messages requires Full Disk Access.", systemImage: "lock")
                    Button("Open Privacy Settings", action: model.openPermissions)
                    Text("A paired iPhone needs a completed local backup. This version supports unencrypted backups; keep encryption enabled and use Mac sync if yours is encrypted.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Find iPhone Backups", action: model.showBackups)
                }.font(.callout)
                if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(.secondary) }
            }.frame(maxWidth: 540, alignment: .leading).padding(48)
        }
    }
    private func exportLine(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
