import SwiftUI
import TenonCore

private struct QuickCommandEditorItem: Identifiable {
    enum Mode { case add, edit }

    let mode: Mode
    let command: QuickCommand
    var id: UUID { command.id }
}

/// Runbooks use the same compact desktop scale as Tenon's launcher and prompt chrome.
/// Keeping the budget explicit prevents this focused utility from drifting back into a
/// full-screen, card-heavy presentation.
enum RunbookMetrics {
    static let libraryWidth: CGFloat = 320
    static let editorWidth: CGFloat = 480
    static let editorHeight: CGFloat = 460
    static let controlHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 6
    static let libraryHeaderHeight: CGFloat = 36
    static let editorHeaderHeight: CGFloat = 44
    static let editorFooterHeight: CGFloat = 44
    static let libraryRowHeight: CGFloat = 38
    static let libraryListPadding: CGFloat = 10
    static let maximumLibraryListHeight: CGFloat = 280
    static let editorBodyHeight: CGFloat = 76
    static let contentInset: CGFloat = 14
    static let sectionSpacing: CGFloat = 10

    static func libraryListHeight(rows: Int) -> CGFloat {
        min(
            CGFloat(max(0, rows)) * libraryRowHeight + libraryListPadding,
            maximumLibraryListHeight
        )
    }
}

struct QuickCommandControl: View {
    var commands: QuickCommandStore
    var workspaceStore: WorkspaceStore
    var terminalPool: SurfacePool

    @State private var menuPresented = false
    @State private var query = ""
    @State private var editorItem: QuickCommandEditorItem?
    @State private var pendingDelete: QuickCommand?
    @FocusState private var searchFocused: Bool

    private var activeWorkspace: Workspace? {
        workspaceStore.catalog.activeWorkspace
    }

    private var projectPath: String? {
        activeWorkspace?.path.standardizedFileURL.path
    }

    var body: some View {
        Button {
            menuPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TenonTheme.amber)
                    .accessibilityHidden(true)
                Text("Runbooks")
                    .font(TenonTheme.interfaceFont(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(TenonTheme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TenonTheme.text)
        .background(TenonTheme.chromeRaised, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(TenonTheme.line, lineWidth: 1)
        }
        .help("Open personal runbooks")
        .accessibilityLabel("Open runbooks")
        .popover(isPresented: $menuPresented, arrowEdge: .bottom) {
            runbookLibrary
        }
        .sheet(item: $editorItem) { item in
            QuickCommandEditor(
                mode: item.mode,
                command: item.command,
                commands: commands,
                workspace: activeWorkspace
            )
        }
        .confirmationDialog(
            "Delete Runbook?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    commands.delete(pendingDelete.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map { "Delete “\($0.label)”?" } ?? "")
        }
    }

    private var runbookLibrary: some View {
        let matches = commands.ranked(query: query, projectPath: projectPath)

        return VStack(spacing: 0) {
            libraryHeader

            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)

            searchField

            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)

            if matches.isEmpty {
                RunbookEmptyState(
                    hasQuery: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    create: presentNewRunbook
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { command in
                            RunbookLibraryRow(
                                command: command,
                                isRecent: command.id == commands.recentCommandID,
                                run: { run(command) },
                                edit: { presentEditor(command, mode: .edit) },
                                delete: {
                                    menuPresented = false
                                    pendingDelete = command
                                }
                            )
                        }
                    }
                    .padding(.vertical, 5)
                }
                .frame(height: RunbookMetrics.libraryListHeight(rows: matches.count))
            }
        }
        .frame(width: RunbookMetrics.libraryWidth)
        .background(TenonTheme.chromeRaised)
        .foregroundStyle(TenonTheme.text)
        .defaultFocus($searchFocused, true)
        .onDisappear {
            query = ""
            searchFocused = false
        }
        .accessibilityIdentifier("tenon.quickCommands.library")
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TenonTheme.amber)
                .frame(width: 15)
                .accessibilityHidden(true)

            Text("Runbooks")
                .font(TenonTheme.interfaceFont(size: 12, weight: .semibold))

            Text(activeWorkspace.map { "· \($0.name)" } ?? "· Personal")
                .font(TenonTheme.utilityFont(size: 9))
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(action: presentNewRunbook) {
                Label("New Runbook", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(TenonTheme.amber)
            .background(TenonTheme.amber.opacity(0.10), in: .rect(cornerRadius: 6))
            .help("Create a runbook")
            .accessibilityLabel("Create a runbook")
            .accessibilityIdentifier("tenon.quickCommands.add")
        }
        .padding(.horizontal, 12)
        .frame(height: RunbookMetrics.libraryHeaderHeight)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(TenonTheme.muted)
                .accessibilityHidden(true)
            TextField("Find a runbook…", text: $query)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 12))
                .focused($searchFocused)
                .onSubmit {
                    if let first = commands.ranked(
                        query: query,
                        projectPath: projectPath
                    ).first {
                        run(first)
                    }
                }
                .accessibilityIdentifier("tenon.quickCommands.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TenonTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func run(_ command: QuickCommand) {
        guard QuickCommandExecutor.run(
            command,
            workspaceStore: workspaceStore,
            terminalPool: terminalPool
        ) else { return }
        commands.recordRun(command.id)
        menuPresented = false
    }

    private func presentNewRunbook() {
        presentEditor(
            QuickCommand(
                scope: activeWorkspace
                    .map { QuickCommandScope.project($0.path) }
                    ?? .global
            ),
            mode: .add
        )
    }

    private func presentEditor(
        _ command: QuickCommand,
        mode: QuickCommandEditorItem.Mode
    ) {
        menuPresented = false
        Task { @MainActor in
            await Task.yield()
            editorItem = QuickCommandEditorItem(mode: mode, command: command)
        }
    }
}

