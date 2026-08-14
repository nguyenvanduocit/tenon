# language: en

@prd-TENON_PRD_009
Feature: Operate native terminal panes with bounded automation and owned processes
  Operators and programmatic callers need terminal input, reading, waiting, and teardown
  to remain coherent under one stable pane identity.
  PRD: terminal.prd.md

  Rule: One lazy native surface follows each terminal pane identity

    @req-term-fr-001 @runtime
    Scenario: One runtime owns independent pane surfaces
      Given the process has initialized the Ghostty runtime with default configuration
      When two visible terminal panes materialize
      Then one runtime owns two distinct surfaces keyed by their pane UUIDs
      And the user's Ghostty configuration is not loaded

    @req-term-fr-002 @spawn
    Scenario Outline: A terminal starts in the correct directory
      Given the pane has <directory source>
      When it materializes for the first time
      Then its shell starts in <directory>
      And the surface receives its pane, surface, socket, and available agent-hook identity

      Examples:
        | directory source | directory |
        | a seeded valid cwd | that cwd |
        | no seeded cwd | the workspace path |

    @req-term-fr-003 @facts
    Scenario Outline: Backend actions become typed host facts
      Given a live terminal surface
      When Ghostty reports <action>
      Then the host receives <fact>

      Examples:
        | action | fact |
        | OSC 0 or OSC 2 | title change |
        | OSC 7 | pane cwd change |
        | OSC 133 command finished | an incremented completion count |
        | process exit | shell exit |
        | responder acquisition | pane focus |
        | native new-tab or split action | the matching workspace command |

    @req-term-fr-004 @keyboard
    Scenario Outline: A handled command selector reaches the PTY without a beep path
      Given the terminal view is first responder
      When the operator presses <key>
      Then the terminal receives the intended input
      And the derived AppKit selector does not escape up the responder chain

      Examples:
        | key |
        | Backspace |
        | an arrow key |
        | Return |
        | Escape |

    @req-term-fr-004 @ime
    Scenario: Text input still uses AppKit interpretation
      Given an input method or dead key composes text
      When the terminal view interprets the event
      Then composed text is inserted into the PTY
      And consuming command selectors does not suppress that text path

    @req-term-fr-005 @clipboard
    Scenario Outline: Sensitive clipboard work asks and settles explicitly
      Given Ghostty requests <operation> with confirmation required
      When the user <decision>
      Then the clipboard operation is <result>

      Examples:
        | operation | decision | result |
        | unsafe paste | allows | completed with the original content |
        | unsafe paste | denies | completed with empty denied content |
        | OSC 52 read | allows | completed with clipboard content |
        | OSC 52 write | denies | not written |

    @req-term-fr-005 @clipboard-deny
    Scenario: Clipboard confirmation without a window denies
      Given a confirmation-requiring terminal clipboard request has no presenting window
      When the presenter resolves it
      Then it denies the request
      And no clipboard content is exposed or changed

    @req-term-fr-006 @render
    Scenario: Surface publishes current render and process observation
      Given a materialized terminal is resized and focused
      When the host asks for its observation
      Then it reports current rendered text, nullable columns and rows, exit state, command count, and foreground PID when available
      And rendering uses the window backing scale

    @req-term-nfr-001 @design
    Scenario: Terminal host UI follows the native design system
      Given terminal chrome, placeholder, or confirmation UI is visible
      When appearance or contrast changes
      Then host UI uses Tenon typography, density, semantic colors, geometry, and components
      And terminal cells remain backend-owned

    @req-term-nfr-002 @main-actor
    Scenario: UI-bound terminal state and blocking process work stay separated
      Given surface state is MainActor-confined
      When process-table inspection or escalation waits are required
      Then those blocking operations run away from MainActor
      And their result returns through a bounded typed seam

    @req-term-nfr-003 @callbacks
    Scenario: A late backend callback cannot reach a released view
      Given every registered view owns a monotonic callback token
      When the surface unregisters and an already queued callback arrives
      Then the token resolves to no live weak view
      And no token is reused during the process lifetime

  Rule: Public terminal intents have distinct targeting and creation semantics

    @req-term-fr-007 @write
    Scenario: Write queues text for a valid unmaterialized terminal
      Given invocation scope resolves a terminal pane that has not been displayed
      When terminal.write.v1 receives bounded text
      Then SurfacePool queues the text without materializing the pane
      And first materialization sends the text verbatim once

    @req-term-fr-008 @run
    Scenario Outline: Run chooses a useful terminal or creates one
      Given the scoped workspace has <terminals>
      When terminal.run.v1 receives a valid command
      Then <target> is focused
      And it receives the command followed by exactly one newline

      Examples:
        | terminals | target |
        | an active terminal in the preferred tab | that active terminal |
        | a nonterminal active pane and another terminal in that tab | the first terminal in that tab |
        | a terminal only in another tab of the workspace | that workspace terminal |
        | no terminal | one new terminal tab |

    @req-term-fr-009 @open
    Scenario: Open always creates a fresh terminal and returns identity
      Given another usable terminal already exists in scope
      When terminal.open.v1 succeeds
      Then one new terminal tab exists
      And its pane UUID differs from the existing terminal
      And the reply contains only the new pane UUID

    @req-term-fr-010 @open-input
    Scenario Outline: Open validates optional launch input honestly
      Given terminal.open.v1 receives <input>
      When the provider validates it
      Then it <result>

      Examples:
        | input | result |
        | a valid command and existing absolute workingDirectory | seeds the directory before surface creation and queues command plus newline |
        | an omitted command | opens an empty shell |
        | blank or NUL-containing command | refuses invalid input |
        | missing, relative, or non-directory workingDirectory | refuses invalid input |

    @req-term-fr-011 @targeting
    Scenario Outline: Target resolution respects exact scope
      Given a terminal request carries <scope>
      When the provider resolves its target
      Then it uses <resolution>

      Examples:
        | scope | resolution |
        | a terminal pane ID | that pane |
        | a nonterminal pane ID | pane-is-not-a-terminal failure |
        | a tab ID | active terminal or first terminal in that tab |
        | a workspace ID | the preferred terminal in that workspace |
        | a missing identity | the corresponding typed unavailable reason |

    @req-term-nfr-004 @bounds
    Scenario Outline: Public terminal fields are bounded twice
      Given a caller submits <field>
      When the request crosses schema and provider validation
      Then values beyond the declared bound are refused
      And accepted output still fits the inline envelope

      Examples:
        | field |
        | write text or command |
        | viewport text |
        | scrollback page and cursor |
        | wait timeout |

    @req-term-nfr-005 @capability
    Scenario Outline: Every terminal intent uses the canonical gate and lane
      Given a programmatic caller declared <intent>
      When it invokes the contract
      Then it requires <capability>
      And the kernel admits it on <lane>

      Examples:
        | intent | capability | lane |
        | terminal.write.v1 | terminal.write | terminalImmediate |
        | terminal.run.v1 | terminal.write | terminalImmediate |
        | terminal.open.v1 | terminal.write | terminalImmediate |
        | terminal.viewport.read.v1 | terminal.read | terminalImmediate |
        | terminal.scrollback.read.v1 | terminal.read | terminalImmediate |
        | terminal.wait.v1 | terminal.read | terminalWait |

    @req-term-nfr-008 @boundary
    Scenario: Public callers never receive terminal implementation authority
      Given a plugin CLI or agent needs terminal work
      When it crosses the host boundary
      Then it uses tenon.intents.send with a declared contract
      And receives no native view, PTY handle, process ID, or handwritten terminal API

  Rule: Viewport, scrollback, and wait report bounded honest observations

    @req-term-fr-012 @viewport
    Scenario: Viewport read preserves its original typed shape
      Given a scoped terminal surface is live
      When terminal.viewport.read.v1 succeeds
      Then it returns paneID, visible text, exited, columns, and rows
      And columns and rows may be null
      And it returns no scrollback cursor fields

    @req-term-fr-013 @scrollback
    Scenario: Scrollback pages the whole stopped buffer oldest first
      Given a stable retained buffer exceeds one requested page
      When the caller follows each returned cursor
      Then every retained row appears exactly once in order
      And default maxLines is 500
      And no page exceeds 2000 rows or the inline byte bound
      And the final cursor is null

    @req-term-fr-026 @process-identity
    Scenario: Process read names the tty and the foreground process
      Given a scoped terminal surface is live
      When terminal.process.read.v1 succeeds
      Then it returns paneID, ttyName, and foregroundPID
      And it returns no CPU, memory, or footprint figure

    @req-term-fr-026 @process-identity
    Scenario: A pane with no live surface says so instead of failing
      Given a terminal pane the canvas has never displayed
      When terminal.process.read.v1 succeeds
      Then ttyName and foregroundPID are both null
      And a pane that is not a terminal fails with terminal-unavailable

    @req-term-fr-014 @invalidation
    Scenario: Moving scrollback invalidates positional continuation
      Given page one issued a cursor encoding total row count
      When the surface row count changes before page two
      Then page two returns invalidated true
      And text is empty and cursor is null
      And the current totalRows is reported

    @req-term-fr-015 @wait
    Scenario Outline: Wait returns one finite result
      Given a live scoped terminal
      When terminal.wait.v1 waits for <condition>
      Then it returns paneID, that condition, and whether it was met
      And it creates no continuous output subscription

      Examples:
        | condition |
        | exit |
        | tui-idle |
        | command-finished |

    @req-term-fr-016 @poll
    Scenario: TUI idle uses the documented bounded cadence
      Given terminal output is being observed
      When terminal.wait.v1 uses its default timeout
      Then it polls at 200 milliseconds with 20 milliseconds tolerance
      And three unchanged text samples are required for TUI idle
      And timeout defaults to 30000 milliseconds and never exceeds 55000

    @req-term-fr-017 @command-finished
    Scenario Outline: Command-finished wait begins after its own baseline
      Given the baseline count is captured when wait begins
      When <outcome> happens
      Then the result has met <met>

      Examples:
        | outcome | met |
        | a later OSC 133 completion increments the count | true |
        | the process exits before another completion | false |

    @req-term-nfr-006 @value-not-handle
    Scenario: Cursor and pane UUID confer no caller-owned resource lifetime
      Given open returns a pane UUID and scrollback returns a cursor
      When the caller drops either value
      Then the host has nothing to release on that caller's behalf
      And workspace or buffer truth independently determines later validity

  Rule: Pane close owns tty-attached work and app quit must reach the same guarantee

    @req-term-fr-018 @close-confirmation
    Scenario Outline: Tab close handles process inspection safely
      Given the tab contains <state>
      When the operator requests close
      Then <outcome>

      Examples:
        | state | outcome |
        | no live terminal | the tab closes immediately |
        | complete identity with one group per tty | the idle tab closes after inspection |
        | multiple groups on a tty | a destructive running-process confirmation appears |
        | missing identity or unavailable inspection | a fail-safe unverifiable-process confirmation appears |

    @req-term-fr-019 @lifetime
    Scenario Outline: Surface lifetime follows catalog membership only
      Given a materialized pane owns a terminal surface
      When <change> occurs
      Then <result>

      Examples:
        | change | result |
        | focus moves | the surface remains alive |
        | another tab becomes active | the surface remains alive |
        | another workspace becomes active | the surface remains alive |
        | the pane leaves the catalog | terminate runs once before release |

    @req-term-fr-020 @teardown
    Scenario: Closing a pane sweeps and escalates its tty process groups
      Given the pane foreground process has a controlling tty with several process groups
      When its surface terminates
      Then callbacks are cleared first
      And every non-root process group is ordered before the root group
      And SIGHUP is sent to all targets
      And after 120 milliseconds the process table is read again
      And SIGKILL is sent to surviving targets

    @req-term-fr-021 @fallback
    Scenario Outline: Teardown fails safe when broad ownership is unprovable
      Given <condition>
      When the terminator settles the pane
      Then <result>

      Examples:
        | condition | result |
        | the root has no controlling tty | the root group and root process are signalled narrowly |
        | the root group vanished | the narrow missing-target-safe fallback is used |
        | Tenon itself shares the tty | no broad tty sweep targets the developer shell |

    @req-term-fr-022 @cleanup
    Scenario: Catalog removal clears every pane-keyed terminal record
      Given a pane closes before or after materialization
      When SurfacePool retains only live catalog IDs
      Then surface, token, title, directory, attention, viewed state, and pending text for that UUID are gone
      And repeated reconciliation cannot terminate it twice

    @req-term-fr-023 @inspection
    Scenario Outline: Process inspection refuses ambiguous ownership
      Given the process table has <shape>
      When the pure inspection rule parses it
      Then it returns <verdict>

      Examples:
        | shape | verdict |
        | invalid PID or group zero or one | those rows are excluded |
        | foreground PID missing or no tty | unavailable |
        | duplicate foreground PIDs resolving to one tty unexpectedly | unavailable |
        | exactly one process group per resolved tty | idle |
        | more than one process group on a resolved tty | running |

    @req-term-fr-024 @req-term-nfr-010 @pending @app-quit
    Scenario: App quit explicitly terminates every materialized terminal
      Given several terminal panes own live or background jobs
      When applicationShouldTerminate runs the bounded stop sequence
      Then each materialized surface receives explicit terminate before process exit
      And its tty-attached jobs complete the SIGHUP and SIGKILL settlement
      And no pane relies only on ARC or ghostty_surface_free

    @req-term-fr-025 @relaunch
    Scenario: Relaunch creates a fresh shell without false continuity
      Given a terminal pane was persisted before quit
      When the pane is first displayed after relaunch
      Then a fresh PTY and shell start in the restored valid cwd or workspace path
      And prior process, emulator state, viewport, and scrollback do not return

    @req-term-nfr-007 @bounded-teardown
    Scenario: Teardown is explicit bounded and PID-reuse-aware
      Given a surface leaves catalog ownership
      When termination begins
      Then ownership triggers it once independent of deallocation
      And it performs at most two process-table rounds and one bounded wait
      And escalation uses the fresh second table rather than stale PIDs

    @req-term-nfr-009 @verification
    Scenario: Terminal decisions are proven at the lowest valid layer
      Given targeting, paging, idle, process parsing, and signal ordering are pure rules
      When regression evidence runs
      Then those rules pass without a window
      And AppKit responder and hosted surface seams have focused tests
      And a real process fixture proves SIGHUP-resistant work receives escalation

  @req-term-fr-027 @terminal
  Scenario: Every terminal knows where it is, agent or not
    Given a person opens an ordinary terminal pane
    Then its shell carries TENON_PANE_ID, TENON_TAB_ID, TENON_WORKSPACE_ID and TENON_SOCKET_PATH
    And a pane an agent was launched into carries exactly the same set

  @req-term-fr-027 @terminal
  Scenario: An identity the host cannot resolve is absent rather than empty
    Given a pane whose owner the catalog cannot answer for
    Then TENON_TAB_ID and TENON_WORKSPACE_ID are unset
    And TENON_PANE_ID is still exported
