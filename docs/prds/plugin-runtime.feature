# language: en

@prd-TENON_PRD_010
Feature: Run declared plugins with bounded authority and generation-owned lifetimes
  Plugin authors need one predictable runtime contract while operators need trust and teardown to be explicit.
  PRD: plugin-runtime.prd.md

  Rule: Inventory provenance and manifest declaration precede execution

    @req-prt-fr-001 @req-prt-nfr-011 @inventory
    Scenario: Ordered roots determine provenance and collision priority
      Given the host configures a sealed bundled inventory before a writable user inventory
      When the same candidate identity is encountered in both roots
      Then the exact owning root determines its trust class
      And the earlier valid bundled candidate cannot be displaced by the user candidate

    @req-prt-fr-002 @discovery
    Scenario Outline: Discovery distinguishes plugins from unrelated files
      Given an inventory contains <entry>
      When the host discovers immediate entries in lexical order
      Then <outcome>

      Examples:
        | entry | outcome |
        | a directory containing manifest.json | the directory is a candidate |
        | a top-level JavaScript file with a tenon-manifest header | the file is a candidate |
        | a plain JavaScript utility with no header | the file is ignored |
        | no inventory root yet | discovery returns an empty set without failure |

    @req-prt-fr-003 @req-prt-nfr-009 @single-file
    Scenario: One-file and directory plugins receive identical authority rules
      Given equivalent declarations exist in a manifest directory and a JavaScript header
      When each plugin loads, activates, reloads, and retires
      Then both pass through the same manifest decoder and lifecycle
      And neither package shape receives different identity, policy, or authority

    @req-prt-fr-004 @manifest
    Scenario Outline: Invalid declaration fails before JavaScript evaluation
      Given a candidate manifest has <defect>
      When manifest preparation runs
      Then that candidate is not evaluated
      And an actionable diagnostic identifies <defect>

      Examples:
        | defect |
        | no stable plugin ID or required intents envelope |
        | an empty or over-bound name or version |
        | duplicate permissions, setting keys, uses, or provisions |
        | a partial, foreign-owned, or invalid provision |
        | an invalid palette, event, or automation declaration |

    @req-prt-fr-004 @unknown-permission
    Scenario: An unknown permission is not ambient authority
      Given a valid manifest names a permission this host does not know
      When the candidate is inspected and activated
      Then the permission grants no capability
      And the author receives a compatibility warning

    @req-prt-fr-005 @failure-isolation
    Scenario Outline: A losing late-inventory plugin fails alone
      Given healthy earlier plugins are prepared
      And a later candidate has <conflict>
      When the complete inventory is admitted
      Then the later candidate is refused with its reason
      And the healthy earlier plugins remain available

      Examples:
        | conflict |
        | a bundled plugin ID or directory identity |
        | a reserved or overlapping namespace |
        | an unknown provisioned contract |
        | a catalog contract already owned by another plugin |

    @req-prt-fr-005 @primary-conflict
    Scenario: A primary-inventory identity clash is a host packaging failure
      Given two bundled candidates claim one identity
      When the primary inventory is prepared
      Then the primary load fails rather than choosing an arbitrary shipped plugin

  Rule: Trust, installation identity, and durable state are host owned

    @req-prt-fr-006 @user-plugin
    Scenario: A newly discovered user plugin starts inert
      Given a new candidate belongs to the explicit-enablement inventory
      When discovery finishes
      Then the candidate is disabled
      And it has no standing intent consent

    @req-prt-fr-007 @trust
    Scenario Outline: A manifest cannot promote its provenance
      Given <candidate>
      When the host derives inventory trust
      Then <result>

      Examples:
        | candidate | result |
        | a plugin in the sealed host inventory | host provenance may auto-enable and seed eligible policy consent |
        | a user plugin claiming bundled status | the claim buys no trust, enablement, or consent |
        | an unknown path outside all inventories | no trusted inventory owns it |

    @req-prt-fr-008 @identity-rotation
    Scenario Outline: Principal changes cannot inherit old private state
      Given an installed plugin undergoes <transition>
      When inventory reconciliation completes
      Then it receives a fresh installation ID
      And old settings, storage, secrets, and consent are not inherited
      And explicit-enablement provenance leaves it disabled

      Examples:
        | transition |
        | bundled to user inventory |
        | user to bundled inventory |
        | legacy record with unknown provenance |
        | uninstall followed by reinstall of the same plugin ID |

    @req-prt-fr-009 @persistence
    Scenario Outline: Installation state publishes only after a durable transaction
      Given the installation document operation <condition>
      When enablement or a session revision changes
      Then <outcome>

      Examples:
        | condition | outcome |
        | acquires its sibling lock and atomic write succeeds | the deterministic record and monotonically increased revision become visible |
        | fails locking or writing | no proposed in-memory identity or revision is returned |
        | exceeds count, size, version, or uniqueness bounds | the document is refused without partial state |

  Rule: Runtime language does not change plugin ownership

    @req-prt-fr-048 @bundled-swift
    Scenario: A compiled implementation remains a managed plugin
      Given a bundled manifest names runtime bundled-swift and an exact compiled PluginID
      When its generation activates, receives events, provides intents, and is disabled
      Then provider calls still cross the intent boundary under that plugin principal
      And event and contribution publication still use the plugin lifecycle
      And disabling it withdraws its providers and contributions like a JavaScript plugin

    @req-prt-fr-048 @bundled-swift @trust
    Scenario: A user manifest cannot select code linked into the app
      Given a manifest in the explicit-enablement inventory names runtime bundled-swift
      When manifest preparation resolves its inventory provenance
      Then activation fails before a runtime is created
      And no compiled implementation, authority, or contribution is exposed

    @req-prt-fr-048 @javascript-default
    Scenario: Existing manifests keep the JavaScript backend
      Given a valid manifest omits runtime
      When the shared manifest decoder loads it
      Then its runtime is javascript
      And its main.js entrypoint remains required

  Rule: JavaScript receives one closed public vocabulary

    @req-prt-fr-010 @req-prt-nfr-004 @global-scope
    Scenario: Runtime globals expose no ambient native bridge or console
      Given a staged runtime owns its pinned JavaScriptCore thread
      When the plugin enumerates globalThis
      Then only standard JavaScript built-ins, tenon, and immutable named lifecycle hooks match the allowlist
      And console and the public native-post bridge are absent
      And JavaScript values never cross off the pinned executor

    @req-prt-fr-011 @closed-inventory
    Scenario: The top-level Tenon inventory is exact
      Given a plugin enumerates the public tenon object
      When its keys and method groups are compared with the normative inventory
      Then they are exactly apiVersion, agents, intents, settings, storage, log, path, events, timers, process, fs, statusBar, views, and palette
      And no feature-specific finite helper is present

    @req-prt-fr-012 @metadata
    Scenario: API version is immutable metadata only
      Given a plugin reads tenon.apiVersion
      When it attempts to replace or extend that value
      Then the runtime metadata remains unchanged
      And the value provides no operation or capability

    @req-prt-fr-013 @scoped-facility
    Scenario Outline: Scoped facilities reveal only installation-owned values
      Given an active plugin uses <facility>
      When the operation completes
      Then <scope>

      Examples:
        | facility | scope |
        | settings.get | only a declared setting key and this installation value are visible |
        | storage.get or storage.set | only this installation non-secret JSON namespace is visible |
        | log | the line is attributed to this plugin generation |

    @req-prt-fr-014 @storage
    Scenario Outline: Storage cache follows durable FIFO commits
      Given accepted writes A then B are queued
      When <persistence outcome>
      Then <visible state>

      Examples:
        | persistence outcome | visible state |
        | both commits succeed | callbacks and cache observe A then B in order |
        | A fails | the last committed value remains visible and A is not published |
        | shutdown begins after B is accepted | B drains before orderly retirement completes |

    @req-prt-fr-015 @path
    Scenario: Path helpers cannot inspect the filesystem
      Given a plugin calls join, normalize, basename, dirname, or extname
      When the pure helper returns a string
      Then no bridge message, I/O, permission check, or host-state read occurs
      And existence or mutation still requires a declared canonical intent or resource

  Rule: Finite operations use the intent dispatcher and its policy

    @req-prt-fr-016 @intent-caller
    Scenario Outline: A finite plugin request settles exactly once
      Given a plugin sends <request>
      When dispatcher admission completes
      Then <outcome>

      Examples:
        | request | outcome |
        | a declared bounded use with an eligible provider | one Promise resolves to one canonical IntentResult |
        | an undeclared use or unauthorized target | one denied IntentResult resolves without performing the effect |
        | an outstanding use whose generation retires | it is cancelled or settled and leaves no pending token |

    @req-prt-fr-017 @provider
    Scenario Outline: Provider binding is a staging contract
      Given a manifest provides one plugin-owned intent
      When the runtime <binding>
      Then <outcome>

      Examples:
        | binding | outcome |
        | binds one matching handler during staging | it becomes ready before activation |
        | omits the handler | staging fails and the candidate never becomes active |
        | binds it twice or after activation | the runtime refuses the invalid binding |

    @req-prt-fr-018 @nested-intent
    Scenario: Nested sends remain within the parent causal scope
      Given a plugin provider receives a call with scope, deadline, progress, and cancellation
      When it uses call.send for another declared intent
      Then the nested request inherits the parent request and deadline by default
      And parent cancellation settles both bridges once
      And explicit retargeting is authorized again for the provider principal

    @req-prt-fr-019 @discovery-control
    Scenario: Intent discovery is a policy-filtered projection
      Given two installation principals have different grants and audiences
      When each lists or describes available intents
      Then each sees only its authorized catalog projection
      And discovery is handled as reserved control plane rather than an intent sent through itself

    @req-prt-fr-020 @policy
    Scenario Outline: Declaring an operation does not grant its authority
      Given a plugin declares a sensitive intent use
      When <policy condition>
      Then <result>

      Examples:
        | policy condition | result |
        | required capability is absent | the request is denied |
        | path or URL is outside admitted canonical scope | the request is denied |
        | redirect leaves the network host allowlist | the redirect is denied |
        | pane or workspace scope differs from invocation | the request is denied |
        | audience, consent, target, and provider readiness all pass | the typed provider may execute |

    @req-prt-fr-021 @policy-consent
    Scenario: Concurrent first policy calls share durable consent
      Given one installation sends concurrent first calls for the same policy fingerprint
      When consent is required
      Then one prompt wave represents all waiters
      And approval becomes standing consent only after its durable write succeeds
      And a hot reload of the same installation retains it

    @req-prt-fr-022 @consent-mode
    Scenario Outline: Consent mode retains its exact meaning
      Given a contract uses <mode>
      When the plugin invokes it repeatedly
      Then <behavior>

      Examples:
        | mode | behavior |
        | always | every invocation prompts and no standing answer skips it |
        | never | no consent record is created |
        | policy from a user inventory plugin | no bundled standing consent is preseeded |

    @req-prt-fr-022 @consent-mode @permissions
    Scenario: The operator's switch is the one thing that answers an always contract
      Given the host's Permissions switch approves every permission request automatically
      When a plugin invokes a contract whose confirmation is always
      Then the invocation is approved without prompting
      And the approval creates no standing consent record

    @req-prt-fr-046 @durable-consent
    Scenario: An approval outlives the process it was given in
      Given a person approves a policy contract for one caller
      When the app is relaunched
      Then the same caller invokes that contract without being asked again

    @req-prt-fr-046 @durable-consent
    Scenario: What could not be kept was never granted
      Given the standing-consent store cannot be written
      When a person approves a policy contract
      Then the grant fails closed and the engine holds no consent for it

    @req-prt-fr-046 @durable-consent
    Scenario: Withdrawal reaches the kept state as well as memory
      Given a caller holds standing consent that was kept for the next launch
      When its authority is withdrawn
      Then the kept state is rewritten without it
      And a later launch restores no consent for that caller

    @req-prt-fr-023 @revocation
    Scenario Outline: Authority withdrawal wins lifecycle races
      Given an invocation is queued while the plugin is <transition>
      When lifecycle serialization reaches that transition
      Then applicable consent and admission are withdrawn
      And the queued invocation cannot enter with stale authority

      Examples:
        | transition |
        | disabled |
        | uninstalled |
        | moved to explicit-enablement provenance |
        | failing to persist a consent decision |

  Rule: Facts, resources, and contributions have bounded owner lifetimes

    @req-prt-fr-024 @host-event
    Scenario: Host events deliver immutable facts only to admitted subscriptions
      Given an active plugin declares and is authorized for a host event family
      When it subscribes, receives a fact, and unsubscribes
      Then the handler receives no reply channel to the publisher
      And no later event reaches that subscription
      And retirement removes any subscription left open

    @req-prt-fr-025 @plugin-event
    Scenario: Plugin-owned events use stable qualified identity
      Given a publisher declares local channel board.changed
      And an observer declares the publisher-qualified channel
      When the publisher emits a fact
      Then the host prefixes the local name with the stable plugin ID
      And only declared qualified observers can receive it

    @req-prt-fr-026 @req-prt-nfr-003 @event-backpressure
    Scenario: A slow event observer cannot block the publisher or peers
      Given one generation accepts ordered facts for a fast and a slow observer
      When the slow observer exceeds its finite delivery capacity
      Then emit remains fire-and-forget and reveals no listeners or delivery count
      And accepted facts retain order
      And the publisher and fast observer continue under explicit bounded-loss behavior

    @req-prt-fr-027 @timer
    Scenario Outline: Timer lifetime cannot escape its generation
      Given a plugin creates <timer>
      When <transition>
      Then <outcome>

      Examples:
        | timer | transition | outcome |
        | a one-shot timer | it fires | its callback runs at most once |
        | a repeating timer below ten milliseconds | it is created | creation is refused |
        | any accepted timer | cancel, failure, reload, disable, uninstall, or shutdown occurs | no later callback reaches the retired generation |

    @req-prt-fr-028 @process-stream @partial
    Scenario: Streaming process output remains finite and generation owned
      Given a plugin with process.exec starts a stream within the concurrent limit
      When stdout, stderr, overflow, cancellation, and exit occur
      Then bounded copied chunks return through the runtime mailbox
      And overflow is explicit
      And one exit fact retires the handler
      And current teardown terminates the Foundation Process leader

    @req-prt-fr-029 @watch
    Scenario Outline: Filesystem watches end visibly and safely
      Given a plugin with filesystem.read requests <watch state>
      When the resource operates
      Then <outcome>

      Examples:
        | watch state | outcome |
        | a watch within count and path capacity | accepted path facts arrive through a bounded mailbox |
        | a 65th watcher or pending-path overflow | refusal or overflow is explicit and no partial batch is delivered |
        | a failed or cancelled watch | its handler retires and late callbacks are ignored |
        | a live watch during generation retirement | native observation is cancelled before callback ownership ends |

    @req-prt-fr-030 @contribution
    Scenario: Contribution publication cannot perform a product effect
      Given a plugin publishes status, view, or palette state
      When the host validates and projects it
      Then only bounded declarative state and owner-scoped action facts change
      And filesystem, workspace, terminal, browser, or OS mutation still requires an intent

    @req-prt-fr-031 @palette
    Scenario Outline: Dynamic palette results belong to one current query revision
      Given a registered provider receives query revision N
      When it publishes <results>
      Then <outcome>

      Examples:
        | results | outcome |
        | bounded rows for revision N | each row designates a declared plugin-owned intent and is eligible to display |
        | rows for superseded revision N minus 1 | the host drops them |
        | a ninth provider or over-bound rows/actions/text | the central limit refuses or truncates according to the schema |

    @req-prt-fr-032 @agents-run
    Scenario: Agent helper composes authority rather than creating it
      Given a plugin declares the four terminal intents used by agents.run
      When it invokes the helper with top-level intents or its current provider call
      Then terminal open, wait, write, and scrollback calls use that sender
      And the sender deadline and cancellation bound the whole composition
      And an arbitrary sender or missing declaration grants nothing

  Rule: Generation replacement and retirement are transactional

    @req-prt-fr-033 @staging
    Scenario: Candidate effects stay private until full activation
      Given a reload candidate declares contracts, providers, events, resources, and contributions
      When manifest preparation, scratch-catalog validation, runtime evaluation, and provider staging run
      Then no candidate state becomes public before all admission steps succeed

    @req-prt-fr-034 @last-good
    Scenario Outline: A failed candidate cannot erase the last good generation
      Given an active generation has contributions and resources
      When a replacement <outcome>
      Then <result>

      Examples:
        | outcome | result |
        | fails manifest parsing, evaluation, handler binding, or provider activation | the active generation, identity, providers, contributions, and resources remain |
        | activates successfully | it replaces the old generation atomically and stale old callbacks are refused |

    @req-prt-fr-035 @lifecycle-race
    Scenario Outline: The later serialized lifecycle request determines final state
      Given an earlier reload is still in flight
      When <later request> is queued
      Then the earlier operation settles before owner release
      And <final state>

      Examples:
        | later request | final state |
        | a newer reload that completes first internally | the newest candidate remains active |
        | disable | the plugin ends disabled |
        | uninstall | no installation, provider, contribution, or runtime remains |
        | shutdown | any committed candidate is closed before shutdown returns |

    @req-prt-fr-036 @req-prt-nfr-005 @retirement
    Scenario: Retirement ends every generation-owned lifetime once
      Given an active generation owns calls, nested calls, subscriptions, timers, watches, processes, callbacks, publications, writes, and logs
      When that generation retires
      Then admission closes before cancellation and drain
      And every owned lifetime reaches one terminal state
      And no retained JavaScript context or stale callback survives

    @req-prt-fr-037 @shutdown-deadline
    Scenario Outline: Shutdown remains finite for good and stalled plugins
      Given shutdown has one end-to-end deadline
      When <runtime behavior>
      Then <report>
      And concurrent shutdown callers join the same operation

      Examples:
        | runtime behavior | report |
        | JavaScript and callbacks quiesce | no stalled phase and the pinned thread stops |
        | synchronous JavaScript never yields | the responsible stalled phase is reported and host control returns by the deadline budget |

    @req-prt-fr-038 @restoration
    Scenario: Restored hidden plugin panes reopen from catalog ownership
      Given persisted workspaces contain visible and hidden panes for an instanced plugin view
      When the host activates or reloads that plugin
      Then the complete workspace catalog determines desired instances
      And every desired instance opens on the active generation
      And hiding a pane does not retire it

    @req-prt-fr-039 @log-backpressure
    Scenario Outline: Plugin logs remain ordered under load and shutdown
      Given a plugin emits <load>
      When the bounded queue delivers outside runtime re-entry
      Then <outcome>

      Examples:
        | load | outcome |
        | lines within capacity | accepted lines appear in original order |
        | more than 512 queued lines | excess lines are counted and one dropped-line summary becomes visible |
        | final accepted lines before shutdown | shutdown drains them before the log worker finishes |

    @req-prt-fr-040 @req-prt-nfr-010 @diagnostics
    Scenario: One plugin failure remains attributable without erasing peers
      Given several candidates have independent manifest, conflict, staging, runtime, or resource failures
      When diagnostics update across reloads
      Then each losing plugin retains an actionable reason
      And unrelated failures and healthy plugin state remain visible
      And no secret or listener identity is included

  Rule: Containment claims must not outrun implementation

    @req-prt-fr-041 @req-prt-nfr-002 @pending @security
    Scenario: User-authored JavaScript is isolated from the Tenon process
      Given an explicitly enabled user plugin is malicious or compromised
      When it exhausts memory, crashes, probes native process state, or attempts prohibited system access
      Then an OS process and sandbox boundary contains the failure and authority
      And the Tenon host process and other plugin principals remain isolated
      And only then may the product describe the plugin as sandboxed

    @req-prt-fr-047 @resource-ownership
    Scenario: A resource declared to belong to a view instance dies with it
      Given a plugin starts a repeating timer declaring the open instance as its owner
      And the plugin registers no close handler of its own
      When that view instance closes because its pane left the workspace catalog
      Then the host retires the timer without the plugin's co-operation
      And a second instance's resources keep running

    @req-prt-fr-047 @resource-ownership
    Scenario: A resource that declares no owner keeps the lifetime it always had
      Given a plugin starts a repeating timer without declaring an owner
      When a view instance of that plugin closes
      Then the timer keeps running until its generation retires

    @req-prt-fr-042 @process-tree
    Scenario: Cancelling a streaming command terminates all descendants
      Given a process stream launches a command that forks descendants
      When the stream is cancelled, overflows, or its generation retires
      Then the owned POSIX process group receives termination
      And no leader or descendant survives after the bounded escalation period

    @req-prt-fr-042 @process-tree
    Scenario: A command that leaves the group is out of reach and said to be
      Given a streamed command calls setsid or daemonizes into launchd
      When the stream is cancelled
      Then the escaped process survives, because no unprivileged macOS app can follow it
      And the plugin author guide states that limit rather than implying containment

    @req-prt-fr-043 @req-prt-nfr-001 @superseded
    Scenario: Removed finite helper APIs cannot return through compatibility work
      Given a finite filesystem, process, workspace, terminal, browser, UI, secret, network, clipboard, or OS operation is proposed
      When its public interaction is classified
      Then it uses the canonical intent and typed provider path
      And historical handwritten helpers, runtime command registration, and sidebar contribution remain absent

    @req-prt-fr-044 @req-prt-nfr-008 @native-boundary
    Scenario: Native capability objects never enter plugin JavaScript
      Given a plugin requests a sensitive effect or long-lived resource
      When the host admits and performs it
      Then JavaScript receives only bounded copied values and owned opaque handles
      And Process, FileHandle, watcher, AppKit, pasteboard, Ghostty, WebKit, model, provider-service, and secret-store objects remain host private

    @req-prt-fr-045 @req-prt-nfr-013 @permission-ux
    Scenario Outline: Permission friction is proportional to actual risk
      Given <plugin state>
      When the plugin performs an unchanged manifest-declared ordinary operation
      Then <permission behavior>
      And declaration, policy, and diagnostics remain available without interrupting every call

      Examples:
        | plugin state | permission behavior |
        | bundled or trusted development provenance | declared installation capabilities are granted without per-operation prompts |
        | explicitly enabled local code with an unchanged authority fingerprint | its reviewed installation grant is reused |
        | local code whose manifest materially expands authority | one enablement-style review explains the delta before the new grant |
        | an operation that is actually sensitive, external, or difficult to reverse | policy may require a specific confirmation proportional to that risk |

  Rule: Cross-cutting runtime qualities are measurable

    @req-prt-nfr-003 @bounds
    Scenario: Every admitted runtime collection has a finite overflow contract
      Given bridge input, nested JSON, calls, callbacks, resources, events, logs, palette values, and persistence documents approach their bounds
      When one exceeds its central limit
      Then the runtime refuses, drops with an explicit summary, or fails the owning generation according to the documented contract
      And no partially decoded batch or unbounded queue remains

    @req-prt-nfr-004 @concurrency
    Scenario: Native callbacks never touch JavaScript from their originating thread
      Given process, watch, event, persistence, and log callbacks arrive concurrently
      When they cross into one runtime
      Then each copies only Sendable snapshots through a finite mailbox
      And JavaScript execution resumes only on its pinned executor
      And log delivery does not synchronously re-enter the runtime actor

    @req-prt-nfr-006 @failure-containment
    Scenario Outline: Incidental failure preserves committed healthy state
      Given <failure>
      When the host handles it
      Then committed installation and healthy plugin state remain intact
      And the owning operation reaches a bounded visible terminal result

      Examples:
        | failure |
        | a malformed late manifest |
        | persistence refusal |
        | candidate activation failure |
        | callback or event overflow |
        | JavaScript shutdown stall |

    @req-prt-nfr-007 @performance
    Scenario: Plugin background work does not block the host UI or static palette
      Given discovery, manifest reads, logs, filesystem resources, and a slow dynamic palette provider are active
      When the person interacts with Tenon
      Then filesystem and delivery work remains off MainActor
      And the static ranked palette remains responsive and in order

    @req-prt-nfr-009 @migration
    Scenario: Runtime schema evolution is explicit and fail closed
      Given an older supported plugin or persisted document loads on a newer host
      When an additive field has a documented default or migration
      Then equivalent declarations retain their contract
      And unknown authority never becomes granted by omission
      And deleted v0.2 helpers, commands, and sidebar are not synthesized

    @req-prt-nfr-011 @determinism
    Scenario: Replaying the same host inputs chooses the same plugin state
      Given identical inventories, files, manifests, policy, persistence, and queued lifecycle operations
      When preparation and serialization repeat
      Then discovery order, catalog winners, policy fingerprints, encoded documents, and final lifecycle state are identical

    @req-prt-nfr-012 @verification
    Scenario: A public runtime change carries boundary and lifecycle evidence
      Given a change adds or alters plugin-visible behavior
      When it is reviewed for release
      Then closed-surface, shipped-plugin, policy, inventory, persistence, concurrency, teardown, backpressure, and reload tests pass
      And Swift 6 warnings-as-errors passes
      And any new public inventory and superseded-path deletion are reviewed in the same change

    @req-prt-nfr-013 @developer-loop
    Scenario: Architecture stays out of the trusted write reload test loop
      Given a developer edits a trusted plugin without changing its declared authority
      When file watching stages and activates the next valid generation
      Then no permission dialog blocks the reload or ordinary declared calls
      And any new architectural ceremony must name the concrete risk or independent compatibility boundary it protects
