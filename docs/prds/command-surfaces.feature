# language: en

@prd-TENON_PRD_002
Feature: Discover commands and arrange tabs without losing context
  An operator supervising several workstreams needs every command surface to expose one
  coherent catalog while preserving tab-local utilities and native window behavior.
  PRD: command-surfaces.prd.md

  Rule: Command discovery has one product vocabulary

    @req-cmd-fr-001 @req-cmd-fr-002 @happy-path
    Scenario: The operator finds and runs an eligible command from the Command Palette
      Given an active plugin declares an authorized palette command
      When the operator opens the Command Palette and searches for that command
      Then the matching plugin-owned command is selectable
      And invoking it uses the command's current authorized binding

    @req-cmd-fr-002 @req-cmd-nfr-006 @keyboard
    Scenario: The Command Palette is fully operable from the keyboard
      Given the workspace is ready for input
      When the operator opens the Command Palette with its product shortcut
      Then search receives keyboard focus
      And arrow keys and Enter operate on the displayed result order
      And Escape closes the palette without invoking a result

    @req-cmd-fr-003 @req-cmd-nfr-001 @req-cmd-nfr-003 @dynamic
    Scenario: A slow dynamic provider never blocks the static command list
      Given static commands are available and a dynamic provider does not answer
      When the operator changes the palette query
      Then the static ranked commands remain immediately selectable in the same order
      And the provider may show a non-selectable pending state below them

    @req-cmd-fr-003 @req-cmd-nfr-001 @stale
    Scenario: A provider answer for an old query is not shown
      Given the palette has advanced to a newer query revision
      When a provider publishes results for the superseded revision
      Then none of those results appear in the current palette

    @req-cmd-nfr-002 @bounds
    Scenario Outline: A dynamic provider cannot exceed publication bounds
      Given a plugin owns a dynamic command provider
      When it publishes <content> beyond the supported bound
      Then the excess contribution is refused or omitted deterministically
      And the host command surfaces remain available

      Examples:
        | content              |
        | provider registrations |
        | results              |
        | actions per result   |

  Rule: Every launcher anchor reuses the same presentation with explicit placement

    @req-cmd-fr-004 @req-cmd-fr-001 @plus
    Scenario: The plus button opens the launcher before creating anything
      Given the tab strip is visible
      When the operator activates the plus button
      Then the searchable shared launcher appears
      And no new tab exists until the operator selects a launcher row

    @req-cmd-fr-005 @req-cmd-fr-007 @tab-launcher
    Scenario: A tab secondary click opens the complete launcher directly
      Given a tab chip is visible
      When the operator secondary-clicks that tab
      Then the searchable shared launcher appears without an intermediate menu
      And the launcher includes the tab-scoped Copy Tab ID utility

    @req-cmd-fr-006 @background-tab
    Scenario: A placing command from a background tab targets that tab
      Given the operator opens the launcher from a tab that is not selected
      When the operator chooses a command that places content
      Then the result is placed within the clicked tab's scope
      And the tab is revealed only as required to present the result

    @req-cmd-fr-006 @background-tab @no-placement
    Scenario: A non-placing tab action does not steal selection
      Given the operator opens the launcher from a background tab
      When the operator chooses an action that places no visible content
      Then the previously selected tab remains selected

    @req-cmd-fr-008 @empty-target
    Scenario Outline: An empty-space launcher fills the exact target
      Given the operator opens the shared launcher from an empty <target>
      When the operator chooses content that can fill that target
      Then the chosen content occupies that exact <target>
      And no unrelated tab or pane is created

      Examples:
        | target    |
        | tab       |
        | pane      |
        | grid area |

    @req-cmd-fr-010 @failure
    Scenario: A failed launcher command remains visible and does not affect ranking
      Given the shared launcher is open on an eligible command
      When that command fails or is no longer available
      Then the launcher explains the failure in place
      And the launcher remains open
      And no successful-use frecency is recorded

    @req-cmd-fr-010 @happy-path
    Scenario: A successful launcher command settles once
      Given the shared launcher is open on an eligible command
      When that command succeeds
      Then its successful use is recorded for ranking
      And the launcher closes

    @req-cmd-fr-011 @layout
    Scenario: Launcher height follows content until the screen limit
      Given the launcher has fewer rows than the available vertical space
      When the launcher is presented
      Then its list ends after its rows, separators, and padding
      And it does not stretch to the screen limit

    @req-cmd-fr-011 @overflow
    Scenario: Launcher results scroll only when content exceeds available space
      Given the launcher rows exceed the available vertical space
      When the launcher is presented
      Then its height is limited by that available space
      And the remaining rows are reachable by scrolling

    @req-cmd-fr-018 @agent-suggestion
    Scenario: A detected local agent appears without creating a second launcher model
      Given a supported local agent launch is available on this machine
      When the operator opens an eligible launcher anchor
      Then the agent suggestion appears in the shared displayed order
      And it follows that anchor's placement and settlement behavior

    @req-cmd-nfr-005 @visual
    Scenario: Command surfaces remain in Tenon's native visual language
      Given the Command Palette and compact launcher present equivalent commands
      When the operator compares their rows, states, focus, and feedback
      Then each surface uses its documented Tenon density and semantic tokens
      And no state depends on a feature-local color or geometry scale

    @req-cmd-nfr-005 @req-cmd-nfr-008 @row-chrome
    Scenario Outline: Every kind of row answers the pointer the same way
      Given a command surface is showing a <row_kind>
      When the operator moves the pointer onto that row
      Then the row draws the shared hover wash from Tenon's semantic tokens
      And its metrics come from the one row presentation every other row is drawn with
      And that presentation is reached without supplying a ranking score or match

      Examples:
        | row_kind                        |
        | ranked command                  |
        | appended provider result        |
        | fixed tab identity utility      |

  Rule: Tab identity utilities remain local and explicit

    @req-cmd-fr-007 @req-cmd-nfr-007 @identity
    Scenario: Copy Tab ID yields the stable raw address
      Given the operator opens the launcher from a tab
      When the operator activates Copy Tab ID
      Then the clipboard contains that tab's raw UUID
      And the utility does not become a ranked command or teach frecency

    @req-cmd-fr-007 @req-cmd-nfr-008 @identity
    Scenario: The fixed tab utility looks like a row while staying out of the order
      Given the operator opens the launcher from a tab
      When the pointer rests on the Copy Tab ID footer
      Then it highlights exactly as a command row does
      And it never carries the keyboard selection accent, because arrowing never reaches it

    @req-cmd-fr-017 @req-cmd-nfr-004 @accessibility
    Scenario: A non-pointer user can reach tab identity and launcher actions
      Given assistive technology is focused on a tab
      When it asks for the tab's available actions
      Then Open launcher and Copy Tab ID are available
      And the tab's one-based position and active state are exposed

    @req-cmd-nfr-007 @public-boundary
    Scenario: Local tab controls do not become public commands
      Given a plugin, CLI, or agent discovers Tenon's public operations
      When it inspects the available intent contracts and product keybindings
      Then no tab-reorder or Copy Tab ID operation is published
      And those controls remain available in their focused native tab context

  Rule: Product keybindings are plugin declarations with one invocation path

    @req-cmd-fr-009 @keybinding
    Scenario: An assigned product key invokes the current command binding
      Given an active plugin command owns a valid unconflicted key chord
      When the operator presses that chord
      Then the exact current plugin-owned command is invoked with a fresh user gesture
      And the same chord is displayed in command discovery

    @req-cmd-fr-009 @conflict
    Scenario: A conflicting or reserved key does not override its winner
      Given two command declarations normalize to the same chord or request a shell-reserved chord
      When the host resolves active product keybindings
      Then the deterministic eligible winner alone receives the binding
      And every losing command remains discoverable without that binding
      And a typed diagnostic explains the refusal

  Rule: A tab drag reorders the tab and never the window

    @req-cmd-fr-012 @selection
    Scenario: A short press remains a tab selection
      Given a tab is not selected
      When the operator presses and releases it without crossing the reorder threshold
      Then that tab becomes selected
      And no reorder preview appears

    @req-cmd-fr-013 @req-cmd-fr-014 @reorder
    Scenario: A tab changes places while the pointer is still holding it
      Given several measured tabs are visible in one workspace
      When the operator drags one tab past another tab's midpoint
      Then the dragged tab already occupies that position before the pointer is released
      And the strip draws no second marker describing where it will land
      And releasing there leaves the tab in place
      And the application window remains in the same position

    @req-cmd-fr-014 @persistence
    Scenario: Reordering preserves the tab's work and survives restoration
      Given a tab has stable identity, panes, content, focus, and active state
      When the operator moves that tab to another position and later restores the workspace
      Then the same tab retains its identity, panes, content, focus, and active state
      And the restored tab sequence reflects the move

    @req-cmd-fr-019 @boundary
    Scenario: The strip's pointer surface covers the chips and nothing else
      Given the tab strip sits inside the window's title-bar band
      When the operator presses the "+" launcher beside the last chip
      Then the launcher opens
      And the press is not absorbed by the surface that owns the chips

    @req-cmd-fr-019 @focus
    Scenario: Selecting a tab leaves the keyboard with the terminal
      Given a pane in the active tab holds keyboard focus
      When the operator clicks a tab chip
      Then that tab becomes active
      And the tab strip does not become the first responder

    @req-cmd-fr-015 @no-op
    Scenario: Holding the pointer over the tab's own place changes nothing
      Given a tab reorder has started
      When the pointer rests on either boundary representing the tab's current position
      Then the tab order remains unchanged

    @req-cmd-fr-015 @cancellation
    Scenario: Pulling the tab away from the strip puts the row back
      Given a tab reorder has already moved the tab
      When the operator releases beyond the strip's admitted vertical band
      Then the dragged tab returns to the index the drag began at
      And the rest of the row stands in the order it started in

    @req-cmd-fr-015 @invalid
    Scenario Outline: Invalid reorder input is refused
      Given a reorder refers to <invalid_input>
      When the reorder is committed
      Then the tab order remains unchanged

      Examples:
        | invalid_input                    |
        | a tab not shown by this strip    |
        | an insertion outside the strip   |

    @req-cmd-fr-017 @req-cmd-nfr-004 @accessibility
    Scenario: Assistive technology can reorder without a pointer drag
      Given assistive technology is focused on a tab that can move right
      When it activates Move tab right
      Then the tab moves one position to the right through the same workspace mutation
      And the completed position is announced

  Rule: Empty titlebar chrome retains native window behavior

    @req-cmd-fr-016 @window-drag
    Scenario: Dragging empty titlebar chrome moves the window
      Given the pointer starts on empty titlebar chrome rather than an interactive control
      When the operator drags that chrome
      Then the window follows the native window drag
      And tab order remains unchanged

    @req-cmd-fr-016 @window-double-click
    Scenario: Double-clicking empty titlebar chrome follows the system preference
      Given macOS has a configured titlebar double-click action
      When the operator double-clicks empty titlebar chrome
      Then the window performs that configured action
