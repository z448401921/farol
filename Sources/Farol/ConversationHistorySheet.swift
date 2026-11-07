import FarolCore
import SwiftUI

struct ConversationHistorySheet: View {
    let palette: Palette
    let agents: [AgentFolder]
    let resume: (ConversationHistory.Entry) -> Void
    let close: () -> Void
    private let availableSize: CGSize

    @State private var entries: [ConversationHistory.Entry]?
    @State private var agent: AgentFolder?
    @State private var pickingAgent = false
    @State private var query = ""
    @State private var disclosed: [String: Bool] = [:]
    @State private var refreshID = UUID()
    @State private var refreshing = false
    @State private var removing: ConversationRow?
    @FocusState private var searching: Bool

    init(palette: Palette, agents: [AgentFolder], availableSize: CGSize = CGSize(width: 752, height: 560),
         resume: @escaping (ConversationHistory.Entry) -> Void, close: @escaping () -> Void) {
        self.palette = palette
        self.agents = agents
        self.availableSize = availableSize
        self.resume = resume
        self.close = close
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [FolderGroup] {
        let term = self.term
        let matches = (entries ?? []).filter { entry in
            (agent == nil || entry.agent == agent)
                && (term.isEmpty || entry.title.localizedStandardContains(term)
                    || entry.directory.localizedStandardContains(term) || entry.id.localizedStandardContains(term))
        }
        return Dictionary(grouping: matches, by: \.directory).map { directory, entries in
            FolderGroup(directory: directory, entries: entries)
        }.sorted { lhs, rhs in
            if lhs.latest != rhs.latest { return lhs.latest > rhs.latest }
            return lhs.directory.localizedStandardCompare(rhs.directory) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Conversation history", palette: palette) {
                Text("Pick a saved conversation to continue in its original folder.")
            }
            .padding(20)

            HStack(spacing: 10) {
                agentSelect
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                    TextField("Search conversations", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                }
                .sheetField(palette, focused: searching)
                IconButton(symbol: "arrow.clockwise", help: "Refresh conversation history", palette: palette) {
                    if !refreshing { refreshID = UUID() }
                }
                .accessibilityLabel("Refresh conversation history")
                .disabled(refreshing)
            }
            .disabled(agents.isEmpty)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            divider
            results.frame(height: min(365, max(140, availableSize.height - 195)))
            divider

            HStack {
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(SheetButton(palette: palette, primary: false))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(palette.text)
        .frame(width: min(720, availableSize.width - 32))
        .sheetBackground(palette)
        .onAppear { searching = !agents.isEmpty }
        .onChange(of: query) { _, _ in disclosed.removeAll() }
        .task(id: refreshID) { await refreshWhileOpen() }
        .alert(item: $removing) { row in
            Alert(title: Text("Remove from Farol history?"),
                  message: Text("You can still open this conversation in \(row.entry.agent.label)."),
                  primaryButton: .destructive(Text("Remove")) {
                      ConversationHistory.remove(row.entry)
                      entries = entries.map { ConversationHistory.filterRemoved(from: $0) }
                  },
                  secondaryButton: .cancel())
        }
    }

    @MainActor private func refreshWhileOpen() async {
        guard !agents.isEmpty else { return }
        let folders = agents
        while !Task.isCancelled {
            refreshing = true
            let scan = Task.detached(priority: entries == nil ? .userInitiated : .utility) {
                ConversationHistory.list(in: folders)
            }
            let snapshot = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled else { return }
            let found = ConversationHistory.filterRemoved(from: snapshot)
            if entries != found { entries = found }
            refreshing = false
            // Start the interval after each read so a large history never queues more work.
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
        }
    }

    private var agentSelect: some View {
        SheetSelect(palette: palette, open: $pickingAgent) {
            if let agent { ToolTile(agent: agent.kind, size: 16) }
            Text(agent?.label ?? "All agents").lineLimit(1)
        } choices: {
            ScrollView {
                VStack(spacing: 1) {
                    agentChoice(nil)
                    ForEach(agents, id: \.self) { option in agentChoice(option) }
                }
                .padding(6)
            }
            .frame(width: 220, height: min(250, 29 * CGFloat(agents.count + 1) + 12))
        }
        .frame(width: 165)
    }

    private func agentChoice(_ option: AgentFolder?) -> some View {
        SheetChoice(palette: palette) {
            agent = option
            disclosed.removeAll()
            pickingAgent = false
        } label: {
            if let option { ToolTile(agent: option.kind, size: 16) }
            Text(option?.label ?? "All agents").lineLimit(1)
            Spacer()
            if option == agent {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
            }
        }
    }

    @ViewBuilder private var results: some View {
        if agents.isEmpty {
            EmptyState(symbol: "bubble.left.and.bubble.right", text: "Set up an agent in Settings to see its conversations.", palette: palette)
        } else if entries == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading conversation history…").foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = self.groups
            if groups.isEmpty {
                EmptyState(symbol: "bubble.left.and.bubble.right",
                           text: term.isEmpty ? "No saved conversations." : "No conversations match your search.", palette: palette)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            let open = disclosed[group.directory] ?? (!term.isEmpty || group.id == groups.first?.id)
                            Section {
                                if open {
                                    ForEach(group.entries.map(ConversationRow.init)) { row in
                                        conversation(row.entry)
                                    }
                                }
                            } header: {
                                folder(group, open: open)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func folder(_ group: FolderGroup, open: Bool) -> some View {
        SheetChoice(palette: palette) {
            disclosed[group.directory] = !open
        } label: {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.muted)
                .frame(width: 12)
            Text(URL(fileURLWithPath: group.directory).lastPathComponent)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text((group.directory as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(group.entries.count.formatted())
                .monospacedDigit()
                .foregroundStyle(palette.muted)
                .accessibilityLabel("\(group.entries.count) conversations")
        }
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .help(group.directory)
        .padding(.vertical, 4)
    }

    private func conversation(_ entry: ConversationHistory.Entry) -> some View {
        VStack(spacing: 0) {
            divider
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .help(entry.title)
                    HStack(spacing: 8) {
                        if agent == nil { Text(entry.agent.label) }
                        Text(entry.updated.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                Button("Continue") { resume(entry) }
                    .buttonStyle(SheetButton(palette: palette, primary: false))
                    .accessibilityLabel("Continue \(entry.title)")
                IconButton(symbol: "trash", help: "Remove from Farol history", palette: palette) {
                    removing = ConversationRow(entry: entry)
                }
                .accessibilityLabel("Remove \(entry.title) from Farol history")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .padding(.leading, 24)
    }

    private var divider: some View { Rectangle().fill(palette.line).frame(height: 1) }

    private struct FolderGroup: Identifiable {
        let directory: String
        let entries: [ConversationHistory.Entry]

        var id: String { directory }
        var latest: Date { entries.first?.updated ?? .distantPast }
    }

    private struct ConversationRow: Identifiable {
        struct ID: Hashable {
            let agent: AgentFolder
            let session: String
        }

        let entry: ConversationHistory.Entry
        var id: ID { ID(agent: entry.agent, session: entry.id) }
    }
}
