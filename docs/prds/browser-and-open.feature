# language: en

@prd-TENON_PRD_006
Feature: Browse and open web addresses through one user-selected policy
  Operators need web content and agent links to open once in the handler they chose.
  PRD: browser-and-open.prd.md

  Rule: Browser is a plugin whose native web resources remain host-owned

    @req-bo-fr-001 @plugin
    Scenario: Browser is discovered as a bundled plugin
      Given the bundled Browser plugin is installed and enabled
      When the operator opens Browser from the launcher
      Then a plugin view fills the selected pane
      And the host has no separate native Browser content case or configuration store

    @req-bo-fr-002 @settings
    Scenario: Browser contributes its entry point and settings declaratively
      Given the Browser manifest is loaded
      When the host builds launchers and Settings
      Then Browser appears through its plugin-owned launcher contribution
      And Home URL and Search engine use the shared plugin settings renderer

    @req-bo-fr-003 @instance
    Scenario: Two Browser panes keep independent addresses and surfaces
      Given two Browser pane instances are open
      When one pane navigates to a new address
      Then only that pane's address changes
      And each pane uses its own instance ID as its surface ID

    @req-bo-fr-004 @req-bo-nfr-001 @chrome
    Scenario: Browser controls occupy the one native pane header
      Given a Browser pane is visible
      When its plugin value renders
      Then Back, Forward, Reload, and a flexible address field appear in the pane header
      And the web surface owns the body below that header

    @req-bo-fr-005 @address
    Scenario Outline: Browser resolves submitted text deterministically
      Given the configured search engine is DuckDuckGo
      When the operator submits <input>
      Then Browser resolves <result>

      Examples:
        | input | result |
        | an empty string | no navigation |
        | https://example.com/a | the same explicit address |
        | example.com/a | https://example.com/a |
        | two words | an encoded DuckDuckGo search for two words |

    @req-bo-fr-006 @req-bo-nfr-007 @one-shot
    Scenario Outline: A requested address belongs only to the next Browser pane
      Given Browser is asked to open a specific address
      When workspace content opening <outcome>
      Then the parked address is cleared
      And a later unrelated Browser pane opens its configured home address

      Examples:
        | outcome |
        | succeeds and creates the pane |
        | is refused before creating a pane |

    @req-bo-fr-007 @req-bo-nfr-002 @scope
    Scenario: A plugin can operate only its own web surface
      Given two plugin installations name the same surface ID
      When one plugin sends a browser surface operation
      Then the host resolves the key from that caller's installation and surface ID
      And no WKWebView or native object crosses the plugin boundary

    @req-bo-fr-008 @security
    Scenario Outline: Top-level URL policy is closed
      Given a plugin requests <address>
      When the host validates the load
      Then the load is <result>

      Examples:
        | address | result |
        | https://example.com/a | accepted |
        | http://example.com | accepted |
        | javascript:alert(1) | refused |
        | file:///tmp/a.html | refused |
        | https://user:pass@example.com | refused |
        | https:///missing-host | refused |

    @req-bo-fr-009 @events
    Scenario: Completed web facts update plugin presentation
      Given a Browser surface begins and completes navigation
      When its title, URL, or loading state changes
      Then the host emits the matching fact to the owning installation
      And Browser reflects the latest navigated URL in its address field

    @req-bo-fr-010 @popup
    Scenario Outline: Popup adoption protects the top-level document
      Given <source> requests <target> in a new window
      When the web surface handles the popup
      Then <outcome>

      Examples:
        | source | target | outcome |
        | the main frame | an allowed HTTPS URL | the target loads in the same pane |
        | the main frame | a refused scheme | the popup is declined |
        | a third-party subframe | an allowed HTTPS URL | the popup is declined |

    @req-bo-fr-011 @req-bo-nfr-005 @user-agent
    Scenario: WebKit composes the Browser user agent
      Given the current supported macOS version
      When a Browser web view is created
      Then its application name contains a deterministic Version token and Safari/605.1.15
      And WebKit's platform and engine tokens are not replaced

    @req-bo-fr-012 @req-bo-nfr-003 @req-bo-nfr-004 @lifecycle
    Scenario Outline: Surface and website-data lifetime follows installation state
      Given a Browser surface belongs to an installed plugin
      When the plugin is <transition>
      Then <surface outcome>
      And <data outcome>

      Examples:
        | transition | surface outcome | data outcome |
        | closed in one pane | that surface is disposed | the installation data is retained |
        | disabled | every inactive surface is disposed | the installation data is retained |
        | uninstalled | every installation surface is disposed | its persistent website data is removed |

  Rule: Agent prose recognizes links without turning arbitrary code into addresses

    @req-bo-fr-013 @links
    Scenario Outline: Valid remote addresses remain live in prose
      Given Agent Lens renders <form>
      When inline attributes are projected
      Then the exact HTTP or HTTPS address is a link

      Examples:
        | form |
        | a written Markdown link |
        | a bare address |
        | an absolute address inside backticks |

    @req-bo-fr-014 @links @security
    Scenario Outline: Non-web code is not inferred as a web link
      Given Agent Lens renders <span> in backticks
      When inline attributes are projected
      Then <outcome>

      Examples:
        | span | outcome |
        | Sources/App.swift that resolves | the file URL wins |
        | ftp://files.example.com | the span stays plain |
        | tenon.dev | the span stays plain |
        | https:// | the span stays plain |
        | swift test --filter Foo | the span stays plain |

  Rule: Open contracts resolve safely for public callers

    @req-bo-fr-015 @req-bo-nfr-008 @contract
    Scenario: URL open keeps the closed programmatic contract
      Given the core intent catalog is compiled
      When url.open.v1 is inspected
      Then it accepts one bounded URL object
      And its audiences are exactly plugin, CLI, and agent
      And no app or UI principal exists

    @req-bo-fr-016 @trusted-default
    Scenario Outline: The trusted provider opens only an authorized web address
      Given a caller requests <address> under <grant>
      When the trusted system provider handles it
      Then <outcome>

      Examples:
        | address | grant | outcome |
        | https://example.com | matching network authority | NSWorkspace receives the URL |
        | https://example.com | no matching network authority | the request is refused |
        | file:///tmp/a | matching shell capability | the request is refused as an invalid URL |

    @req-bo-fr-017 @resolution
    Scenario Outline: One ranking rule chooses the provider decision
      Given the eligible providers include the requested candidates
      When resolution has <state>
      Then it reports <decision>

      Examples:
        | state | decision |
        | an eligible explicit target | that explicit target |
        | an eligible configured default | the configured default |
        | an eligible trusted default only | the trusted default |
        | one eligible provider and automatic selection allowed | the sole provider |
        | several eligible providers without a default | sorted needs-choice candidates |
        | no eligible provider | no provider |

    @req-bo-fr-018 @resolution @lifecycle
    Scenario: Asking what would happen takes no provider lease
      Given a provider generation can serve an open request
      When a caller asks for its resolution decision
      Then the registry state and selection count are unchanged
      And retiring the provider is not delayed by the query

    @req-bo-fr-019 @fallback
    Scenario Outline: Ineligible handlers cannot swallow an open
      Given the configured plugin handler is <condition>
      When the same address is resolved again
      Then that provider is excluded
      And the eligible trusted default can serve the request

      Examples:
        | condition |
        | draining |
        | disabled |
        | unexported |
        | quarantined after invalid output |

    @req-bo-fr-020 @approval
    Scenario: Bundling a handler is not permission to see opened addresses
      Given Browser ships with Tenon but has no URL-open approval
      When plugin activation evaluates its open contracts
      Then Browser has no active URL-open binding
      And its unrelated plugin capabilities can still load

    @req-bo-fr-020 @req-bo-nfr-003 @approval
    Scenario: Approval persists only the exact pair
      Given the person approves one plugin for url.open.v1
      When approval state is reloaded
      Then that plugin and contract pair is approved
      And no other plugin or contract inherits the grant

    @req-bo-fr-021 @candidacy
    Scenario Outline: A declaration binds only under exact approval
      Given a plugin declares an open contract
      When its approval is <state>
      Then the declaration is <outcome>

      Examples:
        | state | outcome |
        | absent | an inert awaiting-approval offer |
        | present for that exact declaration | an active candidate binding |
        | present for an undeclared contract | ignored without widened authority |

    @req-bo-fr-022 @agent @consent
    Scenario: An agent cannot gain standing consent for an alternative handler
      Given an agent selects an approved non-trusted URL handler
      When it opens the same kind of URL on two calls
      Then each call requires its own confirmation
      And the first answer does not become an always grant

  Rule: Every product entry point will honor the person's choice

    @req-bo-fr-023 @req-bo-nfr-008 @pending
    Scenario: Built-in UI enters through one typed opener without self-sending
      Given a host-native view needs to open an address
      When it invokes the opening use case
      Then it calls the typed application service directly
      And public adapters call that same service
      And no synthetic app intent principal is created

    @req-bo-fr-024 @req-bo-nfr-007 @pending
    Scenario: One Agent Lens link gesture settles exactly once
      Given Agent Lens displays a valid HTTP link
      When the operator activates it
      Then the typed opener resolves and invokes exactly one handler
      And SwiftUI systemAction is not also returned

    @req-bo-fr-025 @pending
    Scenario: Browser becomes an inert URL-open offer before approval
      Given Browser declares that it provides url.open.v1
      And the person has not approved the pair
      When the plugin loads
      Then Browser remains usable as a pane
      And the URL-open binding is withheld

    @req-bo-fr-025 @pending
    Scenario: Approved Browser opens the requested address internally
      Given Browser is approved and selected for url.open.v1
      When an address is opened
      Then one Browser pane is created or targeted through workspace content placement
      And its first load uses the requested address

    @req-bo-fr-026 @req-bo-nfr-001 @req-bo-nfr-006 @pending
    Scenario: Settings grants and revokes a truthful handler offer
      Given a plugin declares a known open contract
      When the person reviews its handler row in Settings
      Then the row names the plugin and contract in native accessible controls
      And approving or revoking restages the binding immediately

    @req-bo-fr-026 @req-bo-nfr-003 @pending
    Scenario: Uninstall removes authority rather than leaving it for a reused ID
      Given an installed plugin has an open-handler approval
      When that installation is uninstalled
      Then every approval for its plugin ID is removed
      And a later installation claiming the ID starts unapproved

    @req-bo-fr-027 @req-bo-nfr-006 @pending
    Scenario Outline: The chooser applies one explicit answer
      Given several eligible handlers have no configured default
      When the operator chooses a handler with <answer>
      Then <result>

      Examples:
        | answer | result |
        | Just once | only the current request targets it |
        | Always | the current request targets it and it becomes the configured default |
        | Cancel | nothing opens and prior defaults remain unchanged |

    @req-bo-fr-027 @pending
    Scenario: A remembered handler outranks the trusted default while eligible
      Given the person previously chose an approved Browser handler with Always
      When any supported entry point opens another URL
      Then Browser is selected without another chooser
      And the built-in system provider is not also invoked

    @req-bo-fr-028 @req-bo-nfr-009 @pending
    Scenario Outline: Handler failure is visible and settles once
      Given the selected handler <failure>
      When the open attempt settles
      Then the initiating surface shows a bounded failure
      And no fallback handler is silently invoked by the same gesture

      Examples:
        | failure |
        | refuses the input |
        | returns invalid output |
        | throws an error |
        | exceeds the 15-second timeout |

    @req-bo-fr-029 @pending
    Scenario: Another openable kind reuses the same choice machinery
      Given a second typed open contract has a trusted and approved plugin provider
      When a person chooses, defaults, revokes, or encounters an unhealthy handler
      Then the same resolver and approval workflow governs it
      And no browser-specific chooser branch exists

  Rule: Compatibility and observability do not leak browsing data

    @req-bo-nfr-009 @privacy
    Scenario: Routine diagnostics do not record full browsing addresses
      Given a web-data removal or open operation fails
      When diagnostics retain the failure
      Then they retain a bounded reason and affected installation or request identity
      And they do not routinely persist the full opened URL

    @req-bo-nfr-010 @manual
    Scenario Outline: Installed-app browser verification covers real compatibility
      Given Tenon runs as an installed app on a supported macOS version
      When the reviewer checks <flow>
      Then behavior matches the accepted browser/open contract

      Examples:
        | flow |
        | Google and another UA-sensitive site |
        | history, reload, and main-frame target-blank navigation |
        | third-party iframe popup refusal |
        | keyboard and VoiceOver chooser operation |