private struct RunbookLibraryRow: View {
    let command: QuickCommand
    let isRecent: Bool
    let run: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: run) {
                HStack(spacing: 8) {
                    Image(systemName: command.runner.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? TenonTheme.amber : TenonTheme.muted)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(command.label)
                                .font(TenonTheme.interfaceFont(size: 11.5, weight: .medium))
                                .lineLimit(1)
                            if isRecent {
                                Text("RECENT")
                                    .font(TenonTheme.utilityFont(size: 7, weight: .semibold))
                                    .foregroundStyle(TenonTheme.amber)
                            }
                        }
                        Text(command.subtitle)
                            .font(TenonTheme.utilityFont(size: 9))
                            .foregroundStyle(TenonTheme.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if command.scope.projectPath != nil {
                        Image(systemName: "scope")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TenonTheme.muted)
                            .help("Only available in this project")
                    }

                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(hovering ? TenonTheme.amber : TenonTheme.muted)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .frame(
                    maxWidth: .infinity,
                    minHeight: RunbookMetrics.libraryRowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run \(command.label)")

            Menu {
                Button("Edit", systemImage: "pencil", action: edit)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(TenonTheme.muted)
            .help("Runbook actions")
            .accessibilityLabel("Actions for \(command.label)")
        }
        .padding(.trailing, 6)
        .background(
            hovering ? TenonTheme.text.opacity(0.06) : Color.clear,
            in: .rect(cornerRadius: RunbookMetrics.cornerRadius)
        )
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

private struct RunbookEmptyState: View {
    let hasQuery: Bool
    let create: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: hasQuery ? "magnifyingglass" : "books.vertical")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TenonTheme.muted)
                .accessibilityHidden(true)
            Text(hasQuery ? "No matching runbook" : "Turn repetition into a runbook")
                .font(TenonTheme.interfaceFont(size: 11.5, weight: .semibold))
            Text(
                hasQuery
                    ? "Try a different name, runner, or instruction."
                    : "Save a deliberate launch for this project or every workspace."
            )
            .font(TenonTheme.utilityFont(size: 9))
            .foregroundStyle(TenonTheme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 250)

            if !hasQuery {
                Button("Create Runbook", action: create)
                    .buttonStyle(.bordered)
                    .tint(TenonTheme.amber)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 104)
        .padding(.horizontal, 16)
    }
}

private struct QuickCommandEditor: View {
    private enum Availability: String, CaseIterable {
        case project
        case everywhere
    }

    private enum Field: Hashable {
        case name
        case body
    }

    @Environment(\.dismiss) private var dismiss
    let mode: QuickCommandEditorItem.Mode
    var commands: QuickCommandStore
    let workspace: Workspace?

    @State private var draft: QuickCommand
    @State private var availability: Availability
    @State private var projectPath: String
    @FocusState private var focusedField: Field?

    init(
        mode: QuickCommandEditorItem.Mode,
        command: QuickCommand,
        commands: QuickCommandStore,
        workspace: Workspace?
    ) {
        self.mode = mode
        self.commands = commands
        self.workspace = workspace
        _draft = State(initialValue: command)
        if case let .project(path) = command.scope {
            _availability = State(initialValue: .project)
            _projectPath = State(initialValue: path)
        } else {
            _availability = State(initialValue: .everywhere)
            _projectPath = State(initialValue: workspace?.path.path ?? "")
        }
    }

