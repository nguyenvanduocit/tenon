# language: en

@prd-TENON_PRD_005
Feature: Publish bounded native plugin panes with independent workspace-owned instances
  Plugin authors need composable UI without native object access or bespoke host screens.
  PRD: plugin-ui.prd.md

  Rule: A plugin publishes pure native-rendered values

    @req-pui-fr-001 @req-pui-nfr-010 @contribution
    Scenario: View publication changes plugin-owned presentation only
      Given a loaded plugin registers and sets a view
      When the host accepts the contribution
      Then it validates, snapshots, diffs, and renders pure values
      And no filesystem, workspace, terminal, browser, or OS effect occurs from publication alone

    @req-pui-fr-002 @primitives
    Scenario Outline: Layout primitives compose without bespoke host screens
      Given a body tree contains <node>
      When the host renders it
      Then native SwiftUI represents the documented layout semantics

      Examples:
        | node |
        | vstack or hstack |
        | bounded box |
        | horizontal, vertical, or both-axis scroll |
        | bounded-column grid |
        | styled text or SF-symbol image |
        | spacer or divider |

    @req-pui-fr-003 @components
    Scenario Outline: Opinionated components retain native defaults
      Given a body tree contains <component>
      When the host renders it
      Then it uses the shared Tenon component presentation

      Examples:
        | component |
        | card or badge |
        | button or textfield |
        | stat or keyValue |
        | progress clamped from zero through one |
        | field containing composed children |

    @req-pui-fr-004 @req-pui-nfr-003 @web-surface
    Scenario: A web node is only a reference to a host resource
      Given a plugin publishes a webview surface ID
      When the pane renders and navigates it
      Then the plugin receives no WKWebView or native object
      And finite navigation uses the declared browser surface intents scoped to that installation

    @req-pui-fr-005 @req-pui-nfr-001 @tokens
    Scenario Outline: Unknown style tokens degrade to a semantic default
      Given a node supplies an unknown <token>
      When it decodes
      Then the node remains visible with <fallback>

      Examples:
        | token | fallback |
        | text style | body |
        | font weight | regular |
        | color or tint | default semantic color |
        | button style | plain |
        | scroll axis | vertical |

    @req-pui-fr-006 @req-pui-nfr-004 @fail-soft
    Scenario Outline: One malformed node cannot blank the pane
      Given a tree contains <defect> beside valid siblings
      When the host decodes it under central bounds
      Then only the invalid node is skipped
      And a plugin diagnostic names the correction
      And valid siblings still render

      Examples:
        | defect |
        | an unknown type |
        | text without a value |
        | a container without children |
        | an over-bound identity that cannot be truncated safely |

    @req-pui-fr-007 @identity
    Scenario Outline: Stateful nodes keep authored identity across republish
      Given a plugin inserts or reorders siblings around <stateful node>
      When it republishes the whole body
      Then <state> remains attached to the authored identity
      And duplicate authored identities remain distinct rather than collapsing

      Examples:
        | stateful node | state |
        | a textfield action | its current native draft |
        | a webview surface ID | its live web resource |

  Rule: Body, rows, modal, and header remain one coherent contribution

    @req-pui-fr-008 @req-pui-nfr-008 @compatibility
    Scenario Outline: Body and legacy rows remain first-class
      Given a published view contains <shape>
      When it projects
      Then <result>

      Examples:
        | shape | result |
        | only items | shared native rows render |
        | only body | the recursive tree renders |
        | both body and items | body wins deterministically |

    @req-pui-fr-009 @rows
    Scenario: Dense rows share one host-native vocabulary
      Given rows declare IDs, labels, detail, accessory, section kind, hierarchy, icons, selection, paths, menus, and editing
      When a plugin pane renders them
      Then the same native row renderer used by host content preserves scanning, disclosure, drag, menu, and edit behavior
      And malformed decoration costs only that decoration, not the row

    @req-pui-fr-010 @row-action
    Scenario Outline: Row interactions settle through the correct callback
      Given a row is interactive
      When the person <interaction>
      Then <route>

      Examples:
        | interaction | route |
        | clicks the row | its action or ID reaches onSelect |
        | chooses a context-menu value | action and menu value reach onSelect |
        | commits inline text | action and text reach onSubmit exactly once |

    @req-pui-fr-011 @modal
    Scenario Outline: One modal remains owned by the published value
      Given a view <publication>
      When the shell projects it
      Then <outcome>

      Examples:
        | publication | outcome |
        | adds a modal | one native shell sheet presents its title and body |
        | omits the prior modal | the sheet closes |
        | receives Escape, backdrop click, or close | one dismiss action reaches onSelect |
        | competes with another published modal | the first in publication order wins |

    @req-pui-fr-012 @header
    Scenario: Header accepts only the flat chrome vocabulary
      Given a view publishes header leading and trailing items
      When they decode
      Then only dot, label, badge, image, spinner, iconButton, toggle, segmented, menu, and textfield kinds are representable
      And recursive body containers cannot enter the 34-point strip

    @req-pui-fr-013 @req-pui-nfr-004 @header-bounds
    Scenario Outline: Header admission protects identity and geometry
      Given a header contains <defect>
      When common admission runs for built-in or plugin values
      Then <outcome>

      Examples:
        | defect | outcome |
        | empty, overlong, duplicate, or host-reserved ID | the later or invalid item is refused with a reason |
        | overlong display text | readable text truncates under its display bound |
        | unusable segmented or empty menu | that item is refused |
        | several flexible fields | only the first absorbs slack |
        | more items than a slot budget | excess items are refused before layout |

    @req-pui-fr-014 @req-pui-nfr-003 @header-routing
    Scenario Outline: Published item kind determines the action channel
      Given a header item is <kind>
      When the person operates it
      Then <route>
      And a plugin-supplied accessibilityID is ignored

      Examples:
        | kind | route |
        | iconButton, toggle, segmented, or menu | selection reaches onSelect |
        | textfield | committed text reaches onSubmit |
        | dot, label, badge, image, or spinner | no action is synthesized |

    @req-pui-fr-015 @req-pui-nfr-002 @header-layout
    Scenario Outline: Header controls cannot make the pane immovable
      Given header width is <width>
      When native layout solves controls and title
      Then the close control and north resize edge remain clear
      And a contiguous pane-drag band remains usable
      And <overflow behavior>

      Examples:
        | width | overflow behavior |
        | wide | controls retain natural placement and title remains readable |
        | narrow | eligible items fold into the one host-owned overflow control |

    @req-pui-fr-016 @superseded
    Scenario: Browser toolbar uses the universal pane header
      Given the Browser plugin publishes navigation buttons and a flexible address field
      When its pane renders
      Then those controls occupy the shared pane header
      And no body browserBar or second toolbar path exists

  Rule: Pane UUID and catalog state own every instanced view

    @req-pui-fr-017 @instance
    Scenario: Two panes of one registered type receive distinct instance identity
      Given a plugin registers its view as instanced
      When two workspace panes reference that type
      Then each pane UUID becomes its instance ID
      And type identity remains the same plugin ID and view ID

    @req-pui-fr-018 @instance-callbacks
    Scenario: Instance callbacks and contribution remain isolated
      Given two instances publish different bodies and drafts
      When one receives open, select, submit, and close facts
      Then every callback carries only that instance ID
      And the other instance state remains unchanged

    @req-pui-fr-019 @singleton
    Scenario: A singleton view keeps its historical contract
      Given a view omits instanced or sets it false
      When several panes reference it
      Then one section without an instance ID is projected
      And select/submit callbacks receive no instance argument

    @req-pui-fr-020 @catalog
    Scenario: Hidden panes remain desired instances
      Given instanced plugin panes exist across several workspaces and tabs
      When the selected tab changes
      Then catalog enumeration still includes every pane UUID
      And visibility does not close any instance

    @req-pui-fr-021 @req-pui-nfr-006 @reconcile
    Scenario: Reconciliation is idempotent and reentrancy-safe
      Given desired instances differ from the active set
      When the host reconciles and an onOpen immediately publishes state
      Then active is set to desired before callbacks
      And removed instances close and release once
      And new instances open once
      And the nested publication cannot double-open them

    @req-pui-fr-022 @req-pui-nfr-005 @reload
    Scenario Outline: Generation changes preserve the last valid UI owner
      Given a replacement generation <outcome>
      When the plugin reloads
      Then <result>

      Examples:
        | outcome | result |
        | activates successfully | desired instances receive open facts on the replacement generation |
        | fails staging or activation | the last good generation and resources remain active |
        | emits a stale callback after replacement | the stale mutation is refused |

    @req-pui-fr-023 @resource
    Scenario Outline: Native resource lifetime follows the instance, not visibility
      Given a pane owns an exact installation, view, instance resource key
      When the pane is <transition>
      Then <outcome>

      Examples:
        | transition | outcome |
        | moved or hidden by tab switching | the same resource remains |
        | closed | only that instance resource is disposed once |
        | retained while another instance closes | its resource remains live |

    @req-pui-fr-024 @req-pui-fr-025 @workspace-scope
    Scenario: An inactive workspace's view cannot follow global selection
      Given equivalent instanced views exist in workspaces A and B
      And each resolved its pane owner through workspace.pane.owner.v1
      When the person selects workspace B and changes its focused pane
      Then workspace A's root, body, expansion, and selection remain unchanged
      And returning to A restores its prior state

    @req-pui-fr-026 @projection
    Scenario: Shell projection never substitutes a similarly named view
      Given several plugins and instances publish similar titles
      When a pane resolves its section
      Then exact plugin ID, view ID, and pane instance ID select it
      And no display-name or other-plugin fallback occurs

    @req-pui-fr-035 @architecture
    Scenario: Instance lifecycle remains reconciliation rather than a public request
      Given the catalog adds or removes an instanced plugin pane
      When the host reconciles it
      Then open or close arrives as an owner callback fact
      And no lifecycle intent is resolved or answered

  Rule: Drag and drop is same-instance pointer sugar with input parity

    @req-pui-fr-027 @drag-drop
    Scenario: Transparent wrappers reuse the selection event shape
      Given a dragSource subtree is dropped onto a dropTarget subtree
      When the drag is admitted
      Then children retain their ordinary layout
      And target action plus source payload reach onSelect exactly once

    @req-pui-fr-028 @req-pui-nfr-003 @drag-scope
    Scenario Outline: Cross-scope drag data fires nothing
      Given a drag enters <target>
      When the envelope is decoded
      Then no plugin action fires

      Examples:
        | target |
        | another instance of the same view |
        | another view in the same plugin |
        | another plugin's pane |
        | a malformed, unversioned, or externally synthesized envelope |

    @req-pui-fr-029 @req-pui-nfr-004 @drag-bounds
    Scenario Outline: Invalid drag declarations preserve ordinary rendering
      Given <declaration>
      When the subtree renders
      Then its children remain visible
      And no drag or drop behavior is installed

      Examples:
        | declaration |
        | an empty drag payload |
        | a payload longer than 256 characters |
        | a drop target with no action |

    @req-pui-fr-030 @req-pui-nfr-002 @input-parity
    Scenario: Pointer dragging is never the only route
      Given a move operation is exposed by draggable content
      When the user operates by keyboard or VoiceOver
      Then a button, menu, or equivalent native route performs the same domain operation

  Rule: Real-host snapshots make geometry part of acceptance evidence

    @req-pui-fr-031 @req-pui-nfr-009 @snapshot
    Scenario: Headless snapshot renders the product path rather than a mock
      Given a valid plugin/view snapshot request
      When Tenon boots in snapshot mode
      Then it uses the real inventory, manifests, JavaScript, intent runtime, exact instance, PluginSlotView, and pane chrome
      And only plugin state uses a throwaway root
      And a PNG is written before any window opens

    @req-pui-fr-032 @snapshot
    Scenario Outline: Snapshot configuration and failure are actionable
      Given <request>
      When snapshot mode runs
      Then <outcome>

      Examples:
        | request | outcome |
        | a target plus custom workspace and WxH size | that real view renders at the requested context and size |
        | malformed plugin/view:path syntax | usage fails before host boot |
        | a plugin that contributes no matching section | failure lists the views that did load |
        | a plugin whose intents fail | its real error presentation is captured |

    @req-pui-fr-033 @gallery
    Scenario: View Gallery remains a current singleton vocabulary example
      Given the bundled View Gallery loads
      When its view is opened from more than one pane
      Then current primitives, components, actions, and tokens are demonstrated
      And one workspace-independent singleton body is shared intentionally

    @req-pui-fr-034 @authority
    Scenario: A UI action earns no capability from its presentation
      Given a plugin button requests a filesystem or workspace effect
      When the callback handles the selection
      Then it must send the declared canonical intent
      And normal policy may allow, confirm, or deny it

  Rule: Cross-cutting rendering constraints remain measurable

    @req-pui-nfr-001 @design-system
    Scenario: Plugin values cannot introduce a local visual language
      Given a plugin publishes all supported nodes and header items
      When native rendering resolves them
      Then typography, color, spacing, geometry, and light/dark behavior come from Tenon's design system
      And no raw font, hex color, CSS, or arbitrary native view is accepted

    @req-pui-nfr-006 @determinism
    Scenario: Pure contribution rules replay identically
      Given the same bounded JSON, catalog snapshot, generation, and drag scope
      When decode, identity, reconcile, and drag admission repeat
      Then the same nodes, instances, refusals, and action values result

    @req-pui-nfr-007 @performance
    Scenario: Republish does not discard live state or eagerly build all content
      Given a large lazy row/grid view contains offscreen content and stateful nodes
      When a nearby value changes and the tree republishes
      Then stable identities retain fields and native resources
      And only visible lazy content is materialized as required

    @req-pui-nfr-008 @compatibility
    Scenario: Additive schema mistakes fail soft without reviving removed paths
      Given an older rows/singleton plugin and a newer plugin with unknown additive tokens load
      When both publish
      Then the older contract remains functional
      And unknown additions fall back or lose only the malformed decoration
      And browserBar remains superseded by header chrome
