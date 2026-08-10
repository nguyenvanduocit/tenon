# language: en

@prd-TENON_PRD_004
Feature: Personalize Tenon and configure plugins from one native Settings window
  App preferences need compatible defaults while every plugin setting is rendered and
  persisted generically from its manifest.
  PRD: settings.prd.md

  Rule: App preferences are one pure compatible value

    @req-set-fr-001 @defaults
    Scenario: A fresh install receives explicit product defaults
      Given no valid app preferences blob exists
      When AppPreferencesStore initializes
      Then new tab, split, and workspace default to Terminal
      And new pane width is unrestricted
      And sidebar is visible at 232 points
      And accent is Amber and schedules are enabled

    @req-set-fr-002 @req-set-fr-003 @content
    Scenario Outline: Each creation context resolves its configured content
      Given <context> is configured to <choice>
      When the shell creates it
      Then its initial content is <content>

      Examples:
        | context | choice | content |
        | a new tab | Terminal | terminal |
        | a new split | Files | dev.tenon.file-explorer tree plugin view |
        | a new workspace | Browser | dev.tenon.browser browser plugin view |
        | a new tab | Changes | native Changes |
        | a new split | Empty | empty pane |

    @req-set-fr-004 @pane-width
    Scenario: New-pane width is a creation preference only
      Given existing panes have committed geometry
      When the user changes widest new pane
      Then existing panes keep their size
      And only later pane creation applies the selected fraction

    @req-set-fr-005 @sidebar
    Scenario: Launch initializes sidebar presentation from preferences
      Given the user saved sidebar visibility and default width
      When a new app session constructs the shell
      Then the sidebar starts with those values
      And its width remains inside the native resize bounds

    @req-set-fr-006 @accent
    Scenario: Accent changes host chrome but not terminal cells
      Given a terminal and Tenon chrome are visible
      When the user selects another accent preset
      Then active pane, tab, and focus chrome update immediately
      And Ghostty terminal colors do not change
      And the preset persists

    @req-set-fr-007 @automation-policy
    Scenario Outline: Automation policy revisions are owner-scoped
      Given schedules are configured
      When <change> occurs
      Then <revision> advances
      And unrelated policy identities remain stable

      Examples:
        | change | revision |
        | global scheduled delivery toggles | the global delivery revision |
        | one schedule pauses or resumes | only that schedule revision |

    @req-set-fr-008 @persistence
    Scenario Outline: App preference storage fails soft
      Given UserDefaults contains <blob>
      When AppPreferencesStore loads
      Then it uses <result>

      Examples:
        | blob | result |
        | valid JSON for AppPreferences | the decoded value |
        | missing or corrupt data | a complete default AppPreferences value |

    @req-set-fr-009 @compatibility
    Scenario: An older preference blob gains new defaults without losing old choices
      Given a valid older blob omits newer fields
      When it decodes
      Then present fields retain their values
      And missing fields use current defaults
      And an unknown pane width degrades only to no maximum

  Rule: Current Settings navigation follows semantic owners

    @req-set-fr-010 @navigation
    Scenario: Settings uses one flat source list
      Given Settings opens
      Then its sidebar contains General
      And each plugin declaring settings has one Plugins-section entry
      And Automation, CLI, and Extensions are visible
      And no hardcoded Browser route is required

    @req-set-fr-011 @general
    Scenario: General presents the complete app preference surface
      Given General is selected
      Then it shows new tab, split, workspace, and new-pane-width controls
      And sidebar startup and width controls
      And host accent presets
      And selectable Tenon version

    @req-set-fr-012 @browser
    Scenario: Browser configuration comes from the browser manifest
      Given the bundled Browser plugin declares settings
      When its Settings entry opens
      Then the generic plugin form renders those settings
      And no Browser-specific Swift settings form exists

    @req-set-fr-020 @removed-plugin
    Scenario: Removing the selected plugin fails soft
      Given a plugin settings page is selected
      When that plugin is disabled, removed, or disappears from the snapshot
      Then detail falls back to General
      And Settings remains usable

    @req-set-nfr-001 @design
    Scenario: Settings follows native grouped form language
      Given Settings renders in a supported appearance and contrast
      Then it uses the native source list and grouped Form
      And Tenon density, type, semantic colors, geometry, and scrollbars apply
      And no feature-local token is introduced

    @req-set-nfr-007 @accessibility
    Scenario: Every settings state is labeled and not color-only
      Given a control is loading, saving, disabled, installed, warning, or failed
      When accessibility inspects it
      Then a label and state convey the meaning
      And keyboard interaction reaches the same outcome

    @req-set-nfr-008 @nonblocking
    Scenario: Settings body performs no repeated filesystem or process work
      Given CLI or plugin status needs external I/O
      When Settings renders or refreshes
      Then work runs in a task away from blocking MainActor
      And SwiftUI body reads only captured observable state

  Rule: Plugin settings are manifest-driven installation-scoped values

    @req-set-fr-013 @groups
    Scenario: Manifest group order is preserved
      Given settings contain ungrouped and named groups in manifest order
      When the generic form buckets them
      Then first-seen group order is preserved
      And all ungrouped specs share one leading section

    @req-set-fr-014 @controls
    Scenario Outline: One generic control follows declared type
      Given a manifest declares <type>
      When its plugin settings page renders
      Then it uses <control>

      Examples:
        | type | control |
        | boolean | Toggle |
        | string | text field committed on submit |
        | number | number-formatted text field committed on submit |
        | select with options | Picker containing only declared choices |
        | select without options | fail-soft text field |

    @req-set-fr-015 @effective-value
    Scenario Outline: Effective plugin value has one precedence
      Given <state>
      When UI or runtime reads the setting
      Then it receives <value>

      Examples:
        | state | value |
        | an installation override exists | the override |
        | no override and manifest default exists | the manifest default |
        | neither exists | null |

    @req-set-fr-016 @validation
    Scenario Outline: Setting save validates declaration and shape
      Given a caller saves <candidate>
      When PluginHost validates it against the spec
      Then it is <outcome>

      Examples:
        | candidate | outcome |
        | matching string, boolean, number, or integer-for-number | accepted |
        | a select string in declared options | accepted |
        | undeclared key | refused |
        | wrong scalar type | refused |
        | select value outside options | refused |

    @req-set-fr-017 @changed-event
    Scenario Outline: Successful persistence updates the appropriate runtime state
      Given a valid override is durably written
      And the plugin is <runtime state>
      When save settles
      Then <result>

      Examples:
        | runtime state | result |
        | running | settings.changed carries key and value to that runtime |
        | stopped | override remains for its next activation without an event |

    @req-set-fr-018 @rollback
    Scenario: Failed save rolls optimistic UI back
      Given a control displayed a previous value
      When persistence fails for a new value
      Then the previous value returns
      And a visible error is shown
      And no uncommitted store state is published

    @req-set-fr-019 @extensions
    Scenario: Plugin lifecycle and permission state remain visible
      Given installed plugins include enabled, disabled, invalid, or unknown-permission states
      When Extensions opens
      Then each plugin shows version, enabled state, permissions, violations, and errors
      And one in-flight lifecycle operation disables duplicate toggles

    @req-set-nfr-002 @generic
    Scenario: A new manifest setting needs no plugin-specific native code
      Given a valid plugin adds a supported setting spec
      When the host reloads its manifest
      Then the generic Settings page presents it
      And no Swift view named for that plugin is added

    @req-set-nfr-003 @bounds
    Scenario Outline: Plugin setting documents enforce deterministic limits
      Given a mutation exceeds <limit>
      When the settings store validates the copy
      Then it fails explicitly before publication

      Examples:
        | limit |
        | 256-byte key |
        | 1024 entries per installation |
        | 16384 total entries |
        | 4096 installations |
        | 8 MiB default document bytes |

    @req-set-nfr-004 @atomic
    Scenario: Settings persistence is locked versioned and atomic
      Given two processes or tasks may touch the document
      When one mutation commits
      Then the locked versioned document is validated and atomically replaced
      And a failed write preserves prior disk and actor truth

    @req-set-nfr-005 @identity
    Scenario: Settings follow stable installation identity
      Given a plugin ID is reinstalled under another installation or trust class
      When settings are resolved
      Then the new installation does not inherit the old installation's overrides
      And uninstall removes only the retired installation values

    @req-set-nfr-006 @scoped-facility
    Scenario: tenon.settings remains plugin-private local state
      Given plugin code calls tenon.settings.get
      Then the value comes from that installation's runtime configuration
      And the facility is non-routable, non-discoverable, capability-free, and lifecycle-bound
      And plugin code does not self-send an intent to read its own setting