    private var canSave: Bool {
        draft.isComplete && (availability == .everywhere || !projectPath.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: RunbookMetrics.sectionSpacing) {
                    nameSection
                    runnerSection
                    bodySection
                    launchSection
                    runSummary
                }
                .padding(RunbookMetrics.contentInset)
            }

            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)

            editorFooter
        }
        .frame(width: RunbookMetrics.editorWidth, height: RunbookMetrics.editorHeight)
        .background(TenonTheme.chromeRaised)
        .foregroundStyle(TenonTheme.text)
        .tint(TenonTheme.amber)
        .preferredColorScheme(.dark)
        .defaultFocus($focusedField, .name)
        .onChange(of: draft.runner) { _, runner in
            if runner.isAgent {
                draft.destination = .newTab
                draft.appendEnter = true
            }
        }
        .onChange(of: availability) { _, value in
            if value == .project, projectPath.isEmpty {
                projectPath = workspace?.path.path ?? ""
            }
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TenonTheme.amber)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .add ? "New Runbook" : "Refine Runbook")
                    .font(TenonTheme.interfaceFont(size: 13, weight: .semibold))
                Text("Runner · place · availability")
                    .font(TenonTheme.utilityFont(size: 9))
                    .foregroundStyle(TenonTheme.muted)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: RunbookMetrics.editorHeaderHeight)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            RunbookSectionLabel("NAME")
            TextField("Review this branch", text: $draft.label)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 13, weight: .medium))
                .focused($focusedField, equals: .name)
                .padding(.horizontal, 10)
                .frame(height: RunbookMetrics.controlHeight)
                .background(TenonTheme.panel, in: .rect(cornerRadius: RunbookMetrics.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: RunbookMetrics.cornerRadius)
                        .strokeBorder(
                            focusedField == .name
                                ? TenonTheme.amber.opacity(0.75)
                                : TenonTheme.line,
                            lineWidth: focusedField == .name ? 1.5 : 1
                        )
                }
                .onSubmit { focusedField = .body }
        }
    }

    private var runnerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            RunbookSectionLabel("RUN WITH")
            Picker("Runner", selection: $draft.runner) {
                ForEach(QuickCommandRunner.allCases, id: \.self) { runner in
                    Label(runner.label, systemImage: runner.symbol)
                        .tag(runner)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(height: RunbookMetrics.controlHeight)
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                RunbookSectionLabel(draft.runner.isAgent ? "BRIEF" : "COMMAND")
                Text(
                    draft.runner.isAgent
                        ? "Outcome and expected evidence"
                        : "Exact terminal input"
                )
                .font(TenonTheme.utilityFont(size: 9))
                .foregroundStyle(TenonTheme.muted)
                Spacer()
                Text("\(draft.body.count)/\(QuickCommand.maximumBodyLength)")
                    .font(TenonTheme.utilityFont(size: 9))
                    .foregroundStyle(TenonTheme.muted)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.body)
                    .font(
                        draft.runner == .terminal
                            ? TenonTheme.utilityFont(size: 12)
                            : TenonTheme.interfaceFont(size: 12)
                    )
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .body)
                    .padding(8)
                    .accessibilityLabel(draft.runner.isAgent ? "Brief" : "Command")
                    .accessibilityHint(
                        draft.runner.isAgent
                            ? "Describe the outcome and evidence expected from the agent."
                            : "Enter the exact text Tenon will send to the terminal."
                    )

                if draft.body.isEmpty {
                    Text(
                        draft.runner.isAgent
                            ? "Inspect the current branch, identify material risks, and cite the files or test receipts behind each claim."
                            : "swift test"
                    )
                    .font(
                        draft.runner == .terminal
                            ? TenonTheme.utilityFont(size: 12)
                            : TenonTheme.interfaceFont(size: 12)
                    )
                    .foregroundStyle(TenonTheme.muted.opacity(0.65))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .frame(height: RunbookMetrics.editorBodyHeight)
            .background(TenonTheme.panel, in: .rect(cornerRadius: RunbookMetrics.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: RunbookMetrics.cornerRadius)
                    .strokeBorder(
                        focusedField == .body
                            ? TenonTheme.amber.opacity(0.75)
                            : TenonTheme.line,
                        lineWidth: focusedField == .body ? 1.5 : 1
                    )
            }
        }
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            RunbookSectionLabel("LAUNCH")

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PLACE")
                        .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                        .foregroundStyle(TenonTheme.muted)

                    if draft.runner == .terminal {
                        Picker("Place", selection: $draft.destination) {
                            Text("Focused Pane").tag(QuickCommandDestination.focusedTerminal)
                            Text("New Tab").tag(QuickCommandDestination.newTab)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(height: RunbookMetrics.controlHeight)

                        Toggle("Press Return after inserting", isOn: $draft.appendEnter)
                            .font(TenonTheme.interfaceFont(size: 10.5))
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Press Return after inserting")
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "rectangle.stack.badge.plus")
                                .foregroundStyle(TenonTheme.amber)
                                .frame(width: 14)
                            Text("Fresh terminal tab")
                                .font(TenonTheme.interfaceFont(size: 11, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .frame(height: RunbookMetrics.controlHeight)

                        Text("Keeps agent identity and return path.")
                            .font(TenonTheme.utilityFont(size: 9))
                            .foregroundStyle(TenonTheme.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("AVAILABLE IN")
                        .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                        .foregroundStyle(TenonTheme.muted)

                    Picker("Availability", selection: $availability) {
                        Text("This Project").tag(Availability.project)
                        Text("Everywhere").tag(Availability.everywhere)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(height: RunbookMetrics.controlHeight)

                    Text(availabilityDetail)
                        .font(TenonTheme.utilityFont(size: 9))
                        .foregroundStyle(TenonTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(10)
            .background(TenonTheme.panel, in: .rect(cornerRadius: RunbookMetrics.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: RunbookMetrics.cornerRadius)
                    .strokeBorder(TenonTheme.line)
            }
        }
    }

    private var runSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(TenonTheme.amber)
                .frame(width: 12)
                .accessibilityHidden(true)

            Text("WHEN RUN")
                .font(TenonTheme.utilityFont(size: 8.5, weight: .semibold))
                .foregroundStyle(TenonTheme.amber)
            Text(summaryText)
                .font(TenonTheme.interfaceFont(size: 10.5))
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    private var editorFooter: some View {
        HStack {
            Text("Runbooks stay local to this Mac.")
                .font(TenonTheme.utilityFont(size: 9.5))
                .foregroundStyle(TenonTheme.muted)

            Spacer()

            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .buttonStyle(.plain)
            .font(TenonTheme.interfaceFont(size: 12))
            .foregroundStyle(TenonTheme.muted)
            .padding(.horizontal, 12)
            .frame(height: RunbookMetrics.controlHeight)
            .background(TenonTheme.panel)
            .clipShape(.rect(cornerRadius: RunbookMetrics.cornerRadius))
            .keyboardShortcut(.cancelAction)

            Button("Save Runbook", action: save)
                .buttonStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 12, weight: .semibold))
                .foregroundStyle(TenonTheme.ink)
                .padding(.horizontal, 12)
                .frame(height: RunbookMetrics.controlHeight)
                .background(TenonTheme.amber)
                .opacity(canSave ? 1 : 0.45)
                .clipShape(.rect(cornerRadius: RunbookMetrics.cornerRadius))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .frame(height: RunbookMetrics.editorFooterHeight)
    }

    private var availabilityDetail: String {
        switch availability {
        case .project:
            workspace.map { "Only while \($0.name) is active." }
                ?? "Only in this project."
        case .everywhere:
            "Visible from every workspace."
        }
    }

    private var summaryText: String {
        let launch = switch draft.runner {
        case .terminal where draft.destination == .focusedTerminal:
            "Runs in the focused terminal"
        case .terminal:
            "Opens a fresh terminal tab"
        case .codex:
            "Starts Codex in a fresh terminal tab"
        case .claude:
            "Starts Claude in a fresh terminal tab"
        }
        let availability = switch availability {
        case .project:
            workspace.map { "only in \($0.name)" } ?? "only in this project"
        case .everywhere:
            "from every workspace"
        }
        return "\(launch), available \(availability)."
    }

    private func save() {
        draft.scope = availability == .everywhere
            ? .global
            : .project(path: projectPath)
        commands.upsert(draft)
        dismiss()
    }
}

private struct RunbookSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
            .foregroundStyle(TenonTheme.muted)
            .tracking(0.7)
    }
}

private extension QuickCommandRunner {
    var symbol: String {
        switch self {
        case .terminal: "terminal.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        }
    }

}
