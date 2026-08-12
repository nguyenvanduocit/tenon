# language: en

@prd-TENON_PRD_017
Feature: Control and coordinate live coding agents through one bounded semantic contract
  Plugins, CLI callers, and agents need race-free coordination that becomes unattended after one
  explicit trust decision instead of repeatedly interrupting normal work.
  PRD: agent-control.prd.md

  Rule: Agent control is semantic state over an existing terminal, not a second runtime

    @req-ac-fr-001 @req-ac-fr-002 @req-ac-fr-021 @architecture
    Scenario: Each product primitive retains one owner
      Given a caller needs a new visible agent workstream
      When it prepares topology, starts the provider, observes semantic state, and reads evidence
      Then workspace and terminal contracts own topology and raw terminal operations
      And the typed agent-control service owns normalized identity and finite start, rename, prompt, respond, and wait
      And Agent Lens owns rich human evidence
      And no operation is duplicated under an agent-specific public name

    @req-ac-fr-023 @req-ac-nfr-006 @public-boundary
    Scenario Outline: Every programmatic adapter enters the same governed path
      Given a <caller> principal declares and is authorized for an agent contract
      When it invokes that contract
      Then catalog schema, audience, capability, scope, consent, admission, deadline, cancellation, and telemetry all run
      And the provider calls the same typed service used DIRECT by built-in UI

      Examples:
        | caller |
        | plugin |
        | CLI |
        | agent |

    @req-ac-fr-024 @req-ac-nfr-007 @compatibility
    Scenario: Existing one-shot agent composition does not change silently
      Given a plugin already calls tenon.agents.run
      When semantic agent control ships
      Then the helper still opens, writes, waits for command-finished, and reads scrollback under the caller principal
      And no new agent state or provider requirement is imposed on that existing call

  Rule: Public snapshots reveal useful current state without exposing Agent Lens history

    @req-ac-fr-003 @req-ac-fr-004 @req-ac-nfr-004 @privacy
    Scenario: Agent inventory uses an allowlisted public schema
      Given Agent Lens has transcript, session, message, tool, question, approval, and evidence data
      When an authorized caller lists or gets an agent
      Then the result contains opaque reference, optional workspace-local alias, provider, normalized state, activity version, pane workspace and tab IDs, optional focus or seen metadata, update time, and authority confidence
      And it may contain only the current bounded interaction reference, kind, prompt, offered choice IDs and labels, and freeform-allowed flag
      And no transcript or session path, message history, tool body, evidence anchor, secret, raw hook payload, prompt history, or identifying telemetry is exposed

    @req-ac-fr-005 @req-ac-fr-006 @identity
    Scenario Outline: An agent reference never retargets by convenience
      Given a caller retains a reference and the original <change>
      When the caller re-presents that reference
      Then the request fails typed
      And Tenon does not search by provider label, cwd, focus, recency, alias, or pane position

      Examples:
        | change |
        | pane closes |
        | surface incarnation is replaced |
        | provider occupant changes |
        | reference is malformed |
        | scope or principal no longer authorizes the pane |

    @req-ac-fr-026 @alias-write
    Scenario Outline: A workspace-local alias changes only the exact live incarnation
      Given the caller presents one current agent reference in an authorized workspace
      When agent.rename.v1 requests <change>
      Then <outcome>

      Examples:
        | change | outcome |
        | a bounded unused normalized alias | that exact incarnation receives the alias |
        | an empty alias | that exact incarnation's alias is cleared |
        | an alias already owned in the workspace | agent_alias_conflict is returned and neither agent changes |
        | a stale or replaced reference | identity failure is returned and no alias changes |

    @req-ac-fr-027 @alias-lookup
    Scenario: Alias resolution grants no authority and cannot retarget active work
      Given one policy-filtered workspace contains one uniquely matching alias
      When a caller resolves the alias and starts a finite operation
      Then lookup returns the current exact agent reference under the caller's existing authority
      And a later alias change or occupant replacement cannot retarget that operation

    @req-ac-fr-007 @req-ac-nfr-001 @bounds
    Scenario: Agent list is bounded and policy filtered
      Given more than 32 supported agent surfaces exist across authorized and unauthorized workspaces
      When a caller sends agent.list.v1 for one authorized scope
      Then at most 32 authorized snapshots are returned
      And unauthorized agents are absent
      And overflow is explicit rather than silently pretending the inventory is complete
      And aliases, interactions, prompts, responses, arguments, queues, and timeouts enforce their documented bounds

    @req-ac-fr-008 @req-ac-fr-009 @state-authority
    Scenario: Exactly one authority authors normalized state
      Given an exact pane and surface has an active provider lifecycle hook
      And weaker terminal observation disagrees with the hook
      When normalized state is published
      Then it is one of starting, working, needs_input, settled, failed, or unknown
      And the active bound hook is the sole state authority
      And each published transition advances that incarnation's activity version

    @req-ac-fr-010 @unknown
    Scenario: Missing authority reduces capability rather than inventing completion
      Given a supported provider is visible but lifecycle authority is insufficient
      When a caller gets or waits on that agent
      Then its state is unknown with explicit confidence
      And unknown does not satisfy settled or successful completion
      And prompt delivery is refused before bytes are written

  Rule: Starting an agent controls only the occupant of an explicitly prepared pane

    @req-ac-fr-011 @separation
    Scenario Outline: Agent start never changes layout
      Given the caller scopes agent.start.v1 to <pane-state>
      When start is requested
      Then <outcome>
      And no workspace, tab, split, move, or focus mutation is performed

      Examples:
        | pane-state | outcome |
        | an available interactive shell | the provider command may be submitted |
        | a pane running a command, editor, server, or agent | agent_pane_busy is returned before input |
        | a missing or unauthorized pane | a typed target or policy error is returned |

    @req-ac-fr-012 @req-ac-nfr-001 @input-validation
    Scenario Outline: Start arguments remain bounded data
      Given the start request contains <input>
      When validation runs
      Then <outcome>

      Examples:
        | input | outcome |
        | a supported provider and at most 64 safe tokens totaling at most 8 KiB | the host safely encodes the provider argv for the shell |
        | an unsupported provider | unsupported_agent_provider is returned without input |
        | a control character, sixty-fifth token, or over-8-KiB argv | invalid_agent_argument is returned without input |
        | a timeout below 3 seconds or above 300 seconds | invalid_agent_timeout is returned without input |

    @req-ac-fr-013 @req-ac-nfr-005 @start-identity
    Scenario Outline: Start settles only for the expected surface occupant
      Given a supported agent start was submitted to one pane incarnation
      When <condition>
      Then <outcome>
      And the pane remains visible for inspection on failure

      Examples:
        | condition | outcome |
        | the expected provider takes foreground ownership and authoritative identity arrives | success returns its opaque reference and snapshot |
        | the timeout expires before authoritative identity | agent_start_timeout is returned |
        | the pane closes or its surface or provider changes | an identity-specific failure is returned |

  Rule: Prompt and wait are atomic, occupant-safe, and finite

    @req-ac-fr-014 @input-safety
    Scenario: Prompt reuses the guarded terminal input service
      Given the reference resolves to a settled authoritative provider
      When a bounded prompt is submitted
      Then foreground and surface identity are checked immediately before every frame
      And bracketed-paste terminators are sanitized
      And text plus provider commit are serialized without interleaving

    @req-ac-fr-015 @req-ac-nfr-001 @prompt-delivery
    Scenario Outline: Invalid prompt state writes nothing
      Given the target is <state>
      When agent.prompt.v1 is requested with <delivery>
      Then <error> is returned before any bytes are written

      Examples:
        | state | delivery | error |
        | working | immediate | agent_busy |
        | unknown | whenReady | agent_authority_insufficient |
        | still starting | whenReady | agent_not_ready |
        | empty prompt | whenReady | invalid_agent_prompt |
        | prompt over 32 KiB | whenReady | invalid_agent_prompt |

    @req-ac-fr-015 @req-ac-fr-018 @req-ac-nfr-001 @req-ac-nfr-005 @queued-prompt
    Scenario: Busy agents accept a bounded causally attributed next turn
      Given an authoritative agent is working at activity version 20
      When a caller submits the default whenReady prompt with an optional wait
      Then the request enters that agent's bounded FIFO under the original principal scope deadline and cancellation
      And no prompt bytes are written until the active turn reaches a ready state
      And policy and exact identity are checked again at delivery
      And the event and activity baseline is captured immediately before that queued prompt is delivered
      And settlement of the earlier turn cannot satisfy the queued prompt's wait

    @req-ac-fr-016 @req-ac-fr-020 @race
    Scenario: Prompt and wait cannot miss a fast state transition
      Given the target is settled at activity version 12
      When agent.prompt.v1 with wait captures the event and identity baseline
      And the provider moves through working and settled before waiter registration finishes
      Then the setup-window events are replayed
      And the call succeeds only from an activity version greater than 12
      And the fast transition is observed exactly once

    @req-ac-fr-017 @stall
    Scenario Outline: An ineffective prompt stops waiting promptly
      Given prompt input was accepted from a non-working state
      And no agent activity transition follows
      When the effective deadline is <deadline>
      Then <outcome>

      Examples:
        | deadline | outcome |
        | more than 5 seconds | agent_prompt_stalled is returned at 5 seconds |
        | 5 seconds or less | the ordinary caller deadline error is returned |

    @req-ac-fr-018 @settled-states
    Scenario Outline: Prompt wait states remain semantically honest
      Given a prompt with no explicit until list
      When the same incarnation becomes <state>
      Then <outcome>

      Examples:
        | state | outcome |
        | settled | the call returns that snapshot |
        | needs_input | the call returns that snapshot with the bounded current interaction envelope when available and authorized |
        | failed | the call returns that failed snapshot |
        | unknown | the call continues or fails insufficient-authority, never success |

    @req-ac-fr-019 @req-ac-nfr-005 @finite-wait
    Scenario Outline: Standalone wait owns no continuing resource
      Given agent.wait.v1 pins one live reference
      When <condition>
      Then <outcome>
      And no handle or waiter remains after the reply

      Examples:
        | condition | outcome |
        | current state already matches and afterVersion is absent | it returns immediately |
        | a requested state occurs after afterVersion | it returns the new snapshot |
        | the timeout expires | a typed timeout is returned |
        | caller cancels | a typed cancellation is returned |
        | pane closes, surface changes, or provider is replaced | agent_not_running or agent_identity_changed is returned |

    @req-ac-nfr-002 @concurrency
    Scenario: Human-scale fleet waits do not serialize each other
      Given eight independent pane-scoped agent waits are running
      When each provider advances independently
      Then up to eight waits may settle concurrently in the agentWait lane
      And a ninth remains bounded by admission
      And serial agentImmediate list, get, or rename work and unrelated terminal or workspace lanes continue making progress

    @req-ac-nfr-003 @performance
    Scenario: State delivery stays off the UI thread and within budget
      Given a release-build synthetic provider publishes matching facts locally
      When the wait benchmark runs on the supported Apple Silicon baseline
      Then p95 publish-to-settlement latency is at most 250 milliseconds
      And hook decoding, process checks, waits, and provider I/O do not run on MainActor

  Rule: Progressive trust makes normal automation unattended without delegating Tenon's authority

    @req-ac-fr-022 @control-boundary
    Scenario: Structured provider response does not expose raw or Tenon-owned authority
      Given a provider displays a question or approval
      When an authorized caller receives the bounded current interaction envelope
      Then it may answer only through agent.respond.v1 against that exact pending interaction
      And no logical-key, Tenon-policy-answer, transcript or tool evidence, scope expansion, or lifecycle-subscription contract exists

    @req-ac-fr-028 @structured-response
    Scenario Outline: A response writes only to the exact live offered interaction
      Given an authoritative agent snapshot carries one current interaction reference
      When agent.respond.v1 submits <response>
      Then <outcome>

      Examples:
        | response | outcome |
        | one offered choice ID | the provider receives that structured answer and an optional atomic wait follows |
        | bounded freeform text when freeform is allowed | the provider receives that text and an optional atomic wait follows |
        | a non-offered choice or disallowed freeform text | validation fails before input |
        | a stale, replaced, ambiguous, or wrong-agent interaction | identity failure occurs and no input is written |

    @req-ac-fr-029 @standing-coordinate-trust
    Scenario Outline: Unchanged observation and coordination do not reprompt per call
      Given capability, scope, identity, and <trust state> are valid
      When the caller repeats <contract class>
      Then <confirmation behavior>
      And every call still enforces current scope, deadline, cancellation, admission, and identity

      Examples:
        | trust state | contract class | confirmation behavior |
        | ordinary eligibility | list, get, or wait | no per-call confirmation is requested |
        | existing standing consent | start, rename, or prompt | the existing decision is consumed without another prompt |

    @req-ac-fr-030 @standing-approval-trust
    Scenario Outline: Provider response trust is powerful but does not widen itself
      Given agent.respond.v1 authority is <source>
      When the caller answers exact current provider questions or approvals repeatedly within unchanged scope
      Then authorized calls do not reprompt
      And Tenon's own policy prompt and scope expansion remain impossible through that standing consent

      Examples:
        | source |
        | reviewed installation trust for an installed plugin |
        | explicit attended standing consent for a CLI or agent caller |

    @req-ac-fr-025 @fleet-example
    Scenario: The opt-in example coordinates three visible agents without becoming a broker
      Given the example's plugin principal declares only the seven agent contracts and required existing terminal contracts
      And reviewed installation trust covers those declared contracts
      When it prepares and names three panes, queues or prompts three supported agents concurrently, and answers one declared interaction
      Then every operation retains that plugin's scope, consent, deadline, and cancellation
      And each result retains its pane and agent reference
      And one bounded aggregate is published
      And unchanged operations run without repeated confirmation
      And the example is not installed into every user's palette by default

    @req-ac-nfr-008 @accessibility
    Scenario: Agent state reuses Tenon's existing human surfaces
      Given agent state appears in Agent Lens, attention, pane chrome, a notification, Launcher, or Palette
      When keyboard, pointer, VoiceOver, increased contrast, or narrow panes are used
      Then the owning surface retains native focus and interaction parity
      And status is not encoded by color alone
      And no Herdr-specific visual tokens or feature-local design system appears

    @req-ac-nfr-009 @installed @manual
    Scenario Outline: Real providers close the evidence boundary
      Given an installed Tenon app with current Claude and Codex integrations
      When the reviewer performs <flow>
      Then the complete behavior is observed end to end and recorded as a receipt

      Examples:
        | flow |
        | a fast turn that settles near waiter setup |
        | a queued turn whose causal baseline begins at actual delivery |
        | a question response using bounded freeform input |
        | a provider approval using reviewed standing trust without answering Tenon's policy UI |
        | an interrupted or failed turn |
        | pane closure and surface or provider replacement during wait |
        | aliases, eight concurrent waits, and a three-agent coordinator run without repeated prompts |

    @req-ac-nfr-007 @degradation
    Scenario: Missing or old integrations fail soft
      Given Claude or Codex lifecycle authority is unavailable or outdated
      When the public agent surface inspects that pane
      Then terminal and Agent Lens fallback behavior remain usable
      And public agent state is unknown or unavailable
      And no completion or prompt authority is inferred from screen silence

  Rule: One place knows how this person runs an agent

    @req-ac-fr-031 @req-ac-fr-032 @inventory
    Scenario: The offered agents are the installed ones, with this person's own options
      Given claude is installed on this machine and codex is not
      And this person's recent shell history runs claude with the same two options twice
      When a caller asks for the agent inventory
      Then exactly one agent is listed, named for a person to read
      And it carries those two argument tokens and a short description of the habit
      And no executable path and no other command from that history appears anywhere in the answer

    @req-ac-fr-033 @req-ac-fr-034 @composition
    Scenario: A composed command is the agent this person runs, opened on the work
      Given claude is installed and this person habitually passes --model opus
      When a caller composes a command for claude with a prompt
      Then the returned line runs that agent with --model opus followed by the prompt
      And every token is quoted so a prompt cannot become shell syntax
      And nothing has been started

    @req-ac-fr-033 @agent-unavailable
    Scenario: Asking for an agent this machine does not have fails typed
      Given codex is not installed on this machine
      When a caller composes a command for codex
      Then the call fails with agent-unavailable
      And no fallback agent is substituted

    @req-ac-fr-034 @refusal
    Scenario: A session identifier that could be an option never reaches a command line
      Given a caller passes a session identifier containing a leading dash or a space
      When it composes a command
      Then the call fails as invalid input before any line is built

    @req-ac-fr-035 @resume
    Scenario: The agent that recorded a session resumes it its own way
      Given a session recorded by codex
      When a caller composes a command for codex naming that session
      Then the line resumes through the codex subcommand with that session identifier
      And the result is not marked as a handoff

    @req-ac-fr-035 @handoff
    Scenario: Another agent is handed the transcript instead of a flag that does not exist
      Given a session recorded by Claude Code with a transcript on this machine
      When a caller composes a command for codex naming that session and its transcript path
      Then the line opens codex on a prompt naming that transcript path and the agent that wrote it
      And the prompt states the file's format and asks it to read the end first
      And the result is marked as a handoff

    @req-ac-fr-035 @handoff-refusal
    Scenario: A cross-agent continuation with no transcript is refused
      Given a session recorded by Claude Code whose transcript path is unknown
      When a caller composes a command for codex naming that session
      Then the call fails with agent-handoff-unresolved
      And no agent is started with no context

    @req-ac-fr-036 @one-composition
    Scenario Outline: Every caller runs the line the host composed
      Given claude is installed and this person habitually passes --model opus
      When <caller> starts an agent
      Then the command it runs is the composed line, unedited
      And those options are present in it

      Examples:
        | caller                            |
        | the task board                    |
        | the agent session list            |
        | the built-in launcher             |

  Rule: An agent is a caller in its own right, named by the pane it runs in

    @req-ac-fr-037 @mint
    Scenario: A call from inside an agent's pane carries the agent's own identity
      Given a pane whose agent has bound itself through its provider's lifecycle hook
      And that agent is still the pane's foreground process
      When a process inside that agent's own subtree calls Tenon's control socket
      Then the call is authorized as an agent principal named after that pane
      And two agents in two panes are two different principals

    @req-ac-fr-037 @no-self-assertion
    Scenario Outline: Nothing a caller can say makes it an agent
      Given a pane whose agent has bound itself through its provider's lifecycle hook
      When a caller that <origin> calls Tenon's control socket
      Then the call is authorized as the ordinary local CLI user

      Examples:
        | origin                                                          |
        | is not inside any agent's process subtree                       |
        | the kernel will not name a process for                          |
        | is inside a pane the host sees no agent occupying               |
        | descends from an agent that has since exited its pane           |

    @req-ac-fr-037 @narrower
    Scenario: The agent's identity carries less authority than the person's
      Given a pane running an agent that has been minted a principal
      Then everything that principal can invoke, the person can invoke too
      And it cannot fetch a remote address through Tenon
      And it can still open a pane, write to it, wait on it and read its scrollback

    @req-ac-fr-037 @confirmation
    Scenario: An open-class permission is re-asked when an agent is the caller
      Given a contract whose payload decides what it does and whose confirmation is by policy
      When a minted agent principal invokes it
      Then the confirmation required is always, not the caller's standing consent
      And the same contract invoked by the person keeps their standing consent
