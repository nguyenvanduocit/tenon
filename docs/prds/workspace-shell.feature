# language: en

@prd-TENON_PRD_001
Feature: Resume work in a stable native workspace shell
  An operator supervising several projects needs Tenon to preserve the identity,
  navigation, and valid layout of each workspace without mixing their context.
  PRD: workspace-shell.prd.md

  Rule: The shell has one native window and one catalog truth

    @req-ws-fr-001 @req-ws-nfr-009 @singleton
    Scenario: Launching Tenon presents the one workspace window
      Given Tenon has completed startup preparation
      When the application presents its workspace shell
      Then one main workspace window with stable identity is available
      And the application offers no action that creates another workspace window

    @req-ws-fr-002 @req-ws-nfr-006 @req-ws-nfr-010 @titlebar
    Scenario: Empty titlebar chrome behaves like native window chrome
      Given the compact titlebar shows the Tenon identity and tab strip beside the traffic lights
      When the operator drags an empty titlebar gap
      Then the system moves the window without taking input from a titlebar control
      And a double click on that gap follows the configured system titlebar action

    @req-ws-fr-034 @titlebar
    Scenario: The identity zone names the workspace exactly while nothing else does
      Given the sidebar is collapsed to its icon rail, where a workspace name appears only in a tooltip
      When the operator reads the title bar's identity zone
      Then the zone shows the active workspace's name in place of the Tenon wordmark
      And a name too long for the zone is truncated at its tail with the whole name in its tooltip
      And expanding the sidebar returns the zone to the wordmark, because the workspace list names the active workspace

    @req-ws-fr-003 @req-ws-nfr-009 @catalog
    Scenario: A valid catalog keeps every identity and selection internally consistent
      Given a catalog contains one or more workspaces
      Then every workspace and tab has a unique stable identifier
      And every workspace contains at least one tab
      And every non-empty tab selects one of its own panes
      And every empty tab has no active pane
      And no pane identifier appears in two tabs

    @req-ws-fr-003 @invalid @atomic
    Scenario Outline: An invalid catalog mutation changes nothing
      Given the current catalog is valid
      When a mutation would <violation>
      Then the catalog remains byte-for-value unchanged
      And no workspace fact is published

      Examples:
        | violation |
        | remove its final workspace |
        | remove a workspace that does not exist |
        | select a tab outside the active workspace |
        | select a pane outside its owning tab |

  Rule: Workspace and tab navigation preserve local context

    @req-ws-fr-004 @add-workspace
    Scenario: Adding a directory creates and selects a workspace
      Given the operator chooses one directory from Add Workspace
      When the directory is accepted
      Then a new stable workspace is created with the derived folder name
      And its initial tab uses the current default content and pane sizing
      And the new workspace becomes active
      And the folder is recorded in recent-workspace history

    @req-ws-fr-025 @add-workspace @drag-and-drop
    Scenario: Dropping a folder on the sidebar opens a workspace at it
      Given no open workspace is rooted at a folder
      When the operator drops that folder on the sidebar
      Then a new workspace is created with the derived folder name
      And the new workspace becomes active
      And the folder is recorded in recent-workspace history

    @req-ws-fr-025 @add-workspace @drag-and-drop
    Scenario: Dropping a folder that is already open reveals it instead of duplicating it
      Given an open workspace is rooted at a folder
      When the operator drops that folder on the sidebar
      Then no workspace is added
      And the workspace already rooted at that folder becomes active

    @req-ws-fr-025 @drag-and-drop
    Scenario: Dropping several folders at once opens each of them in order
      Given three folders no open workspace is rooted at
      When the operator drops all three on the sidebar together
      Then a workspace is opened for each of them in the order they were dropped
      And the last dropped folder's workspace is active

    @req-ws-fr-025 @drag-and-drop
    Scenario: A dropped file is refused rather than read as its parent folder
      Given the operator drags a file rather than a folder
      When the pointer passes over the sidebar
      Then the sidebar does not offer itself as a drop target
      And releasing the file leaves the workspace catalog unchanged

    @req-ws-fr-026 @workspace-close @running-process
    Scenario: Removing a workspace with terminal work asks before destroying it
      Given a workspace owns a pane whose terminal process cannot be proved idle
      When the operator chooses Remove Workspace from that workspace row
      Then a native destructive confirmation names that workspace
      And cancelling leaves the workspace and every pane it owns unchanged
      And confirming removes the workspace through the typed workspace service

    @req-ws-fr-026 @workspace-close @idle
    Scenario: Removing an idle workspace needs no confirmation
      Given every live terminal in a workspace has complete process identity
      And process inspection classifies every one as an idle shell
      When the operator chooses Remove Workspace from that workspace row
      Then the workspace is removed without a confirmation

    @req-ws-fr-026 @workspace-close @race
    Scenario: A pane or foreground process changed during inspection fails safe
      Given workspace removal is waiting for process inspection
      When the workspace pane set or a pane's foreground process changes before inspection returns idle
      Then the stale idle answer does not remove the workspace
      And Tenon asks for destructive confirmation instead

    @req-ws-fr-005 @selection
    Scenario: Selecting a workspace restores its active tab and pane
      Given two workspaces each remember a different active tab and pane
      When the operator selects the inactive workspace
      Then that workspace becomes active
      And its remembered tab becomes visible
      And its remembered pane receives focus
      And the previously active workspace keeps its resource identities

    @req-ws-fr-005 @req-ws-nfr-007 @events
    Scenario: Workspace selection publishes facts in semantic order
      Given an inactive workspace has a non-empty active tab
      When that workspace is selected
      Then the published facts say workspace selected before tab selected
      And slot focused follows for that tab's active pane
      And no public customization or navigation capability is created by the native action

    @req-ws-fr-031 @req-ws-nfr-005 @req-ws-nfr-007 @reorder
    Scenario: Dragging a workspace row changes the sidebar order under the pointer
      Given the sidebar displays several workspace rows
      When the operator drags one row past a neighboring row
      Then that workspace moves to the insertion place named by the pointer
      And the active workspace, tabs, panes, roots, and surface identities remain unchanged
      And exactly one workspace-moved fact describes each settled catalog move

    @req-ws-fr-031 @req-ws-nfr-005 @accessibility @reorder
    Scenario: Assistive technology can reorder workspaces without a pointer drag
      Given VoiceOver is focused on a workspace that has a row below it
      When it activates Move workspace down
      Then the same typed workspace move places it one row lower
      And the row's spoken position and completion announcement report its new place

    @req-ws-fr-031 @persistence @reorder
    Scenario: Workspace order returns after relaunch
      Given the operator has reordered the workspace rows
      When the catalog is saved and restored
      Then the restored workspaces appear in the chosen order
      And the active workspace remains selected by stable identity

    @req-ws-fr-006 @remove-workspace
    Scenario: Removing an inactive workspace does not steal selection
      Given the catalog has at least two workspaces
      And an inactive workspace is selected for removal
      When the operator confirms removal
      Then its pane and tab closure facts are published
      And that workspace is removed
      And the active workspace remains active

    @req-ws-fr-006 @remove-workspace @selection
    Scenario: Removing the active workspace selects a surviving neighbor
      Given the active workspace has a surviving neighbor
      When the active workspace is removed
      Then the surviving neighbor becomes active
      And its active tab and pane become the selected context

    @req-ws-fr-006 @guard
    Scenario: The final workspace cannot be removed
      Given the catalog contains exactly one workspace
      When the operator requests its removal
      Then the workspace remains present
      And no removal fact is published

    @req-ws-fr-008 @active-pane
    Scenario: Each tab remembers its own active pane
      Given tab Alpha has pane A2 active
      And tab Beta has a different active pane
      When the operator selects tab Beta and returns to tab Alpha
      Then pane A2 is still Alpha's active pane
      And pane A2 receives the focus fact

    @req-ws-fr-009 @tabs
    Scenario: A new tab is appended and selected
      Given an active workspace contains one tab
      When the operator creates a new tab
      Then the new tab is appended with a new stable identity
      And it becomes the active tab
      And its initial pane becomes active

    @req-ws-fr-009 @tabs @keyboard
    Scenario: Cycling tabs wraps around their displayed order
      Given the first tab is active in a workspace with several tabs
      When the operator selects the previous tab
      Then the last tab becomes active
      When the operator selects the next tab
      Then the first tab becomes active again

    @req-ws-fr-009 @tabs @close
    Scenario: Closing an active middle tab selects its previous neighbor
      Given the middle tab is active in a workspace with three tabs
      When the operator closes the middle tab
      Then the previous tab becomes active
      And its remembered active pane receives focus

    @req-ws-fr-009 @tabs @guard
    Scenario: The final tab in a workspace cannot be closed
      Given a workspace contains exactly one tab
      When the operator requests that tab to close
      Then the tab and all of its panes remain unchanged
      And no tab-closed fact is published

  Rule: Recent workspace navigation offers closed folders without duplication

    @req-ws-fr-007 @recent-workspaces
    Scenario: Reopening a workspace moves it to the front without duplication
      Given a folder already exists in recent-workspace history
      When that folder is opened again with a newer display name
      Then one entry for its canonical path appears first
      And the entry uses the newer display name
      And the history survives a relaunch

    @req-ws-fr-007 @req-ws-nfr-002 @recent-workspaces @menu
    Scenario: The recent menu filters open folders before applying its display cap
      Given recent-workspace history contains more than five closed folders
      And several newer entries are already open in the catalog
      When the operator opens the sidebar Add Workspace menu
      Then no open canonical folder is offered
      And the five newest eligible closed folders are offered
      And tab or pane churn does not re-layout the open menu

    @req-ws-fr-007 @recent-workspaces @race
    Scenario: A recent folder opened during menu settlement is not duplicated
      Given a closed recent folder is offered in the menu
      And that folder becomes open before the click is delivered
      When the operator activates the stale menu row
      Then the existing workspace is selected
      And no duplicate workspace is created

  Rule: Catalog persistence restores valid orientation and fails soft

    @req-ws-fr-010 @req-ws-nfr-009 @round-trip
    Scenario: The supported catalog tree round-trips through one versioned document
      Given a valid catalog contains customized workspaces, ordered tabs, spatial panes, supported content, active selections, titles, and valid working directories
      When the catalog is captured and restored on the same filesystem
      Then all supported value state and stable identifiers are equal
      And sidebar visibility and width are absent from the catalog document

    @req-ws-fr-011 @req-ws-nfr-001 @req-ws-nfr-002 @durability
    Scenario: A burst of mutations writes only its final catalog snapshot
      Given the catalog persistence debounce window is open
      When several successful workspace mutations occur rapidly
      Then at most one atomic locked write is committed for that burst
      And the committed document contains the final snapshot

    @req-ws-fr-011 @req-ws-nfr-001 @quit
    Scenario: Orderly termination flushes pending workspace state
      Given the final catalog snapshot has not reached its debounce deadline
      When the application begins orderly termination
      Then the final live catalog is flushed before termination completes
      And a persistence error leaves the in-memory session available until shutdown

    @req-ws-fr-012 @req-ws-nfr-003 @fail-soft
    Scenario Outline: An unusable catalog document never crashes launch
      Given the saved catalog document is <condition>
      When Tenon attempts restoration
      Then restoration declines the unusable document without a trap
      And startup seeds or selects a valid fallback catalog

      Examples:
        | condition |
        | missing |
        | larger than 16 MiB |
        | syntactically corrupt |
        | ambiguous because it repeats an object key |
        | written with a newer top-level schema version |

    @req-ws-fr-012 @req-ws-nfr-003 @req-ws-nfr-008 @degrade
    Scenario Outline: A local restore defect loses only its smallest safe unit
      Given a supported catalog document contains <defect>
      When the document is restored
      Then the remaining valid catalog is available
      And the defect becomes <outcome>

      Examples:
        | defect | outcome |
        | a workspace whose root folder is gone | a dropped workspace with a surviving selection fallback |
        | a structurally invalid tab | a dropped tab with its workspace otherwise preserved |
        | a pane whose file is gone | an empty pane in the same layout position |
        | an unknown plugin view | an empty pane in the same layout position |
        | an unknown pane content kind | an empty pane in the same layout position |
        | an unknown workspace mark or accent | the default value for only that appearance field |

    @req-ws-fr-013 @launch-precedence
    Scenario: A bare launch restores the saved catalog as saved
      Given a valid catalog was saved
      And the new launch names no explicit directory
      When startup resolves the launch catalog
      Then the saved workspaces, ordering, and active selection are returned unchanged

    @req-ws-fr-013 @launch-precedence
    Scenario: An explicit open directory augments rather than replaces restored work
      Given a valid catalog was restored
      When startup explicitly names a directory not already open
      Then a new workspace for that directory is added beside the restored workspaces
      And the new workspace becomes active

    @req-ws-fr-013 @launch-precedence @dedupe
    Scenario: An explicit directory already open selects its canonical match
      Given a valid catalog was restored
      And one workspace is rooted at the explicit launch directory
      When startup resolves the launch catalog
      Then the matching workspace becomes active
      And no duplicate workspace is added

    @req-ws-fr-014 @lazy @terminal
    Scenario: Restored unseen panes remain lightweight until viewed
      Given a saved catalog contains terminal and plugin panes outside the visible tab
      When the catalog is restored
      Then no live terminal process or web surface is created for those panes
      And their valid title and working-directory placeholders may be shown
      When a restored terminal is first viewed
      Then it starts a fresh shell rather than claiming old PTY or scrollback continuity

    @req-ws-fr-027 @agent-lens @relaunch
    Scenario: A pane running an agent comes back reading that session
      Given a terminal pane whose foreground process is the agent that reported its session
      When the application quits and is launched again
      Then that pane comes back reading the recorded session rather than a blank shell
      And the reading offers to resume the session in place
      And the pane keeps the working directory its shell would spawn into

    @req-ws-fr-027 @agent-lens @relaunch
    Scenario: A pane whose agent has already exited comes back as the terminal it was
      Given a terminal pane whose agent has exited and handed the shell back
      When the application quits and is launched again
      Then that pane comes back as a terminal

    @req-ws-fr-027 @agent-lens @degrade
    Scenario: An agent pane whose transcript is gone still comes back as a terminal
      Given a saved pane names a session transcript that is no longer readable
      When the catalog is restored
      Then that pane comes back as a terminal rather than an empty pane

  Rule: Pane names remain presentation and AI work belongs to pane lifetime

    @req-ws-fr-028 @req-ws-fr-030 @rename @accessibility
    Scenario: Renaming a pane changes its label without changing its identity
      Given a pane has a stable identity, content, geometry, and automatic title
      When the operator chooses Rename from its header menu
      Then the pane's own title becomes the field the name is typed into
      And nothing is presented over the shell
      When the operator types a normalized name and presses Return
      Then the pane, active tab, and process monitor prefer that custom name
      And the pane identity, content, geometry, owner, and live surface are unchanged
      And the custom name survives a relaunch
      And VoiceOver offers the same Rename action through the same typed mutation

    @req-ws-fr-028 @rename @automatic
    Scenario: Clearing a pane name restores its automatic content title
      Given a pane has a custom name and a changing terminal title
      When the operator empties the title field and commits it
      Then the custom name is removed
      And the pane resumes showing the title derived from its content

    @req-ws-fr-028 @req-ws-fr-030 @rename @cancel
    Scenario: Escape abandons an inline rename and leaves the pane as it was
      Given the operator is typing a new name on a pane's title
      When the operator presses Escape
      Then the pane's title returns to the name it was showing
      And no rename mutation is recorded

    @req-ws-fr-029 @req-ws-nfr-011 @ai-rename
    Scenario: AI Rename accepts only one bounded Companion JSON title
      Given a pane contains work the operator wants summarized as a title
      When the operator chooses AI Rename
      Then Tenon snapshots the Companion profile and sends its selected agent one bounded untrusted pane brief
      And Claude uses JSON output with a JSON schema or Codex uses its JSONL agent-message event
      And only a response matching the title JSON schema may rename the pane
      And failure leaves the current pane name unchanged

    @req-ws-fr-030 @ai-rename @attention
    Scenario: A generating pane reports on its own title and stays usable
      Given the operator chooses AI Rename on a pane
      When the Companion task is running
      Then that pane's title reads "Naming…"
      And no surface is presented over the shell
      And the pane keeps its content, its focus, and its own name underneath
      And another pane may generate its own title at the same time

    @req-ws-fr-030 @ai-rename @failure
    Scenario: A failed generation says so on the pane and withdraws itself
      Given AI Rename is generating a title for a pane
      When the Companion task fails
      Then that pane's title reads "Rename failed" with the provider's message as its tooltip
      And after a bounded linger the pane returns to its automatic title with no operator gesture
      And the pane's custom name is unchanged throughout

    @req-ws-fr-029 @cancel @pane-lifecycle
    Scenario Outline: Losing the pane cancels its AI rename process
      Given AI Rename is generating a title for a pane
      When the pane is removed by <operation>
      Then Tenon cancels the generation task and terminates its Companion process
      And no late response can name another pane

      Examples:
        | operation |
        | Close Pane |
        | Close Tab |
        | Remove Workspace |
        | application shutdown |

    @req-ws-fr-029 @cancel @tab-switch
    Scenario: Switching tabs does not kill an AI rename owned by a live pane
      Given AI Rename is generating a title for a pane
      When the operator switches to another tab while that pane remains in the catalog
      Then the generation remains owned by the original pane
      And a validated result may rename only that pane

  Rule: Workspace presentation changes without changing identity

    @req-ws-fr-015 @identity
    Scenario: Naming a workspace normalizes presentation only
      Given a workspace has a stable identity, root, tabs, and panes
      When the operator enters a name with surrounding, repeated, and line-break whitespace
      Then the stored display name collapses the whitespace into one line
      And the name contains no more than 60 characters
      And the workspace identity, root, tabs, panes, and plugin scope are unchanged

    @req-ws-fr-015 @identity @duplicates
    Scenario: Duplicate display names remain independently addressable
      Given two workspaces have different stable identities
      When both are named Payments
      Then both rows may display Payments
      And selecting either row addresses its own stable workspace identity

    @req-ws-fr-032 @req-ws-nfr-005 @req-ws-nfr-006 @appearance
    Scenario: A workspace can use an expanded curated mark and semantic accent
      Given the workspace identity form is open
      When the operator chooses a supported mark and accent
      Then the workspace offers exactly 24 marks and 12 named semantic colours
      And the selected choices have a non-color visual indication
      And the workspace row announces the useful mark and workspace name

    @req-ws-fr-032 @req-ws-nfr-003 @appearance @upload
    Scenario: An uploaded icon survives its source file
      Given the workspace identity form is open
      When the operator chooses a decodable image within the source bounds
      Then image decoding and normalization run off MainActor
      And the workspace stores a PNG no larger than 64 by 64 pixels and 128 KiB
      And moving or deleting the source file does not remove the workspace icon
      And malformed saved image bytes fall back to the selected system mark

    @req-ws-fr-032 @appearance @reset
    Scenario: Reset restores default presentation without recreating work
      Given a workspace has a custom name, uploaded icon, and accent
      When the operator resets its identity
      Then the name is derived from its folder
      And the folder mark and the automatic colour are restored
      And its stable identity, root, tabs, panes, and selections are unchanged

    @req-ws-fr-023 @appearance
    Scenario: A workspace nobody has tinted already has a colour of its own
      Given two workspaces rooted at different folders and never customised
      When their rows are drawn
      Then each is drawn in a colour derived from its own canonical folder
      And that colour is the same colour after the app is relaunched
      And every spelling of one folder derives one colour
      And an explicitly chosen accent is used in place of the derived colour

    @req-ws-fr-023 @req-ws-nfr-005 @appearance
    Scenario: The derived palette can be seen and told apart
      Given the palette a derived colour is chosen from
      Then every colour in it reaches 3:1 against the sidebar chrome
      And no two of its colours are close enough to read as one colour

    @req-ws-fr-024 @req-ws-nfr-005 @appearance
    Scenario: Every row shows its colour, and the selected row is still obvious
      Given a sidebar holding several workspaces
      When one of them is the selected workspace
      Then every row draws its own workspace colour
      And the selected row is told apart by its fill, its text, and its spoken state

    @req-ws-fr-017 @req-ws-nfr-007 @events
    Scenario: A real identity edit publishes one fact through the existing boundary
      Given a workspace has its current presentation
      When the operator changes its name, mark, or accent to a different valid value
      Then every current host representation reads the updated shared presentation
      And exactly one workspace identity-changed fact is published for that mutation
      And the native form has used the typed host service directly

    @req-ws-fr-017 @req-ws-nfr-008 @no-op
    Scenario: A missing or unchanged identity edit publishes nothing
      Given a workspace identity edit names an unknown workspace or its current value
      When the edit is submitted
      Then the catalog remains unchanged
      And no identity-changed fact is published

    @req-ws-fr-033 @req-ws-nfr-004 @intent
    Scenario: An external caller customizes one exact workspace
      Given a CLI, plugin, or agent sends workspace.identity.set.v1 with workspace UUID scope
      When its finite name, accent, or icon patch is valid
      Then the provider calls the same typed identity mutation as the native form
      And it returns the final complete identity after exactly one identity-changed fact
      But missing or stale workspace scope never falls back to the selected workspace

    @req-ws-fr-021 @preferences
    Scenario: Sidebar layout has one persistence owner
      Given sidebar visibility and width were saved in app preferences
      And a catalog with different workspace content was saved separately
      When Tenon relaunches
      Then the sidebar uses its saved preference values
      And catalog restoration does not overwrite or duplicate those values

  Rule: Recently opened content never crosses workspace scope

    @req-ws-fr-018 @req-ws-nfr-004 @recent-content
    Scenario: An empty tab shows only its owning workspace history
      Given workspace Alpha and workspace Beta have different recent content
      And an empty tab belongs to workspace Alpha
      When its launcher shows Recently Opened
      Then only Alpha's ordered recent items are visible
      And no title, path, or view from Beta is exposed

    @req-ws-fr-018 @recent-content @off-selection
    Scenario: A mutation records recent content in the workspace it changed
      Given workspace Alpha is selected
      And a pane in workspace Beta is addressed directly
      When that Beta pane opens eligible content
      Then the content is recorded in Beta's recent bucket from the mutation fact
      And Alpha's recent bucket is unchanged

    @req-ws-fr-018 @recent-content @independence
    Scenario: The same content has independent recency in two workspaces
      Given the same eligible content was opened in two workspaces
      When one workspace opens it again and then clears its own history
      Then the other workspace's ordering and rows remain unchanged

    @req-ws-fr-019 @req-ws-nfr-008 @migration
    Scenario: A stale bucket is adopted only by its canonical workspace heir
      Given a restored recent bucket names a workspace identity no longer in the catalog
      And one unclaimed live workspace has the same canonical root
      When recent-content state is prepared at launch
      Then that live workspace may inherit the stale bucket
      And no workspace rooted elsewhere can read it

    @req-ws-fr-019 @req-ws-nfr-004 @migration
    Scenario: Legacy app-global recent rows are discarded
      Given old recent rows carry no workspace identity or canonical root owner
      When the scoped recent store loads them
      Then none is assigned to a workspace by guess
      And every workspace starts without those ambiguous rows

  Rule: Compact shell utilities and structural plugin facts remain safe

    @req-ws-fr-020 @req-ws-nfr-005 @req-ws-nfr-006 @req-ws-nfr-010 @footer
    Scenario: The sidebar footer stays compact without losing an action
      Given the sidebar is at its minimum supported width
      When the footer is rendered
      Then Help, Feedback, and Settings are each present once in one compact row
      And no primary sidebar version label is shown
      And every icon control has its tooltip, keyboard focus treatment, and spoken name
      And the row fits without clipping or overlap

    @req-ws-fr-020 @footer @destinations
    Scenario: Footer actions keep their established destinations
      Given the compact sidebar footer is visible
      When the operator activates Help, Feedback, and Settings
      Then Help opens the Tenon project help destination
      And Feedback opens the Tenon issue destination
      And Settings opens the application settings scene
      And version and build remain discoverable in Settings About

    @req-ws-fr-022 @req-ws-nfr-004 @req-ws-nfr-007 @workspace-status
    Scenario: A permission-free plugin can summarize workspace structure safely
      Given the bundled Workspace Status contribution is active without permissions
      When a workspace-changed fact reports tab and pane counts
      Then its status text may show those structural counts
      And the fact contains no terminal text, file contents, secrets, or pane body
