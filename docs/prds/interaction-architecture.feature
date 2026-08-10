# language: en

@prd-TENON_PRD_011
Feature: Classify every Tenon interaction once and route every public call through one kernel
  Engineers need deterministic boundaries so one feature cannot gain duplicate routes or lose policy and lifecycle behavior.
  PRD: interaction-architecture.prd.md

  Rule: Ownership and semantics select the first matching mechanism

    @req-iar-fr-001 @semantic-owner
    Scenario Outline: Code placement alone does not change semantic ownership
      Given two components differ only by <placement>
      When their shipping, trust, installation, reload, discovery, provider, and compatibility facts remain the same
      Then <placement> does not create an independent semantic owner

      Examples:
        | placement |
        | Swift target or source directory |
        | actor or thread |
        | process location |
        | synchronous or asynchronous implementation |

    @req-iar-fr-002 @req-iar-nfr-005 @principal
    Scenario: Principal identity is host minted and carries no generic app authority
      Given host Swift and public callers invoke product behavior
      When policy identifies the caller
      Then plugin, CLI, agent, and accepted-user gesture identities are explicit where applicable
      And built-in same-owner code mints no generic app or core authority principal

    @req-iar-fr-003 @adapter
    Scenario Outline: Public reachability distinguishes adapters from local controls
      Given an interaction enters through <surface>
      When its boundary is classified
      Then <classification fact>

      Examples:
        | surface | classification fact |
        | plugin runtime | it crosses a public adapter boundary |
        | CLI socket | it crosses a public adapter boundary |
        | agent or MCP projection | it crosses a public adapter boundary |
        | palette or registered product keybinding | it crosses a public projection boundary |
        | focused editor Escape or save control | it remains same-owner local control |

    @req-iar-fr-004 @classification-unit
    Scenario: Mechanism lifecycle is not a new product mechanism
      Given a view contribution registers, an event subscribes, a request cancels, or a resource reads
      When the exact interaction is classified
      Then the domain interaction keeps its CONTRIBUTION, EVENT, INTENT, or RESOURCE class
      And registration, subscription, cancellation, or read remains reserved lifecycle for that class

    @req-iar-fr-005 @req-iar-nfr-001 @ordered-law
    Scenario Outline: Ordered classification stops at the first semantic match
      Given an exact interaction is <shape>
      When the decision law runs in order
      Then it selects <mechanism>
      And no later rung can override it by local preference

      Examples:
        | shape | mechanism |
        | an exact reserved mechanism lifecycle operation | CONTROL PLANE |
        | independently owned declarative state | CONTRIBUTION |
        | a fact that already happened | EVENT |
        | multi-result, large pull, or caller-owned lifetime | RESOURCE/STREAM/TASK |
        | same owner outside a public adapter | DIRECT |
        | one of the three exact private facilities | SCOPED FACILITY |
        | finite unicast across an owner or adapter boundary | INTENT |

    @req-iar-fr-006 @contribution
    Scenario: Declarative publication owns state but no host effect
      Given an independent plugin publishes a view, setting schema, status, or intent presentation
      When the host validates, reconciles, indexes, or renders its snapshot
      Then the interaction is CONTRIBUTION
      And decoding or publication performs no imperative host mutation

    @req-iar-fr-007 @event
    Scenario: An already-happened fact does not wait for observers
      Given a workspace, terminal, browser, settings, or plugin-owned fact occurred
      When the publisher accepts it for bounded delivery
      Then the interaction is EVENT
      And zero or more observers run outside the publisher transaction
      And no observer result returns to the publisher

    @req-iar-fr-008 @resource
    Scenario Outline: Lifetime or cardinality makes a resource
      Given a caller receives <shape>
      When the initial creation reply completes
      Then the producer remains an explicitly owned bounded RESOURCE/STREAM/TASK
      And read, progress, cancel, overflow, and teardown are defined

      Examples:
        | shape |
        | several correlated stdout and stderr values |
        | a filesystem watch lifetime |
        | a large pull body with cursor or handle |
        | a terminal or web surface retained after creation |

    @req-iar-fr-009 @direct
    Scenario: Same-owner host behavior stays typed
      Given SwiftUI and a typed application service ship and roll back as one owner
      And no public adapter or independent lifetime is crossed
      When the UI performs the behavior
      Then it uses a typed DIRECT call
      And no IntentValue, string name, discovery, or provider selection is introduced

    @req-iar-fr-010 @scoped-facility
    Scenario Outline: The private-facility exception remains closed
      Given a plugin uses <surface>
      When the boundary inventory is checked
      Then <result>

      Examples:
        | surface | result |
        | settings.get | it reads only this plugin's declared settings snapshot |
        | storage.get or storage.set | it accesses only this plugin's non-secret state |
        | log | it emits this runtime's diagnostics |
        | a proposed fourth facility | it is refused until the normative inventory and fitness test change |

    @req-iar-fr-011 @intent
    Scenario: Finite public work is one intent
      Given a plugin, CLI, agent, palette, or registered keybinding requests one finite unicast operation
      And no earlier decision rung applies
      When the request crosses the boundary
      Then one versioned canonical INTENT settles one terminal result

    @req-iar-fr-012 @blocked-design
    Scenario Outline: An under-specified interaction cannot enter implementation
      Given the proposal cannot state <missing fact>
      When classification review occurs
      Then the proposal is blocked until the fact is explicit and the first-match result is repeatable

      Examples:
        | missing fact |
        | semantic owner or caller principal |
        | result cardinality |
        | resource lifetime and cancellation |
        | authority and failure semantics |
        | backpressure or overflow behavior |

  Rule: One behavior may have adapters but only one implementation

    @req-iar-fr-013 @single-implementation
    Scenario: Native UI and public adapters converge on one domain service
      Given one operation is available to built-in SwiftUI and authorized public principals
      When each route performs it
      Then SwiftUI calls the typed application service directly
      And the intent provider validates and adapts into that same service
      And domain semantics exist in neither adapter twice

    @req-iar-fr-014 @plugin-local
    Scenario: A plugin does not self-send for private implementation structure
      Given one plugin intent handler needs a local helper
      When the handler performs its own domain algorithm
      Then it calls ordinary local JavaScript
      And it self-sends only when it intentionally crosses a declared public contract

    @req-iar-fr-015 @direct-gate
    Scenario Outline: DIRECT inventory growth is a reviewed exception
      Given a DIRECT inventory entry is <change>
      When architecture fitness runs
      Then <requirement>

      Examples:
        | change | requirement |
        | unchanged or smaller | the grandfathered length ceiling remains satisfied |
        | enlarged | one labelled justification and updated pinned length are required |
        | newly added | one labelled justification plus updated count and length map are required |
        | removed after reclassification | the inventory may shrink without preserving dead text |

  Rule: The intent kernel owns contract, authority, resolution, and settlement

    @req-iar-fr-016 @contract
    Scenario Outline: Contract identity is compiled before a call
      Given a contract changes <facet>
      When catalog installation validates it
      Then <outcome>

      Examples:
        | facet | outcome |
        | owner, canonical name, schema, errors, effects, audience, authority, or timeout | the complete descriptor is compiled or refused atomically |
        | a breaking same-major field | compatibility validation refuses the mutation |
        | an additive compatible field | the declared default and schema remain callable |

    @req-iar-fr-017 @envelope
    Scenario: Caller payload cannot forge authoritative metadata
      Given untrusted input contains caller, request, scope, deadline, target, or idempotency-looking fields
      When the adapter constructs an IntentEnvelope
      Then host-minted metadata remains authoritative and immutable
      And input is one owned bounded IntentValue without live JavaScript or native objects

    @req-iar-fr-018 @pipeline
    Scenario: Every public adapter enters the same ordered dispatch pipeline
      Given equivalent plugin, CLI, agent, or plugin-owned palette requests arrive
      When dispatch begins
      Then each passes bounds, schema, policy, provider, consent, idempotency, lease, admission, asynchronous execution, output validation, settlement, and audit in order
      And no adapter jumps directly to a provider

    @req-iar-fr-019 @authority
    Scenario Outline: Designation never bypasses authority
      Given a caller designates <target>
      When policy resolves the request
      Then audience, declared use, grant, capability, canonical argument, scope, consent, target eligibility, and readiness are all checked

      Examples:
        | target |
        | a workspace, tab, or pane ID |
        | a filesystem path |
        | a network host or redirect |
        | an explicit provider ID |

    @req-iar-fr-020 @provider-resolution
    Scenario Outline: Provider resolution is deterministic and authority-safe
      Given a contract has <eligible state>
      When one request resolves
      Then <outcome>
      And the selected provider acts with its own authority rather than inheriting the caller's grants

      Examples:
        | eligible state | outcome |
        | no active provider | structured unavailable failure |
        | one active eligible provider | that provider is selected |
        | several with one stable default | the default is selected |
        | several without target or default | explicit ambiguity failure |
        | an authorized explicit target | that exact provider is selected |

    @req-iar-fr-021 @settlement
    Scenario Outline: Exactly one validated terminal result crosses the boundary
      Given a provider <behavior>
      When the request settles
      Then <outcome>

      Examples:
        | behavior | outcome |
        | returns schema-valid output | one success with provider metadata reaches the caller |
        | returns invalid output | one structured kernel failure reaches the caller and invalid data does not |
        | throws a declared domain error | one structured failure reaches the caller |
        | replies after cancellation already settled | telemetry records a late reply without second settlement |

    @req-iar-fr-022 @req-iar-nfr-007 @cancellation
    Scenario Outline: Cancellation reports whether work physically started
      Given cancellation or deadline occurs <phase>
      When the dispatcher settles the caller
      Then <result>
      And no result claims rollback

      Examples:
        | phase | result |
        | before mailbox start | outcome notStarted proves the handler never ran |
        | after physical start without durable completion | outcome unknown reports possible effect |
        | after start while work still runs | global and principal admission remain held until physical completion |

    @req-iar-fr-023 @idempotency
    Scenario Outline: Retry cannot duplicate or retarget an effect
      Given a keyed request is repeated with <duplicate>
      When the retained atomic claim is consulted
      Then <result>

      Examples:
        | duplicate | result |
        | the same principal, contract, input, and target while running | the caller joins one execution |
        | the same retained terminal request | the same terminal result replays |
        | changed input or explicit target | tenon.idempotency-conflict and no second execution |
        | an unkeyed side effect after start | no automatic retry or provider fallback occurs |

  Rule: Generations and execution lanes make lifecycle and backpressure physical

    @req-iar-fr-024 @generation
    Scenario Outline: Generation swap never splits one request
      Given generation g is active and candidate g plus 1 <staging result>
      When activation or retirement proceeds
      Then <outcome>

      Examples:
        | staging result | outcome |
        | fails | g remains active and the candidate error is visible |
        | succeeds | new requests lease g plus 1 while admitted g calls drain on g |
        | is disabled or uninstalled | every queued and running lane settles under retirement rules before shutdown |

    @req-iar-fr-025 @lane-inventory
    Scenario: Every core contract maps to one physical mailbox
      Given the exact CoreIntentName inventory is installed
      When lane classification is audited
      Then each intent belongs to exactly one closed lane
      And every lane owns a distinct bounded mailbox
      And adding a lane does not increase global admission

    @req-iar-fr-026 @terminal-wait
    Scenario Outline: Core lane concurrency matches the normative exception map
      Given requests enter <lane>
      When the mailbox admits them
      Then <concurrency>

      Examples:
        | lane | concurrency |
        | terminalWait | up to 8 independent pane-scoped waits may run |
        | every other core lane | one request runs serially |

    @req-iar-fr-027 @req-iar-nfr-002 @backpressure
    Scenario Outline: Intent admission is bounded without silent loss
      Given <capacity state>
      When another request arrives
      Then <outcome>

      Examples:
        | capacity state | outcome |
        | one principal has queued FIFO work | fair round-robin preserves that principal's order among peers |
        | background work fills nonreserved capacity | interactive reserved capacity remains usable |
        | lane, principal, global count, or byte budget is full | tenon.overloaded returns with no dropped side effect |
        | a queued deadline expires | the queue node is removed without an accumulating tombstone |

    @req-iar-fr-028 @cycle-progress
    Scenario Outline: Causal work cannot create an unbounded wait graph
      Given a provider <behavior>
      When dispatch evaluates the causal chain
      Then <result>

      Examples:
        | behavior | result |
        | attempts to await an ancestor | tenon.cycle-detected is returned before deadlock |
        | exceeds maximum causal depth | the request is refused |
        | reports progress faster than the delivery rate | progress is rate-limited and coalesced to the latest pending state |
        | wants a detached reaction | the fact is published as an EVENT instead of an orphaned intent |

  Rule: Each public surface is a projection, not another semantic API

    @req-iar-fr-029 @core-inventory
    Scenario: Core contract names and lanes are one code-owned closed inventory
      Given CoreIntentName gains, loses, renames, or reclassifies a case
      When catalog fitness runs
      Then the source inventory, normative table, audience profile, execution lane, schemas, providers, and superseded paths must change together

    @req-iar-fr-030 @core-audience
    Scenario Outline: Core intents use only two exact audience profiles
      Given a core intent belongs to <profile>
      When exposure is compiled
      Then its audience is exactly <audience>
      And no user, generic app, or core authority appears

      Examples:
        | profile | audience |
        | programmatic | plugin, CLI, and agent |
        | plugin-only | plugin |

    @req-iar-fr-031 @command-projection
    Scenario: Launcher palette and registered bindings reuse plugin presentation
      Given a plugin-owned intent declares palette metadata and eligible launcher or keybinding presentation
      When each surface builds its command index
      Then they project the same declaration and shared invoker
      And no core intent or handwritten duplicate command row is inserted

    @req-iar-fr-032 @local-keyboard
    Scenario Outline: Keyboard reachability, not the device, selects the path
      Given <control>
      When the key gesture occurs
      Then <route>

      Examples:
        | control | route |
        | a host-wide discoverable or rebindable product command | invoke the plugin-owned intent projection |
        | editor save or Escape in the focused editor | typed local control |
        | palette navigation or dismissal | typed local control |
        | focused Ghostty input or list navigation | focused responder/local control |

    @req-iar-fr-033 @cli
    Scenario Outline: CLI control plane cannot accumulate domain verbs
      Given the CLI sends <operation>
      When the server classifies it
      Then <route>

      Examples:
        | operation | route |
        | ping | reserved direct control |
        | same-channel app activation or focus | reserved single-instance control |
        | list or describe contracts | reserved discovery control plane |
        | workspace, terminal, file, process, or other domain work | intent send through normal policy |

    @req-iar-fr-034 @agent
    Scenario: Agent tools are one revisioned policy projection
      Given an agent session lists canonical tools
      When catalog, provider, policy, or session revision changes
      Then only agent-audience active contracts with canonical schemas and host effect policy are exposed
      And stale listing cursors are invalidated
      And cancellation and progress map to the internal request exactly once

    @req-iar-fr-035 @no-channel
    Scenario Outline: Existing mechanisms compose every two-way case
      Given a product interaction needs <shape>
      When it is designed
      Then <mechanism>
      And no duplex channel or event-with-reply is created

      Examples:
        | shape | mechanism |
        | ask and receive one answer in either direction | one declared INTENT per direction |
        | notify zero to many listeners | EVENT with no reply |
        | long work with repeated facts/cancel | bounded RESOURCE/TASK or stable value re-presented to finite intents |

    @req-iar-fr-036 @plugin-event
    Scenario: Plugin event publication reveals no observer topology
      Given a publisher declares local channel board.changed and an observer separately declares its qualified name
      When the host accepts the emitted fact
      Then host identity qualifies the owner-local channel
      And only declared observers are eligible
      And the publisher sees no listener identity or delivery count

    @req-iar-fr-037 @contribution-action
    Scenario: Contribution callbacks do not borrow presentation authority
      Given a user selects a plugin view or palette contribution
      When the owner receives the immutable action fact
      Then the callback itself grants no product capability
      And any resulting finite effect uses its canonical typed DIRECT or INTENT route

    @req-iar-fr-038 @control-plane
    Scenario Outline: Reserved control plane carries lifecycle but no domain command
      Given a message performs <operation>
      When control-plane admission checks it
      Then <outcome>

      Examples:
        | operation | outcome |
        | framing, discovery revision, provider bind/swap, request cancel/progress/settlement, resource read/cancel, or runtime health | the exact reserved operation is accepted |
        | split pane, open file, run process, or another product verb | it is refused as a boundary violation |

    @req-iar-fr-039 @tenon-inventory
    Scenario: Public plugin paths match one exhaustive inventory
      Given the runtime bootstrap and normative table are enumerated
      When their exact paths and classifications are compared
      Then every current tenon path matches once
      And finite filesystem, process, terminal, browser, workspace, UI, secret, network, OS, and clipboard effects exist only through intents.send

  Rule: Architecture changes carry enforcement and remove old paths

    @req-iar-fr-040 @req-iar-nfr-010 @change-protocol
    Scenario: An interaction change is one reviewed vertical slice
      Given an author adds or changes an interaction
      When the change is proposed for acceptance
      Then semantic owner, principals, cardinality, lifetime, authority, failure, backpressure, and chosen rung are recorded
      And normative and source inventories plus a pre-acceptance fitness test change together
      And the superseded public path is deleted and source-wide stale search is clean
      And relevant build, tests, performance probes, and an independent verifier pass complete

  Rule: Cross-cutting architecture qualities remain measurable

    @req-iar-nfr-003 @latency
    Scenario: Intent kernel CPU stays inside the documented ratio
      Given fifteen warmed paired samples compare one dispatcher send with an equivalent awaited actor DIRECT call
      When the cheapest-sample statistic is computed by the documented CPU-time method
      Then the intent-to-direct ratio is at most 700
      And a JSON round trip, schema recompile, or duplicate policy pass cannot hide behind an absolute-time threshold

    @req-iar-nfr-004 @main-actor
    Scenario: Boundary work preserves unrelated UI and lane progress
      Given filesystem, process, network, schema, plugin, and resource work is active
      When built-in UI and an unrelated provider lane need progress
      Then non-UI work stays off MainActor
      And the UI, other plugin executor, and independent lane remain responsive

    @req-iar-nfr-006 @telemetry-privacy
    Scenario: Traceability does not become payload logging
      Given one public request is created, queued, started, and settled
      When telemetry records its trace
      Then IDs, principal surface, contract, provider generation, timings, byte counts, consent, and outcome are attributable
      And input/output content is redacted by default
      And stack and invalid-result detail are restricted to privileged inspection

    @req-iar-nfr-008 @compatibility
    Scenario: A breaking contract change mints a new major
      Given a provider needs a required input or incompatible output change
      When schema compatibility is evaluated
      Then the changed contract receives a new major version
      And the old major remains callable during its declared migration window

    @req-iar-nfr-009 @observability
    Scenario: Every caller can understand discovery and refusal in domain terms
      Given a contract is hidden, denied, unavailable, ambiguous, overloaded, cancelled, or failed
      When plugin, CLI, agent, or privileged inspection observes it
      Then structured contract, policy, provider, generation, trace, queue, and outcome data explains the state appropriate to that principal

    @req-iar-nfr-011 @accessibility
    Scenario: One action path has equivalent accessible input routes
      Given a command or native local control supports pointer interaction
      When a keyboard or VoiceOver user operates the equivalent affordance
      Then the same owning projection or typed local action path runs
      And focus and observable outcome remain equivalent

    @req-iar-nfr-012 @resilience
    Scenario Outline: Public failures remain explicit and nonduplicating
      Given a request encounters <failure>
      When the kernel reaches its terminal rule
      Then one structured result describes the failure or uncertainty
      And no duplicate provider effect or unrelated-state loss occurs

      Examples:
        | failure |
        | invalid input or provider output |
        | missing or ambiguous provider |
        | policy denial or overload |
        | deadline or cancellation |
        | provider reload or retirement |
