// @domain: agent-lens
import SwiftUI

/// Renders agent prose as the structure it was written in. Blocks come from the pure
/// `AgentMarkdown` parser and inline spans become attributes, so a transcript reads as
/// prose rather than as the punctuation the agent typed.
struct AgentMarkdownText: View {
    let source: String
    var textStyle: Font.TextStyle = .body
    var weight: Font.Weight = .regular
    var tint: Color = TenonTheme.text
    /// The streaming caret, parked at the end of the trailing paragraph so a live message
    /// keeps its cursor in the sentence instead of on a line of its own.
    var caret = false
    /// Which written paths resolve to a file, so citing one is a way back to it.
    var fileLinks: AgentFileLinks = .none
    @State private var blocks: [AgentMarkdownBlock] = []
    @State private var parsedSource: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if parsedSource != source || blocks.isEmpty {
                // The detached parser cannot leave this row with zero height. A lazy timeline
                // would place the next work row at that zero edge, then draw this prose through
                // it when parsing completes. Plain text is the truthful first-frame fallback.
                Text(source + (caret ? " ▍" : ""))
                    .font(.system(textStyle).weight(weight))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                    AgentMarkdownBlockView(
                        block: block,
                        textStyle: textStyle,
                        weight: weight,
                        tint: tint,
                        caret: caret && offset == blocks.count - 1,
                        fileLinks: fileLinks
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            let requestedSource = source
            let parsed = await Task.detached(priority: .userInitiated) {
                AgentMarkdown.parse(requestedSource)
            }.value
            guard !Task.isCancelled, requestedSource == source else { return }
            blocks = parsed
            parsedSource = requestedSource
        }
    }
}

private struct AgentMarkdownBlockView: View {
    let block: AgentMarkdownBlock
    let textStyle: Font.TextStyle
    let weight: Font.Weight
    let tint: Color
    let caret: Bool
    let fileLinks: AgentFileLinks

    @ViewBuilder var body: some View {
        switch block {
        case .paragraph(let text):
            prose(text + (caret ? " ▍" : ""))

        case .heading(let level, let text):
            prose(text)
                .font(headingFont(level))
                .foregroundStyle(TenonTheme.text)
                .padding(.top, 1)

        case .list(let items):
            AgentMarkdownListView(
                items: items,
                textStyle: textStyle,
                weight: weight,
                tint: tint,
                fileLinks: fileLinks
            )

        case .code(let language, let source):
            AgentMarkdownCodeView(language: language, source: source)

        case .quote(let inner):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(TenonTheme.line)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, block in
                        // Erased so the block view can nest inside itself.
                        AnyView(
                            AgentMarkdownBlockView(
                                block: block,
                                textStyle: textStyle,
                                weight: weight,
                                tint: TenonTheme.muted,
                                caret: false,
                                fileLinks: fileLinks
                            )
                        )
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let table):
            AgentMarkdownTableView(
                table: table,
                textStyle: textStyle,
                tint: tint,
                fileLinks: fileLinks
            )

        case .rule:
            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)
                .padding(.vertical, 1)
        }
    }

    /// Deliberately not selectable, and neither is any other row Agent Lens draws.
    ///
    /// `.textSelection(.enabled)` wraps every `Text` in SwiftUI's `SelectionOverlay`, an
    /// `NSViewRepresentable`. Its `updateNSView` configures a real `NSTextField` on each update —
    /// font, attributed string, alignment through `FallbackAlignmentProvider` — and
    /// `-[NSControl setFont:]` invalidates that field's intrinsic content size from *inside* the
    /// pass that is measuring it, so the pass arms the next one. Measured at **17.5% of a
    /// spinning main thread** in incident `0001-81aede1d`, with the pane frozen and footprint
    /// climbing. A transcript pane holds hundreds of these rows inside a lazy list, so the cost
    /// is per row, per update, forever. Selection belongs behind a per-row Copy affordance that
    /// costs nothing until it is used; it does not belong in the measurement path (T-141).
    private func prose(_ text: String) -> some View {
        Text(AgentMarkdownInline.attributed(text, codeStyle: textStyle, fileLinks: fileLinks))
            .font(.system(textStyle).weight(weight))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(.title3).weight(.semibold)
        case 2: .system(.headline)
        default: .system(textStyle).weight(.semibold)
        }
    }
}

