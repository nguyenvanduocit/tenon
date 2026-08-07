# T-067: Agent Lens renders the markdown agents actually write
> Assistant prose arrives as CommonMark and is shown raw — `**bold**`, `- [ ]` task lists, and
> fenced code all read as literal punctuation in the timeline, so the compressed view is harder
> to scan than the terminal it is supposed to replace.
- **priority**: high
- **effort**: M

## Owner / files (agent lock)
- released 2026-08-06 by session 91fc26a7 — all files free.

## Criteria
- [x] A pure `AgentMarkdown.parse` turns agent prose into blocks — headings, paragraphs, nested/ordered/task lists, fenced code, blockquotes, pipe tables, thematic breaks — asserted headless in `TenonAppStateTests` (`AgentLensMarkdownTests`, 16 tests)
- [x] Inline spans (bold, italic, inline code, links, strikethrough) render as attributes, never as literal punctuation — `AgentMarkdownInline.attributed`, inline code additionally gets a monospaced run
- [x] An unterminated code fence mid-stream still renders as code, so streaming output never flips formatting
- [x] Pipe tables use columns while they fit and reflow into labeled records in a narrow pane, without horizontal scrolling
- [x] The collapsed long-message view and its "Show all" toggle still bound what a single message can occupy — `lineLimit` cannot clip a block stack, so `AgentMarkdown.collapsed` bounds the parsed *source* (18 lines / 1600 chars) instead
- [x] `swift build` green (warnings-as-errors); `swift test` 1094 tests, every AgentLens suite green

## Notes
Hand-rolled line parser rather than swift-markdown/MarkdownUI: the subset agents emit is
small, the package stays free of a cmark-gfm dependency, and the rules are asserted
headless. Anything it cannot read degrades to a paragraph whose inline spans still render.

Two failures in the full run — `AgentsRunTests.testRunComposesOpenWaitAndPagedReadInOrderWithScope`
and `IntentMailboxTests.testALaneIsSerialByDefault` — are timing-flaky under the parallel
load of several agents building at once; both pass when their suites run alone, and neither
target depends on `TenonApp`, where every change here lives.

Not covered: tool-step output, interaction-request detail, and the inspector still render
plain. They carry command output and short prompts, not prose.
