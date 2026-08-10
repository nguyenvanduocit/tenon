# language: en

@prd-TENON_PRD_007
Feature: Control the correct local Tenon instance through canonical intents
  Local humans and agents need bounded discovery and invocation without a second domain API.
  PRD: cli-control.prd.md

  Rule: The packaged command belongs to the correct installed channel

    @req-cli-fr-001 @req-cli-nfr-006 @packaging
    Scenario: Production installs a relocatable command without administrator access
      Given the supported release app contains its signed self-contained auxiliary CLI
      When the operator installs it from Production Settings
      Then an executable tenon-cli is copied to the user's .local/bin directory
      And it does not depend on a framework inside the app or checkout

    @req-cli-fr-002 @channel
    Scenario: Staging cannot replace the neutral global command
      Given both production and staging are installed
      When CLI installation is inspected in staging
      Then the global installer is unavailable
      And staging panes still use their bundled command and staging socket

    @req-cli-fr-003 @channel
    Scenario: Production and staging can be primary together
      Given no Tenon instance is running
      When production and staging launch
      Then each owns a distinct socket directory and singleton claim
      And each uses a distinct Application Support root

    @req-cli-fr-004 @req-cli-nfr-005 @discovery
    Scenario Outline: Client socket discovery never guesses across channels
      Given the CLI runs in <context>
      When it resolves its socket path
      Then it chooses <path>

      Examples:
        | context | path |
        | a neutral shell without an override | the production compatibility socket |
        | a production pane | TENON_SOCKET_PATH from that production instance |
        | a staging pane | TENON_SOCKET_PATH from that staging instance |

    @req-cli-fr-005 @environment
    Scenario: A terminal exports stable local targeting facts
      Given a pane's terminal surface is created
      When its process environment is assembled
      Then TENON_SOCKET_PATH names the owning channel
      And TENON_PANE_ID names that pane
      And TENON_AGENT_HOOK_SCRIPT names the owning channel's runtime script

  Rule: The socket and singleton claim fail closed

    @req-cli-fr-006 @req-cli-nfr-001 @socket-security
    Scenario Outline: An unsafe socket path is refused
      Given the expected socket directory or node is <condition>
      When the server or client verifies it without following symlinks
      Then control access is refused

      Examples:
        | condition |
        | owned by another user |
        | a symlink |
        | the wrong filesystem node type |
        | more permissive than directory 0700 or socket 0600 |

    @req-cli-fr-007 @req-cli-nfr-001 @claim
    Scenario Outline: Only a safe stable claim can elect a primary
      Given tenon.lock is <condition>
      When a launch opens and locks it
      Then <outcome>

      Examples:
        | condition | outcome |
        | a same-user single-link 0600 regular file | the nonblocking advisory lock may elect the primary |
        | a symlink | startup is unavailable |
        | multiply linked | startup is unavailable |
        | held by the live primary | the contender is secondary |

    @req-cli-fr-008 @singleton
    Scenario: A second same-channel launch activates instead of assembling another app
      Given a primary owns the channel claim and is becoming or already reachable
      When another app launches in that channel
      Then the contender sends app.focus with bounded retry
      And exits before hook installation or durable workspace construction
      And the primary retains its socket

    @req-cli-fr-009 @stale-recovery
    Scenario Outline: Stale-path recovery removes only a dead socket node
      Given the claim owner finds <occupant> at the socket path
      When no live server answers
      Then <result>

      Examples:
        | occupant | result |
        | a stale socket node | that node is reclaimed and the server may bind |
        | a regular file | the file remains and bind degrades |
        | a symlink | the symlink remains and bind degrades |

    @req-cli-fr-010 @req-cli-nfr-007 @degradation
    Scenario Outline: Failed control startup has an honest outcome
      Given the app <failure>
      When startup settles
      Then <outcome>

      Examples:
        | failure | outcome |
        | cannot safely acquire the claim | workspace startup stops as unavailable |
        | owns the claim but cannot bind after recovery | the running app logs the exact degradation |
        | is degraded staging | child panes retain the staging target and never fall back to production |

  Rule: Protocol v3 is bounded and has a closed action vocabulary

    @req-cli-fr-011 @req-cli-nfr-002 @protocol-v3
    Scenario: One connection carries one exact v3 exchange
      Given a client connects to the secure socket
      When it writes one newline-delimited v3 request and closes its write side
      Then the server writes one v3 response and closes the connection

    @req-cli-fr-012 @req-cli-nfr-002 @codec
    Scenario Outline: Invalid framing returns a closed control failure
      Given a request has <defect>
      When the v3 codec incrementally reads it
      Then it is rejected with <code>
      And no domain operation starts

      Examples:
        | defect | code |
        | the wrong protocol version | unsupported_version |
        | malformed or too-deep JSON | malformed_json |
        | an unknown root field | malformed_json |
        | a non-object params value | invalid_params |
        | more than the encoded bound | payload_too_large |

    @req-cli-fr-013 @req-cli-nfr-004 @actions
    Scenario Outline: The parser accepts only the five protocol actions
      Given a valid v3 request names <action>
      When the action parser runs
      Then it produces <classification>

      Examples:
        | action | classification |
        | ping | transport liveness control |
        | app.focus | instance activation control |
        | intent.list | intent discovery control |
        | intent.describe | intent discovery control |
        | intent.send | canonical intent adapter |
        | terminal.write | unknown_action |

    @req-cli-fr-014 @ping
    Scenario: Ping proves server liveness only
      Given the app can answer its control socket
      When the client sends ping
      Then the result contains protocol version, process ID, and active state
      And it makes no promise that every provider is ready

    @req-cli-fr-015 @focus
    Scenario: Focus activates the existing primary
      Given the primary app has a window
      When app.focus is accepted
      Then the app activates and its first window becomes key and front

  Rule: Discovery and invocation expose one canonical Intent Bus

    @req-cli-fr-016 @discovery
    Scenario Outline: Discovery is filtered by the CLI principal
      Given an intent is <visibility>
      When the CLI lists or describes contracts
      Then <result>

      Examples:
        | visibility | result |
        | callable by the CLI audience and policy | its canonical summary or description is returned |
        | plugin-only or otherwise hidden | it is absent and describe returns intent_not_found |

    @req-cli-fr-017 @req-cli-nfr-004 @dispatch
    Scenario: Intent send crosses the production dispatcher
      Given the client supplies canonical name, input, scope, target, idempotency, and timeout
      When intent.send is executed
      Then the CLI principal uses normal policy, resolution, validation, timeout, and telemetry
      And no socket-specific domain service runs

    @req-cli-fr-018 @errors
    Scenario: Intent failure remains structurally useful
      Given canonical dispatch fails
      When the CLI response is encoded
      Then it preserves intent source, code, details, retry guidance, outcome, request ID, and provider ID
      And it is not flattened into a generic CLI message

    @req-cli-fr-019 @alias
    Scenario Outline: Friendly commands are only client-side intent constructors
      Given the operator uses <alias>
      When the CLI builds the request
      Then it sends <intent> through action intent.send

      Examples:
        | alias | intent |
        | state | workspace.state.v1 |
        | send | terminal.write.v1 |
        | read | terminal.viewport.read.v1 |
        | wait | terminal.wait.v1 |
        | pane-focus | workspace.pane.focus.v1 |
        | tab-focus | workspace.tab.focus.v1 |

    @req-cli-fr-020 @scope
    Scenario Outline: Scope designates without granting
      Given intent.send carries <scope>
      When it is parsed and authorized
      Then <result>

      Examples:
        | scope | result |
        | valid workspace, tab, and pane UUIDs | the designation reaches normal policy |
        | a malformed UUID | invalid_params is returned |
        | userGestureID | invalid_params is returned because the field is host-owned |

    @req-cli-fr-021 @scope
    Scenario Outline: Pane targeting follows explicit precedence
      Given <inputs>
      When the CLI constructs scope
      Then <result>

      Examples:
        | inputs | result |
        | explicit --pane and TENON_PANE_ID | the explicit pane is used |
        | only TENON_PANE_ID | the environment pane is used |
        | explicit --tab and TENON_PANE_ID | the tab is used and inherited pane is omitted |
        | no pane or tab | provider-active resolution is allowed where the contract permits |

    @req-cli-fr-022 @wait
    Scenario Outline: Terminal wait returns one finite answer
      Given the CLI waits for <condition> with a valid bound
      When the condition is met or its timeout expires
      Then one result reports that condition and met true or false
      And the client transport deadline includes a one-second settlement margin

      Examples:
        | condition |
        | exit |
        | tui-idle |
        | command-finished |

    @req-cli-fr-023 @req-cli-nfr-008 @consent
    Scenario: An unanswered policy prompt cannot hold a CLI request forever
      Given a CLI policy intent has a caller deadline and nobody answers its prompt
      When that deadline expires
      Then the dispatch returns canonical deadline failure
      And the CLI receives it before the server watchdog
      And no standing CLI or agent consent is created

  Rule: Physical request lifetime remains responsive and settles once

    @req-cli-fr-024 @req-cli-nfr-002 @backpressure
    Scenario Outline: Connection capacity is a real end-to-end cap
      Given eight valid slow requests occupy all permits
      When <event> occurs
      Then <outcome>

      Examples:
        | event | outcome |
        | another connection exceeds admission grace | it receives busy without joining an unbounded queue |
        | one request settles | exactly one permit becomes available |
        | a handler never calls completion for 120 seconds | its watchdog settles it once and returns the permit |

    @req-cli-fr-025 @lifecycle
    Scenario: Server teardown ends pending clients and releases the claim safely
      Given requests are still live when the server is destroyed
      When teardown drains ownership
      Then each pending permit settles at most once as not ready
      And the listener and socket are released before the stable claim lock

    @req-cli-fr-026 @output
    Scenario Outline: CLI process outcomes are scriptable
      Given the CLI reaches <outcome>
      When the process exits
      Then it uses <code>
      And <presentation>

      Examples:
        | outcome | code | presentation |
        | success | 0 | pretty sorted JSON on stdout |
        | server control or intent failure | 1 | structured JSON on stdout |
        | invalid local usage | 2 | a concise error or usage on stderr |

    @req-cli-nfr-003 @responsiveness
    Scenario: A slow provider does not block the listener or unrelated work
      Given one accepted intent remains in asynchronous dispatch
      When another client connects and sends a fast request
      Then accept, framing, and decode proceed off MainActor
      And only minimal UI effects hop to MainActor
      And the unrelated request can settle independently

    @req-cli-nfr-005 @compatibility
    Scenario: Protocol mismatch is explicit rather than guessed
      Given a v2 client contacts the v3 app
      When the request is decoded
      Then unsupported_version names the current version
      And the app does not reinterpret the old shape

    @req-cli-nfr-007 @observability
    Scenario: Diagnostics distinguish control degradation from a stopped app
      Given Tenon remains visible but its socket could not bind
      When support inspects the host log
      Then the exact degraded path and reason are present
      And sensitive intent input is not required to diagnose it

    @req-cli-nfr-008 @lifecycle
    Scenario: A disconnected client still cannot create unbounded host work
      Given the client disconnects while its intent is awaiting consent or a provider
      When no early disconnect cancellation is installed
      Then the per-call deadline or server watchdog still settles the host request
      And its permit is eventually released exactly once
