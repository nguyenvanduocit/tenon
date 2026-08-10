# language: en

@prd-TENON_PRD_014
Feature: Coordinate workspace tasks in a fixed-column board and supervise their agent runs
  People and agents need a readable shared board whose moves remain atomic under concurrent edits.
  PRD: kanban.prd.md

  Rule: Every pane follows the board of its owning workspace

    @req-kan-fr-001 @opener
    Scenario: Kanban opens as an instanced pane-filling plugin view
      Given the bundled Kanban manifest is active
      When palette or launcher invokes its plugin-owned open intent
      Then a pane receives the dev.tenon.kanban board view
      And each pane UUID owns an independent instance

    @req-kan-fr-002 @workspace-owner
    Scenario: Global workspace selection cannot retarget another pane's board
      Given Kanban panes exist in workspaces A and B
      When the person selects workspace B
      Then pane A still resolves workspace A through workspace.pane.owner.v1
      And pane B still resolves workspace B

    @req-kan-fr-003 @header
    Scenario: The board path is derived and visible
      Given a Kanban instance belongs to workspace root repo
      When the view opens
      Then it reads repo/.kanban/board.md
      And the pane header shows that resolved path with head truncation

    @req-kan-fr-012 @rebind
    Scenario: Moving a pane between workspaces replaces its board-owned state
      Given a Kanban instance is open on workspace A
      When its owning workspace changes to B
      Then A's watcher, detail, tracking, and run references are released
      And the instance watches and renders B/.kanban/board.md
      And other Kanban instances remain unchanged

  Rule: Parsing and bounded reads preserve useful data under concurrent edits

    @req-kan-fr-004 @parser
    Scenario Outline: Board structure recognizes only complete format lines
      Given board text contains <line>
      When aio-kanban v3 parsing runs
      Then <result>

      Examples:
        | line | result |
        | a non-empty ## Ready heading | a Ready column begins |
        | a bare ## heading stub | no column begins |
        | a valid linked T-number line under a column | one task belongs to that column |
        | a task-looking line before any column | it is ignored |

    @req-kan-fr-005 @task-parser
    Scenario: Task display and task-file detail have separate bounded fields
      Given a board line has title, priority/effort, and additional dash-separated status prose
      And its linked task file has description, priority, effort, and checked criteria
      When the card and detail are parsed
      Then the first separator ends the title
      And only the immediate meta segment becomes the card badge
      And task-file fields and criterion state appear in detail

    @req-kan-fr-006 @fail-soft
    Scenario: One malformed line cannot blank valid neighbors
      Given a malformed board or task line sits between valid content
      When parsing runs
      Then only the malformed line is skipped or omitted
      And valid surrounding columns, cards, and detail remain visible

    @req-kan-fr-007 @req-kan-nfr-003 @paged-read
    Scenario Outline: Board reads finish under a finite paging contract
      Given a board <condition>
      When the plugin follows filesystem.file.read.v1 cursors
      Then <outcome>

      Examples:
        | condition | outcome |
        | fits one inline page | one reply supplies the full text |
        | spans several pages below 24 | code-point-safe pages reassemble the exact text |
        | changes during a page sequence | the whole read restarts at most three times |
        | still changes after three restarts | file-kept-changing-mid-read is visible |
        | exceeds 24 pages | file-larger-than-24-pages is visible |
        | returns a non-inline shape | unexpected-content-shape is visible |

    @req-kan-fr-008 @req-kan-nfr-011 @honest-error
    Scenario Outline: Missing and failed reads are not conflated
      Given board read returns <result>
      When the pane renders the outcome
      Then <message>

      Examples:
        | result | message |
        | dev.tenon.core.path-not-found | No board at the exact path |
        | denied, invalid, oversized, or another failure | Board read failed followed by the reason |

    @req-kan-fr-009 @req-kan-nfr-005 @stale-refresh
    Scenario: A slow old refresh cannot overwrite newer pane state
      Given refresh generation N is awaiting a page
      When generation N plus 1 publishes first or the pane closes
      Then generation N drops its result
      And current or closed instance state is not mutated

    @req-kan-fr-010 @board-event
    Scenario Outline: Board event describes only a real accepted change
      Given a refresh follows <trigger>
      When its new board text is compared with the prior snapshot
      Then <event outcome>

      Examples:
        | trigger | event outcome |
        | the board bytes changed | one owner-qualified board.changed fact is emitted |
        | an unrelated file changed under .kanban | no board.changed fact is emitted |
        | the same board content is re-read | no board.changed fact is emitted |

    @req-kan-fr-011 @req-kan-nfr-007 @watch
    Scenario: A burst of filesystem facts causes one bounded refresh
      Given one instance owns a watcher for its .kanban directory
      When several watch callbacks arrive within 250 milliseconds
      Then prior debounce timers are cancelled
      And one refresh reads the board after the burst

  Rule: Native fixed columns remain readable rather than squeezing into the pane

    @req-kan-fr-013 @req-kan-nfr-001 @layout
    Scenario Outline: Column width is independent of pane width
      Given the board has five columns and the pane is <width>
      When the native body renders
      Then every column remains a 260-point box in one horizontal ScrollView
      And <overflow behavior>

      Examples:
        | width | overflow behavior |
        | wide | columns keep their fixed width with ordinary spacing |
        | narrow | later columns overflow sideways and are reachable by horizontal scroll |

    @req-kan-fr-014 @column
    Scenario: Empty and populated columns retain one board geometry
      Given one column is empty and another is tall
      When the row renders
      Then each header shows name and count
      And each full-width box fills the row height with cards pinned at the top
      And empty space remains a drop target

    @req-kan-fr-015 @bounds
    Scenario Outline: Growing board content cannot grow one view snapshot without bound
      Given a column has <content>
      When it renders
      Then <bounded result>

      Examples:
        | content | bounded result |
        | 20 cards | the first 12 render and the pane names 8 more |
        | a title longer than 96 characters | the card title is clipped with an ellipsis |
        | metadata longer than 24 characters | the badge text is clipped |
        | more than 12 criteria | only the bounded criterion set renders |

    @req-kan-fr-016 @card
    Scenario Outline: A card exposes only actions valid in its column
      Given a task card is in <position>
      When it renders
      Then it shows task ID, clipped title/meta, More, and a same-instance drag source
      And <buttons>

      Examples:
        | position | buttons |
        | first column | only move right is present |
        | middle column | move left and move right are present |
        | last column | only move left is present |

    @req-kan-nfr-010 @visual
    Scenario: Layout acceptance includes real native pixels
      Given a layout-sensitive Kanban change passes tree-shape tests
      When release evidence is reviewed
      Then a real-host offscreen or installed render also covers narrow horizontal overflow
      And empty versus tall columns, clipping, control placement, and modal geometry are visible

  Rule: More opens current detail and supervises one real terminal run

    @req-kan-fr-017 @modal
    Scenario: More opens one window-level sheet without changing card geometry
      Given a card is visible on the board
      When the person selects More
      Then the host presents one plugin modal over the shell
      And the card remains unchanged with no inline detail expansion

    @req-kan-fr-018 @detail
    Scenario Outline: Detail reflects the current linked task on disk
      Given the person opens a task whose board/file state <state>
      When the plugin refreshes board then task file
      Then <outcome>

      Examples:
        | state | outcome |
        | still exists | bounded description, priority, effort, and criteria render |
        | disappeared from the board | detail and modal close |
        | file read fails | unavailable detail does not masquerade as old content |

    @req-kan-fr-019 @dismiss
    Scenario Outline: Every modal dismissal uses one plugin-owned action
      Given task detail is open
      When the person uses <route>
      Then one dismiss selection closes the modal

      Examples:
        | route |
        | Escape |
        | backdrop |
        | native close control |
        | plugin dismiss action |

    @req-kan-fr-020 @start
    Scenario Outline: Start creates or reports one agent terminal
      Given the task detail is open in its owning workspace
      When terminal.open.v1 <result>
      Then <outcome>

      Examples:
        | result | outcome |
        | returns a valid pane ID | the plugin records that pane under the task and begins current tracking |
        | fails or omits a pane ID | Start failed and its structured reason remain visible |

    @req-kan-fr-020 @start-prompt
    Scenario: Agent prompt preserves workflow context
      Given a task has an ID and linked task path
      When Start invokes terminal.open.v1
      Then the command names the task and task file
      And instructs the agent to follow CLAUDE.md and claim the board before work
      And workingDirectory is the pane's owning workspace root

    @req-kan-fr-021 @req-kan-nfr-007 @tracking
    Scenario Outline: Open detail tracks a bounded current viewport
      Given a recorded agent pane is <state>
      When the 1.2-second tracking tick reads terminal.viewport.read.v1
      Then <outcome>

      Examples:
        | state | outcome |
        | running with output | running, shortened pane ID, and the last 15 non-empty lines of at most 160 characters render |
        | exited | exited renders and tracking stops |
        | closed or unavailable | the run becomes exited and Tracking stopped names the reason |

    @req-kan-fr-022 @req-kan-nfr-006 @run-lifetime
    Scenario: Modal and run have different lifetimes
      Given a live run belongs to the open task
      When the person dismisses and later reopens that task
      Then dismissal stops only the tracking timer
      And the agent pane and run reference remain
      And reopening resumes tracking unless the run already exited

    @req-kan-fr-023 @focus
    Scenario: Focus pane designates the exact recorded run
      Given a task detail records an agent pane ID
      When the person chooses Focus pane
      Then workspace.pane.focus.v1 is sent with that pane in invocation scope

  Rule: Buttons and drag share one fresh atomic relocation

    @req-kan-fr-024 @button-move
    Scenario Outline: Adjacent buttons express one relative move
      Given a task is in a column with <adjacency>
      When the person chooses <button>
      Then the shared move relocator targets <destination>

      Examples:
        | adjacency | button | destination |
        | a left neighbor | move left | the immediately preceding column |
        | a right neighbor | move right | the immediately following column |

    @req-kan-fr-025 @req-kan-nfr-002 @drag-parity
    Scenario: Same-instance drag and accessible buttons perform the same move
      Given a card has pointer drag plus native move buttons
      When the card is dropped on another column or moved by keyboard or VoiceOver button
      Then both routes enter the same bounded move queue and relocation function
      And only an envelope from the exact plugin, view, and instance can reach the drop action

    @req-kan-fr-026 @fresh-move
    Scenario: Move preserves concurrent edits and every unrelated byte
      Given the rendered task line may be stale because another agent edited the board
      When a move begins
      Then it re-reads the current board
      And moves the first occurrence of that task's verbatim line using the parser's same heading predicate
      And every other line remains byte-for-byte in its current order

    @req-kan-fr-027 @move-no-op
    Scenario Outline: A move that cannot change state performs no write
      Given the requested destination is <condition>
      When relocation evaluates the current board
      Then <outcome>

      Examples:
        | condition | outcome |
        | the card's current column | unchanged returns and no write occurs |
        | outside the adjacent or column range | no-adjacent-column is visible and no write occurs |
        | for a task no longer present | task-not-found is visible and no write occurs |

    @req-kan-fr-028 @empty-column
    Scenario Outline: Target insertion follows board structure
      Given the target column <contents>
      When a task line moves there
      Then <location>

      Examples:
        | contents | location |
        | has task lines | the moved line follows its last task line |
        | is empty | the moved line follows the column heading |

    @req-kan-fr-029 @move-queue
    Scenario Outline: Per-pane moves are serialized and finite
      Given one move is still reading or writing
      When <additional actions>
      Then <outcome>

      Examples:
        | additional actions | outcome |
        | a second through fourth move arrives | each waits and computes from the prior committed result |
        | a fifth queued move arrives | Move refused too-many-queued-moves is visible |

    @req-kan-fr-030 @rebind-race
    Scenario: Mid-move workspace rebinding cannot cross-write boards
      Given a move captured workspace A's board path
      When the pane rebinds to workspace B before paging completes
      Then the move reads and writes only A's captured path
      And it never writes A content to B's board

    @req-kan-fr-031 @paged-write
    Scenario Outline: Board write is one atomic target change
      Given relocated UTF-8 board text <size>
      When writeFile commits it
      Then <protocol>
      And code points are never split between pages

      Examples:
        | size | protocol |
        | fits 48 KiB | one filesystem.file.write.v1 call publishes the whole target |
        | spans 2 through 21 pages | cursor staging receives pages and only the final call commits one atomic rename |
        | exceeds 21 pages | board-larger-than-21-pages is visible and the target is unchanged |

    @req-kan-fr-032 @req-kan-nfr-004 @failure-recovery
    Scenario Outline: Failed move returns to the disk's actual state
      Given a move fails during <phase>
      When the operation reaches its terminal path
      Then no partial target becomes visible
      And a bounded read, move, or write reason renders
      And the pane refreshes from disk

      Examples:
        | phase |
        | fresh read or invalidation restart |
        | relocation |
        | staged page append or cursor recovery |
        | atomic commit |

  Rule: Plugin boundaries and lifecycle remain complete

    @req-kan-fr-033 @lifecycle
    Scenario: Closing one Kanban instance releases only its owned work
      Given two instances own separate watchers and one has an open-modal tracking timer
      When one instance closes or its generation retires
      Then its watcher, debounce, tracking, pending publication, and late callbacks stop
      And the other instance remains live
      And any agent terminal pane is not implicitly closed

    @req-kan-fr-034 @req-kan-nfr-008 @boundary
    Scenario: Kanban needs no bespoke host capability
      Given the complete board, move, detail, and run workflow executes
      When public boundary fitness audits it
      Then UI is CONTRIBUTION and user facts or board.changed are EVENT
      And watcher and timer are RESOURCE, path/parser/relocator are plugin-local DIRECT
      And filesystem, workspace, and terminal effects are manifest-declared canonical INTENTS
      And no native host object enters JavaScript

    @req-kan-nfr-005 @determinism
    Scenario: Identical concurrent action order yields identical board state
      Given the same starting board, pane instance, refresh generations, and ordered move requests
      When the sequence is replayed
      Then the same accepted refresh and serialized relocations produce the same final bytes and view

    @req-kan-nfr-009 @compatibility
    Scenario: Historical shapes stay superseded without breaking the file format
      Given an existing aio-kanban v3 board and a one-page board write load
      When the current plugin renders and mutates them
      Then valid historical board lines remain readable and the small write stays byte-compatible
      And the old tree-list and inline-detail UI are not restored beside fixed columns and modal
