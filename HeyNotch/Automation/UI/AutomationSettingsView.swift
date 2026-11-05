import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsView: View {
    @ObservedObject private var access = AutomationAccessStore.shared
    @ObservedObject private var connection = AutomationCoordinator.shared
    @ObservedObject private var tasks = TaskController.shared
    @State private var name = "Codex"
    @State private var listIDs: Set<String> = []
    @State private var canWrite = true
    @State private var message: String?
    @State private var isError = false
    @State private var exportedPath: String?
    @State private var client: SetupClient = .codex

    enum SetupClient: String, CaseIterable, Identifiable {
        case codex = "Codex", claudeCode = "Claude Code", claudeDesktop = "Claude Desktop"
        var id: String { rawValue }
    }

    private var executable: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/heynotch-mcp").path }
    private var helperAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }
    private var setup: String {
        let path = exportedPath ?? "/path/to/HeyNotch-connection.json"
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        switch client {
        case .codex: return "codex mcp add heynotch -- \(quote(executable)) --connection \(quote(path))"
        case .claudeCode: return "claude mcp add --scope user heynotch -- \(quote(executable)) --connection \(quote(path))"
        case .claudeDesktop:
            let object: [String: Any] = ["mcpServers": ["heynotch": ["command": executable, "args": ["--connection", path]]]]
            return String(data: (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data(), encoding: .utf8) ?? ""
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow agents to use selected task lists", isOn: $access.enabled)
                Label(connection.status, systemImage: access.enabled ? "link" : "link.badge.plus")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Connect Codex, Claude, or another MCP client to your tasks. Each connection has its own list access and can be revoked at any time. Keep HeyNotch open while using it.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Agent access") }
            Section {
                TextField("Connection name", text: $name)
                Toggle("Allow task creation and edits", isOn: $canWrite)
                if tasks.lists.isEmpty {
                    Text("Connect Apple Reminders in Tasks settings, then choose the lists this agent may use.").foregroundStyle(.secondary)
                    Button("Refresh lists") { Task { await tasks.refresh() } }
                } else {
                    ForEach(tasks.lists) { list in
                        Toggle(isOn: Binding(get: { listIDs.contains(list.id) }, set: { included in
                            if included { listIDs.insert(list.id) } else { listIDs.remove(list.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(list.title)
                                Text("\(list.account)\(list.writable ? "" : " · Read only")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Create connection…", action: createConnection)
                    .disabled(!access.enabled || listIDs.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !helperAvailable)
                if !helperAvailable { Text("The MCP helper is missing from this build. Rebuild HeyNotch with its bundled helper.").foregroundStyle(.red) }
                Text("The exported connection file is a credential. Store it privately on this Mac. It gives access only to the selected lists; provider keys and recordings are not exposed.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("New connection") }
            if let message {
                Section { Text(message).foregroundStyle(isError ? Color.red : Color.secondary).textSelection(.enabled) }
            }
            if !access.grants.isEmpty {
                Section("Connections") {
                    ForEach(access.grants, id: \.id) { grant in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(grant.name)
                                Text("\(grant.allowedListIDs.count) lists · \(grant.canWrite ? "Read and write" : "Read only")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Export…") { export(grant.id) }
                            Button("Revoke", role: .destructive) {
                                do {
                                    try access.revoke(grant.id)
                                    message = "Connection revoked. Its exported file no longer grants access."; isError = false
                                }
                                catch { show(error) }
                                if !access.grants.contains(where: { $0.id == grant.id }) {
                                    Task { await connection.retireClient(grant.id) }
                                }
                            }
                        }
                    }
                }
            }
            Section("Connect your client") {
                Picker("Client", selection: $client) { ForEach(SetupClient.allCases) { Text($0.rawValue).tag($0) } }
                Text(client == .claudeDesktop
                     ? "In Claude Desktop’s developer settings, edit the MCP configuration. Merge this entry with existing servers, then restart Claude."
                     : "Run this command in Terminal, then reopen your client. Its normal tool approval settings still apply.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(setup).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy setup") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(setup, forType: .string) }
                    .disabled(exportedPath == nil || !helperAvailable)
                Text("Install HeyNotch in Applications before configuring a client so the helper path stays stable. Try: ‘Add a task to review the proposal tomorrow in my Work list.’")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !connection.recentActivity.isEmpty {
                Section("Recent actions") { ForEach(Array(connection.recentActivity.enumerated()), id: \.offset) { _, action in Text(action).font(.callout) } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agent access")
        .task { connection.start(); await tasks.refresh() }
    }

    private func destination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save private agent connection"
        panel.message = "Choose a private folder on this Mac. Anyone who can read this file can use this connection."
        panel.nameFieldStringValue = "HeyNotch-connection.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func createConnection() {
        guard let url = destination() else { return }
        var createdID: String?
        do {
            let grant = try access.createGrant(name: name, listIDs: listIDs, canWrite: canWrite)
            createdID = grant.id
            try access.exportConnection(grant.id, to: url)
            exportedPath = url.path; message = "Connection saved. Copy the setup below into your client."; isError = false
        } catch {
            if let createdID { try? access.revoke(createdID) }
            show(error)
        }
    }
    private func export(_ id: String) {
        guard let url = destination() else { return }
        do { try access.exportConnection(id, to: url); exportedPath = url.path; message = "Connection exported. Copy the setup below into your client."; isError = false }
        catch { show(error) }
    }
    private func show(_ error: Error) { message = error.localizedDescription; isError = true }
}