private struct AgentMarkdownListView: View {
    let items: [AgentMarkdownListItem]
    let textStyle: Font.TextStyle
    let weight: Font.Weight
    let tint: Color
    let fileLinks: AgentFileLinks

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    marker(item)
                        .frame(minWidth: 13, alignment: .trailing)
                    Text(AgentMarkdownInline.attributed(
                        item.text,
                        codeStyle: textStyle,
                        fileLinks: fileLinks
                    ))
                        .font(.system(textStyle).weight(weight))
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.depth) * 15)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: AgentMarkdownListItem) -> some View {
        if let task = item.task {
            Image(systemName: task == .checked ? "checkmark.square.fill" : "square")
                .font(.system(textStyle))
                .foregroundStyle(task == .checked ? TenonTheme.amber : TenonTheme.muted)
                .accessibilityLabel(task == .checked ? "Checked" : "Unchecked")
        } else {
            switch item.marker {
            case .bullet:
                Text(item.depth == 0 ? "•" : "◦")
                    .font(.system(textStyle))
                    .foregroundStyle(TenonTheme.muted)
            case .ordered(let ordinal):
                Text(ordinal)
                    .font(TenonTheme.utilityFont(size: 10.5))
                    .foregroundStyle(TenonTheme.muted)
            }
        }
    }
}

private struct AgentMarkdownCodeView: View {
    let language: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "code" : language)
                    .font(TenonTheme.utilityFont(size: 9.5, weight: .semibold))
                    .foregroundStyle(TenonTheme.muted)
                    .tracking(0.4)
                Spacer(minLength: 6)
                Button {
                    copyAgentLensText(source)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(TenonTheme.muted)
                }
                .buttonStyle(.plain)
                .help("Copy code")
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 9)
            .padding(.top, 6)

            ScrollView(.horizontal) {
                Text(source)
                    .font(TenonTheme.utilityFont(size: 11.5))
                    .foregroundStyle(TenonTheme.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .tenonScrollbarStyle()
            .scrollIndicators(.hidden)
        }
        .background(TenonTheme.chromeRaised, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(TenonTheme.line, lineWidth: 1)
        }
    }
}

private struct AgentMarkdownTableView: View {
    let table: AgentMarkdownTable
    let textStyle: Font.TextStyle
    let tint: Color
    let fileLinks: AgentFileLinks

    var body: some View {
        // Tables are useful only while their columns remain legible. Measure the natural
        // columnar form first; when the pane cannot hold it, ViewThatFits falls through to
        // the record form instead of hiding evidence behind a sideways scroll.
        ViewThatFits(in: .horizontal) {
            columnarTable
                .fixedSize(horizontal: true, vertical: false)
            recordTable
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnarTable: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    cellText(cell, weight: .semibold, tint: TenonTheme.text)
                        .gridColumnAlignment(alignment(column))
                }
            }
            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)
                .gridCellUnsizedAxes(.horizontal)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        cellText(cell, weight: .regular, tint: tint)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var recordTable: some View {
        if table.rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(table.header.enumerated()), id: \.offset) { _, header in
                    cellText(header, weight: .semibold, tint: TenonTheme.text)
                }
            }
            .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { column, header in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(recordLabel(header, column: column))
                                    .font(.system(textStyle).weight(.semibold))
                                    .foregroundStyle(TenonTheme.text)
                                    .fixedSize(horizontal: true, vertical: false)
                                cellText(
                                    row.indices.contains(column) ? row[column] : "",
                                    weight: .regular,
                                    tint: tint
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    if rowIndex < table.rows.count - 1 {
                        Rectangle()
                            .fill(TenonTheme.line)
                            .frame(height: 1)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cellText(_ cell: String, weight: Font.Weight, tint: Color) -> some View {
        Text(AgentMarkdownInline.attributed(cell, codeStyle: textStyle, fileLinks: fileLinks))
            .font(.system(textStyle).weight(weight))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func recordLabel(_ header: String, column: Int) -> String {
        let label = header.isEmpty ? "Column \(column + 1)" : header
        return label + ":"
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.columns.indices.contains(column) ? table.columns[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
