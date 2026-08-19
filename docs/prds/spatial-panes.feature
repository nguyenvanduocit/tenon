# language: en

@prd-TENON_PRD_003
Feature: Arrange live panes without losing identity, focus, or attention
  An operator supervising several work surfaces needs every pane interaction to preserve
  valid geometry and live context while remaining accessible and diagnosable.
  PRD: spatial-panes.prd.md

  Rule: The spatial core admits only valid deterministic layouts

    @req-sp-fr-001 @req-sp-nfr-001 @grid
    Scenario: Every pane fits the logical canvas without overlap
      Given a tab contains several panes on the spatial canvas
      Then every pane lies within the twelve by twelve logical grid
      And every pane is at least three columns by three rows
      And no two panes overlap or share an identity

    @req-sp-fr-001 @req-sp-nfr-002 @invalid
    Scenario Outline: Invalid geometry is rejected atomically
      Given the current tab layout is valid
      When a proposed layout would <violation>
      Then the proposal is invalid
      And the catalog layout remains unchanged
      And no geometry fact is published

      Examples:
        | violation |
        | move a pane outside the canvas |
        | overlap two panes |
        | shrink a pane below its minimum width |
        | shrink a pane below its minimum height |
        | repeat a pane identity |

    @req-sp-fr-002 @req-sp-nfr-004 @identity
    Scenario: Moving a pane preserves the resource joined to its identity
      Given a pane owns live content under a stable pane identity
      When a valid geometry or tab move is committed
      Then the pane keeps the same identity and content value
      And its live terminal, web, editor, or plugin resource is not restarted

    @req-sp-fr-016 @req-sp-nfr-001 @req-sp-nfr-002 @transaction
    Scenario Outline: A transaction that does not match current truth is refused
      Given the active tab has an authoritative layout
      When a transaction carries <mismatch>
      Then no part of its proposal is committed
      And the authoritative layout and events remain unchanged

      Examples:
        | mismatch |
        | a stale baseline |
        | the wrong operation kind |
        | an affected pane set different from the actual changes |
        | a no-op proposal |
        | geometry belonging to another tab |

  Rule: Pane creation, split, duplicate, and close share one placement policy

    @req-sp-fr-003 @req-sp-nfr-001 @creation
    Scenario: Creating near free canvas uses the best valid region
      Given the active tab has a fillable empty region near the creation anchor
      When a pane is created from that anchor
      Then the new pane occupies the best valid empty region near the anchor
      And no existing pane is resized
      And the new pane becomes active

    @req-sp-fr-003 @req-sp-fr-005 @creation @fallback
    Scenario: Creating with no free region splits the named pane
      Given the canvas has no fillable empty region
      And the named pane can split on one axis
      When a new pane is requested beside it
      Then the named pane is split on a valid axis
      And a new stable pane appears to its right or below
      And the new pane receives focus

    @req-sp-fr-003 @req-sp-fr-004 @empty-canvas
    Scenario: An empty-canvas launcher reserves the region the operator clicked
      Given the pointer is inside one fillable empty region
      When the operator opens content there with a creation-width limit
      Then the reserved rectangle still contains the clicked logical cell
      And width declined by the limit remains empty canvas

    @req-sp-fr-004 @sizing
    Scenario Outline: A future pane respects the configured maximum and available width
      Given the automatic pane-width maximum is <maximum>
      And the available region is <available> columns wide
      When a new pane is created
      Then its width is <expected> columns
      And every existing pane keeps its previous rectangle

      Examples:
        | maximum | available | expected |
        | unlimited | 9 | 9 |
        | one half | 9 | 6 |
        | one third | 9 | 4 |
        | one half | 3 | 3 |

    @req-sp-fr-004 @sizing @future-only
    Scenario: Changing the automatic-layout maximum never resizes an existing pane
      Given a pane already exists at its committed width
      When the operator changes the automatic pane-width maximum
      Then the existing pane remains at its committed width
      And it can still be resized through ordinary pane controls

    @req-sp-fr-004 @req-sp-fr-006 @sizing @close
    Scenario: Closing a pane respects the automatic-layout maximum
      Given a neighboring pane is narrower than the configured maximum
      When another pane beside it closes
      Then the neighbor grows into the released region only up to the configured maximum
      And any declined columns remain empty canvas

    @req-sp-fr-004 @req-sp-fr-006 @sizing @close
    Scenario: Closing a pane never shrinks a neighbor already wider than the maximum
      Given a neighboring pane is wider than the configured maximum
      When another pane beside it closes
      Then the neighbor keeps its committed width
      And any declined columns remain empty canvas

    @req-sp-fr-004 @req-sp-fr-006 @sizing @cross-tab
    Scenario: A pane dragged to another tab leaves the same width behind as closing it
      Given a neighboring pane is narrower than the configured maximum
      When the pane beside it is dragged out to another tab
      Then the neighbor grows into the released region only up to the configured maximum
      And it stands exactly where closing that pane would have left it

    @req-sp-fr-004 @req-sp-fr-014 @sizing @cross-tab
    Scenario: A pane released on the tab bar opens at the configured maximum
      Given the operator carries a pane over the tab bar
      When the operator releases it onto a new tab
      Then the pane fills that tab only up to the configured maximum
      And any declined columns remain empty canvas

    @req-sp-fr-004 @req-sp-fr-014 @sizing @cross-tab
    Scenario: A pane released on a tab chip takes free canvas bounded by the maximum
      Given the target tab has an empty region wider than the configured maximum
      When the operator releases the carried pane on that tab's chip
      Then the pane takes the empty region only up to the configured maximum

    @req-sp-fr-004 @req-sp-fr-014 @sizing @cross-tab @empty-grid
    Scenario: A pane released on a highlighted region adopts that region whole
      Given the target tab has an empty region wider than the configured maximum
      And the drop highlight promises that region's committed pane frame
      When the operator releases the carried pane inside that region
      Then the pane occupies exactly the promised frame
      And the configured maximum does not narrow it

    @req-sp-fr-005 @split @targeting
    Scenario Outline: Split and Stack target the clicked pane rather than the active pane
      Given pane Alpha is active and pane Beta is selected through its header menu
      When the operator chooses <action> for pane Beta
      Then pane Beta is divided <direction>
      And pane Alpha is not resized
      And the new pane becomes active

      Examples:
        | action | direction |
        | Split | horizontally |
        | Stack | vertically |

    @req-sp-fr-006 @close
    Scenario: Closing a pane absorbs its region deterministically
      Given a tab has several valid neighboring panes
      When one pane is closed
      Then one valid neighbor absorbs its released region by the deterministic close rule
      Except horizontal growth stops at the configured maximum and leaves declined width empty
      And unrelated panes keep their identity and content
      And the tab keeps a valid active pane

    @req-sp-fr-006 @close @empty-tab
    Scenario: Closing the final pane closes its tab when another tab survives
      Given a workspace contains several tabs
      And one tab contains exactly one pane
      When that pane is closed
      Then that tab is removed
      And a surviving tab becomes active with its remembered active pane

    @req-sp-fr-006 @close @empty-tab @last-tab
    Scenario: Closing the final pane of the workspace's only tab keeps the required tab
      Given the workspace's only tab contains exactly one pane
      When that pane is closed
      Then the tab remains present with no panes
      And the tab has no active pane

    @req-sp-fr-007 @duplicate
    Scenario: Duplicate creates a separate pane showing the clicked content
      Given a clicked pane can be placed or split
      When the operator chooses Duplicate
      Then a new pane with a new stable identity is created near the clicked pane
      And its content value equals the clicked pane's content value
      And the copied pane becomes active

    @req-sp-fr-007 @duplicate @disabled
    Scenario: Duplicate is disabled when no valid placement exists
      Given the clicked pane is too small to split on either axis
      And no fillable empty region remains
      When its header menu opens
      Then Duplicate is visible but disabled
      And activating it cannot mutate the layout

  Rule: Pane chrome keeps utilities direct and region ownership unambiguous

    @req-sp-fr-008 @req-sp-nfr-009 @menu
    Scenario: The bare pane header exposes the complete flat menu
      Given a pane header has enough geometry for all pane operations
      When the operator secondary-clicks its bare header
      Then the menu contains Split, Stack, Duplicate, Copy Pane ID, and Close in that order with separators
      And no item has a submenu
      And no Change Type action is present

    @req-sp-fr-008 @menu @targeting
    Scenario: Closing an inactive pane from its menu does not focus it first
      Given one pane is active and another pane's header menu is open
      When the operator chooses Close for the inactive pane
      Then the inactive pane closes
      And no transient focus fact for that pane is published before closure

    @req-sp-fr-009 @req-sp-nfr-005 @copy-id
    Scenario Outline: Copy Pane ID uses the same direct route from every native entry point
      Given a pane has a stable UUID
      When the operator invokes <entry>
      Then the pasteboard contains only that raw UUID

      Examples:
        | entry |
        | Copy Pane ID from the header menu |
        | the pane's Copy Pane ID accessibility action |

    @req-sp-fr-029 @req-sp-fr-008 @menu @agent-session
    Scenario: An agent pane offers its session continuations where their groups live
      Given a pane carries an agent session and its provider's CLI is installed here
      When the operator secondary-clicks its bare header
      Then Fork Session appears directly after Duplicate
      And Copy Resume Command appears directly after Copy Pane ID
      And a pane carrying no agent session shows neither item

    @req-sp-fr-029 @menu @agent-session
    Scenario: Fork Session opens a fresh terminal beside the pane running the provider's own fork
      Given a pane carries a Claude Code session
      When the operator chooses Fork Session
      Then a new terminal pane opens beside the clicked pane using Duplicate's placement
      And the provider's fork of that session is queued for the shell that pane is about to build
      And the clicked pane is left exactly as it was

    @req-sp-fr-029 @menu @agent-session
    Scenario: Copy Resume Command places the provider's resume line on the clipboard
      Given a pane carries an agent session
      When the operator chooses Copy Resume Command
      Then the clipboard holds the provider's resume command for that session
      And the command carries the options this person always passes their agent
      And it does not mint a new session

    @req-sp-fr-029 @menu @agent-session @refusal
    Scenario: A missing provider CLI greys the continuations and states why
      Given a pane carries a session whose provider CLI is not installed on this machine
      When its header menu opens
      Then Fork Session and Copy Resume Command are visible but disabled
      And each item states, where the item is, that the provider is not installed

    @req-sp-fr-030 @agent-session @recorded-pane
    Scenario: A recorded session's résumé invitation catches up once agent detection resolves
      Given a recorded-session pane's résumé invitation was drawn before agent detection finished
      When agent detection later reports the provider CLI is installed here
      Then the pane's résumé invitation offers Resume instead of stating the provider is missing

    @req-sp-fr-010 @fill-width
    Scenario: Double-clicking bare header fills available width only
      Given a pane has horizontal free space before its nearest blocking neighbors
      When the operator double-clicks the bare header
      Then the pane grows to those neighbors or the canvas edges
      And no neighbor moves or shrinks

    @req-sp-fr-010 @fill-width @no-op
    Scenario: Filling a pane already spanning its band changes nothing
      Given a pane already reaches every horizontal boundary in its row band
      When the operator double-clicks the bare header
      Then its rectangle remains unchanged
      And no resize fact is published

    @req-sp-fr-011 @resize-menu
    Scenario Outline: A pane border offers exact named canvas fractions
      Given the operator secondary-clicks the pane's <edge> border
      When the resize menu opens
      Then it offers one third, one half, and full
      And choosing a valid value changes only the <axis> extent
      And the opposite edge remains fixed

      Examples:
        | edge | axis |
        | east | horizontal |
        | west | horizontal |
        | north | vertical |
        | south | vertical |

    @req-sp-fr-011 @resize-menu @disabled
    Scenario: An impossible or current border size is disabled
      Given one named border destination would overlap a neighbor or change nothing
      When the border resize menu opens
      Then that destination is visible but disabled
      And the other valid destinations remain available

    @req-sp-fr-012 @cycle-size
    Scenario: Border double-click cycles through the same named sizes
      Given a pane border can reach full, one half, and one third
      When the operator repeatedly double-clicks that border
      Then its axis cycles full, one half, one third, then full
      And its opposite edge stays fixed

    @req-sp-fr-012 @cycle-size @skip-invalid
    Scenario: Border cycling skips a destination the layout refuses
      Given the next named size would make the layout invalid
      And a later named size is valid
      When the operator double-clicks that border
      Then the pane moves directly to the later valid size
      And no invalid intermediate layout is displayed

  Rule: Drag and resize preview exactly what can settle

    @req-sp-fr-013 @req-sp-nfr-009 @drag
    Scenario: A short header movement remains a click
      Given the operator presses bare pane header
      When the pointer travels less than four points before release
      Then no pane pickup begins
      And the live pane stays in place

    @req-sp-fr-013 @req-sp-nfr-004 @drag @thumbnail
    Scenario: Pane pickup carries one complete snapshot while the live resource stays mounted
      Given a live pane has body content and host chrome
      When a header drag crosses the pickup threshold
      Then one floating thumbnail contains the complete pane and header
      And the live card and resource remain mounted at the source during the drag

    @req-sp-fr-014 @drag @empty-grid
    Scenario: Dropping in free canvas commits the snapped valid move
      Given a pane is being carried over a fillable empty grid region
      When the operator releases on a valid snapped destination
      Then the pane moves to the displayed logical rectangle
      And its stable identity and live resource are preserved

    @req-sp-fr-014 @drag @beside
    Scenario Outline: Dropping over another pane uses its directional quadrant
      Given a pane is carried over the target pane's <quadrant> region
      When the operator releases the pane
      Then it is placed at the target pane's <edge> edge through a valid transaction

      Examples:
        | quadrant | edge |
        | left triangle | left |
        | right triangle | right |
        | top triangle | top |
        | bottom triangle | bottom |

    @req-sp-fr-014 @drag @cross-tab
    Scenario: A routed tab target accepts a pane without restarting it
      Given a pane is carried from its source tab
      When the operator settles over another tab and releases on a valid target edge
      Then the pane becomes owned by the target tab
      And its source layout reflows validly
      And its stable identity, content, and live resource are preserved

    @req-sp-fr-014 @drag @cross-tab @empty-grid
    Scenario: A routed tab target accepts a pane on its empty canvas
      Given a pane is carried from its source tab
      And the hover-revealed tab still has a fillable empty grid region
      When the operator points inside that region
      Then the drop highlight promises exactly the region's committed pane frame
      When the operator releases there
      Then the pane fills the empty region containing the pointed cell
      And no existing pane in the target tab is reshaped
      And a region too small for a pane is never offered as a destination

    @req-sp-fr-014 @req-sp-nfr-002 @cancel
    Scenario Outline: Cancelling an active drag restores authoritative presentation
      Given a pane drag has an ephemeral valid preview
      When <cancellation> ends the gesture
      Then the catalog remains at the authoritative baseline
      And the thumbnail, target highlight, and preview are removed
      And the appropriate previous responder is restored

      Examples:
        | cancellation |
        | the operator presses Escape |
        | the canvas is detached |
        | a routed tab hover is cancelled |

    @req-sp-fr-015 @invalid-move
    Scenario: Leaving a valid move target for an invalid gap clears and rolls back
      Given a pane drag previously had a valid move target
      When the pointer moves to a location with no valid destination
      Then no invalid move preview or target is displayed
      When the operator releases there
      Then the pane returns to its authoritative baseline

    @req-sp-fr-015 @invalid-resize
    Scenario: An invalid resize keeps the last valid edge
      Given a resize drag has produced a valid preview
      When the pointer continues into an impossible resize
      Then the last valid resize remains displayed
      And no overlapping or undersized proposal appears
      When the operator releases
      Then the displayed valid resize is committed

    @req-sp-fr-016 @stale
    Scenario: Store changes during a gesture invalidate the old preview
      Given a pane gesture began from one layout snapshot
      And another committed mutation changes the authoritative layout
      When the stale gesture next updates or ends
      Then its old preview is removed
      And the newer authoritative geometry remains rendered and stored

  Rule: Focus converges and genuine user focus still works

    @req-sp-fr-017 @req-sp-nfr-003 @focus
    Scenario: A newly created pane wins competing focus commands once
      Given a launcher creates and focuses a new pane while the previous responder may return
      When queued focus work settles
      Then the new pane remains the active pane
      And focus transitions stop without further user input

    @req-sp-fr-017 @focus @stale
    Scenario: A queued command for a pane no longer active is dropped
      Given a focus command is queued for pane Beta
      When the model moves active focus to pane Alpha before the command runs
      Then pane Beta does not become first responder
      And pane Alpha remains active

    @req-sp-fr-017 @focus @direct-user
    Scenario: A genuine click into another pane updates model focus
      Given no host-driven focus or overlay restoration is in progress
      When the window system reports that the operator focused pane Beta
      Then the workspace active pane becomes Beta
      And exactly one model focus transition is recorded

    @req-sp-fr-017 @focus @overlay
    Scenario: Dismissing an overlay cannot reclaim focus for the old pane
      Given an overlay creates and focuses a new pane
      When the window system restores the pre-overlay responder during dismissal
      Then that restoration is not adopted as a user focus choice
      And the new pane remains active

  Rule: One bounded host header serves built-in and plugin panes

    @req-sp-fr-018 @req-sp-nfr-006 @header
    Scenario: A pane renders one host-owned chrome header
      Given a built-in or plugin pane is mounted
      When the pane is rendered
      Then exactly one 34-point header contains host glyph, attention, title, and close
      And pane content does not render a second identity toolbar

    @req-sp-fr-019 @req-sp-nfr-009 @header-layout
    Scenario: Header controls never consume close, resize, or guaranteed drag regions
      Given a pane publishes the maximum supported leading and trailing header items
      When the host solves the header at a supported pane width
      Then every interactive item has a disjoint hit and cursor rectangle
      And the close control and north resize edge remain reachable
      And a bare draggable band remains reachable

    @req-sp-fr-019 @header-bounds
    Scenario Outline: An invalid header value fails soft without corrupting siblings
      Given a header contribution contains <invalid-item>
      When the host admits the header value
      Then the invalid item is refused or bounded by its field's contract
      And valid sibling items remain deterministically ordered

      Examples:
        | invalid-item |
        | a duplicate identity across leading and trailing slots |
        | the host-reserved overflow identity |
        | an overlong routing identity |
        | an undrawable glyph control |
        | too many items in one slot |

    @req-sp-fr-019 @header-overflow
    Scenario: Folded actionable header items remain reachable in overflow
      Given the pane is too narrow for every admitted header item
      When the host folds items into overflow
      Then every folded actionable item has a reachable overflow entry
      And choosing it reports the original item's identity and value

    @req-sp-fr-020 @req-sp-nfr-007 @header @built-in
    Scenario: A built-in header action focuses its pane and uses a typed host command
      Given an inactive built-in pane publishes an interactive header control
      When the operator activates that control
      Then the pane becomes active before its state changes
      And a typed same-owner command handles the action directly
      And no public intent or plugin callback is created

    @req-sp-fr-020 @req-sp-nfr-007 @req-sp-nfr-008 @header @plugin
    Scenario: A plugin header action returns only to its declaring live instance
      Given a live plugin view instance published a bounded header control
      When the operator activates that control
      Then the existing select or submit event reaches that plugin, view, and instance
      And no other instance or retired generation receives it
      And no native view or geometry object crosses the plugin boundary

    @req-sp-fr-020 @req-sp-nfr-003 @header-refresh
    Scenario: Updating header state does not rebuild pane content
      Given a pane's content resource is mounted under one stable content identity
      When its header contribution, attention, or focus presentation changes
      Then the header refreshes
      And the existing content host and live resource remain mounted

  Rule: Attention is one truthful machine and clears only through viewing

    @req-sp-fr-021 @attention
    Scenario Outline: Terminal evidence derives the pane's activity state
      Given a materialized terminal pane is <viewed-state>
      When <observation> is observed
      Then its activity becomes <state>
      And its unseen flag is <unseen>

      Examples:
        | viewed-state | observation | state | unseen |
        | viewed | output continues changing | working | clear |
        | viewed | the screen remains stable without a new finish | idle | clear |
        | not viewed | a real command finish counter advances | finished unseen | set |
        | viewed | a real command finish counter advances | seen | clear |
        | not viewed | the shell process exits | exited | set |

    @req-sp-fr-021 @attention @acknowledgement
    Scenario: Later output does not acknowledge unseen work
      Given a pane finished while unviewed and is marked unseen
      When the pane begins producing output again
      Then its activity may become working
      And its unseen flag remains set until the pane is actually viewed

    @req-sp-fr-022 @attention @viewed
    Scenario Outline: A pane counts as viewed only when all three conditions hold
      Given the app is <frontmost>
      And the pane's workspace is <workspace-state>
      And the pane is <display-state>
      When viewed state is projected
      Then the pane is <result>

      Examples:
        | frontmost | workspace-state | display-state | result |
        | frontmost | selected | displayed in the active tab | viewed |
        | background | selected | displayed in the active tab | not viewed |
        | frontmost | not selected | displayed in its tab | not viewed |
        | frontmost | selected | in a background tab | not viewed |

    @req-sp-fr-022 @req-sp-nfr-003 @attention @projection
    Scenario: Every shell attention surface reads the same pane machines
      Given panes across several tabs and workspaces have activity states
      When the shell renders pane dots, tab state and bolding, workspace counts, and the global count
      Then every value is a projection of those same per-pane machines
      And an unchanged poll pass produces no observable republish

    @req-sp-fr-022 @attention @notification
    Scenario: A background burst produces one actionable notification
      Given the app is not frontmost
      When several panes become unseen in one observation pass
      Then at most one system notification summarizes the burst
      When the operator activates that notification
      Then Tenon activates and focuses its first named pane

  Rule: Pane resources are lazy, retained, and canvas-sized

    @req-sp-fr-023 @req-sp-nfr-004 @lazy
    Scenario: A pane never viewed owns no live renderer resource
      Given a pane exists in a background tab or restored catalog
      And the pane has never been displayed
      Then it owns no terminal surface, PTY, or renderer buffer
      And reading its placeholder title or directory does not materialize it

    @req-sp-fr-023 @lazy @first-view
    Scenario: First display materializes once and flushes queued input
      Given text is queued for a terminal pane that has no surface yet
      When the pane is displayed for the first time
      Then one fresh terminal surface is created under that pane identity
      And the queued text is delivered to it

    @req-sp-fr-023 @req-sp-nfr-004 @lifetime
    Scenario: A viewed resource survives hiding and dies with its slot
      Given a pane has materialized its live resource
      When focus, tab selection, workspace selection, geometry, or view mounting changes without removing the pane
      Then the same resource remains alive
      When the pane identity leaves the catalog
      Then that resource is released exactly once

    @req-sp-fr-024 @req-sp-nfr-003 @hosting
    Scenario: Pane size flows from canvas to content only
      Given the canvas assigns a frame to a pane card
      When its SwiftUI content host is mounted
      Then the content host publishes no minimum, intrinsic, or maximum sizing options upward
      And the card assigns the body frame from its own bounds

    @req-sp-fr-024 @req-sp-nfr-011 @req-sp-nfr-012 @update-bound
    Scenario: An unchanged hosted lazy pane converges
      Given a real pane host contains a scrolling lazy list and receives no state changes
      When the run loop is observed across consecutive settled intervals
      Then its body evaluation count stops increasing
      And the evidence is recorded as a bound and mitigation
      And the stage-level measurement that drove the reproduced stall is covered by SP-FR-027

    @req-sp-fr-027 @hosting
    Scenario: The canvas answers the size it is proposed
      Given the stage asks the canvas how large it wants to be
      When the canvas is measured
      Then it answers the proposed width and height
      And no fitting-size sweep runs over the cards beneath it

    @req-sp-fr-027 @hosting
    Scenario: A canvas that answers nothing sends the question to AppKit
      Given a representable that declares no size of its own sits inside a stack
      When the stack computes its size
      Then AppKit is asked for a fitting size
      And answering it walks the subtree the stack was measuring

    @req-sp-nfr-013 @attention
    Scenario: The attention poll never renders a pane's screen as text
      Given several panes are open and the fixed-interval attention poll runs over all of them
      When the poll takes consecutive samples of every pane
      Then it obtains each screen as a fingerprint
      And no pane is asked to render its screen to text

    @req-sp-fr-024 @req-sp-nfr-011 @incident
    Scenario: A future sustained main-runloop stall records evidence automatically
      Given the current build detects one sustained main-runloop stall
      When the stall crosses its diagnostic threshold
      Then a bounded process sample is captured outside the blocked main thread
      And another sample is not captured until that stall ends and a new stall begins

  Rule: Public ownership queries and accessibility reveal only the right facts

    @req-sp-fr-025 @req-sp-nfr-007 @req-sp-nfr-008 @pane-owner
    Scenario: A programmatic caller resolves a pane in an unselected workspace
      Given a plugin, CLI, or agent caller knows one valid pane UUID
      And that pane belongs to a tab outside the selected workspace and first state page
      When the caller sends the versioned pane-owner request
      Then the response contains only its workspace UUID, workspace path, and tab UUID

    @req-sp-fr-025 @pane-owner @errors
    Scenario Outline: Pane-owner input fails deterministically
      Given a programmatic pane-owner request contains <input>
      When the request is evaluated
      Then it returns <result> without changing workspace state

      Examples:
        | input | result |
        | text that is not a UUID | an invalid-input error |
        | a UUID not present anywhere in the catalog | a workspace-unavailable error |

    @req-sp-fr-028 @tab-close
    Scenario: Closing a scoped tab takes every pane under it
      Given a workspace holds two tabs and the caller names one of them
      When the caller sends the versioned tab-close request
      Then that tab and all of its panes leave the catalog
      And the other tab is untouched

    @req-sp-fr-028 @tab-close @errors
    Scenario Outline: Tab close refuses rather than reporting an empty success
      Given a programmatic tab-close request carries <scope>
      When the request is evaluated
      Then it returns <result> without changing workspace state

      Examples:
        | scope | result |
        | no tab at all | a tab-not-found error |
        | a tab UUID no workspace holds | a tab-not-found error |
        | the only tab of its workspace | a close-refused error |

    @req-sp-fr-026 @req-sp-nfr-005 @accessibility
    Scenario: VoiceOver hears useful pane position instead of implementation identifiers
      Given a pane occupies a known logical rectangle
      When its accessibility value is read
      Then it announces a one-based column, row, and extent in words
      And it does not speak the raw pane UUID or raw grid tuple
      And exact UUID and rectangle remain available in its non-spoken identifier

    @req-sp-fr-026 @req-sp-nfr-005 @attention @non-color
    Scenario: Attention remains readable without color
      Given Differentiate Without Color is enabled
      When pane, tab, and workspace attention is rendered
      Then every activity state uses its meaningful symbol and spoken wording
      And unseen and selected state remain distinguishable without hue

    @req-sp-fr-026 @req-sp-nfr-009 @empty-region
    Scenario: Keyboard and assistive input can address fillable empty canvas
      Given the active canvas contains one or more distinct fillable empty regions
      When the operator uses Option-Return or a Fill Empty Region accessibility action
      Then the shared launcher targets the corresponding exact region
      And no occupied gutter is mistaken for empty workspace

  Rule: Responsibility boundaries remain reviewable

    @req-sp-nfr-010 @architecture
    Scenario: A pane interaction has one owner at each layer
      Given a pane gesture is evaluated and rendered
      Then pure spatial math owns valid geometry
      And the interaction coordinator owns gesture decisions
      And the AppKit canvas owns mounting and pointer capture
      And the pane card owns hit testing and chrome presentation
      And typed stores own focus, headers, attention, and resources without duplicating geometry

    @req-sp-nfr-012 @evidence
    Scenario: Review distinguishes proof from hypothesis
      Given pane documentation reports an incident or native interaction outcome
      When the evidence is reviewed
      Then measured production data, deterministic tests, candidate mitigation, and human-only checks are labeled separately
      And an unreproduced incident is not reported as fixed

  @req-sp-fr-028 @pane-chrome
  Scenario: An agent labels the tab the person is looking at
    Given a pane an agent is working in
    When it sets its own pane title to "Fixing the token refresh race"
    Then the pane carries that pinned title
    When it sets an empty title
    Then the pane returns to the title its content derives

  @req-sp-fr-028 @pane-chrome
  Scenario: A rename addresses the pane it names and no other
    Given a caller sends a pane title with no pane in scope
    Then it is refused
    And the focused pane keeps its title
