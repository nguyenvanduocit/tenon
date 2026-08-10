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

    @req-ws-fr-016 @req-ws-nfr-005 @req-ws-nfr-006 @appearance
    Scenario: A workspace can use a curated mark and semantic accent
      Given the workspace identity form is open
      When the operator chooses a supported mark and accent
      Then the workspace uses the closed mark and semantic-color vocabulary
      And the selected choices have a non-color visual indication
      And the workspace row announces the useful mark and workspace name

    @req-ws-fr-016 @appearance @reset
    Scenario: Reset restores default presentation without recreating work
      Given a workspace has a custom name, mark, and accent
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
