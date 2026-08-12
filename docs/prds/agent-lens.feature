# language: en

@prd-TENON_PRD_012
Feature: Supervise agent sessions through bounded checkable evidence
  Operators need a semantic account of live agent work without losing the exact terminal.
  PRD: agent-lens.prd.md

  Rule: Historical sessions and the live Lens remain distinct products

    @req-al-fr-001 @history-plugin
    Scenario Outline: Claude session history is bounded and resumable
      Given the history plugin resolves a project's Claude transcript directory
      When the directory <state>
      Then <result>

      Examples:
        | state | result |
        | has more records than the configured limit | only newest metadata-rich sessions are shown |
        | contains invalid UTF-8 in an older record | byte-mode scanning can still find later titles |
        | has no transcripts | a native empty state appears |
        | has a selected session | the terminal receives claude --resume with that exact ID |

  Rule: Lens presentation never replaces the living terminal

    @req-al-fr-002 @req-al-fr-032 @surface
    Scenario: Renderer changes preserve one terminal incarnation
      Given an agent is attached to a terminal pane
      When the person switches among Session, Terminal, and Split
      Then the same terminal surface, PTY, process, input, and scrollback remain
      And no Lens stream is cancelled merely by the mode change

    @req-al-fr-003 @detection
    Scenario Outline: Detection offers a view without taking it
      Given the person selected <mode>
      When an agent is first detected or its root session reattaches
      Then the mode control appears
      And <mode> remains selected

      Examples:
        | mode |
        | Terminal |
        | Session |
        | Split |

    @req-al-fr-004 @req-al-nfr-001 @header
    Scenario: Modes use the pane's one native header
      Given Lens capability is visible
      When pane chrome renders
      Then the provider/status and Session, Terminal, Split choice share the existing header
      And Terminal remains keyboard-accessible as the exact escape hatch

    @req-al-fr-005 @narrative
    Scenario: One timeline orders conversation and execution evidence together
      Given a session contains prose, tools, subagents, a question, diagnostics, and instructions
      When Session renders
      Then conversation and execution facts appear in evidence order
      And system, developer, project, and skill instructions remain collapsed in the inspector

    @req-al-fr-006 @attention
    Scenario: Judgment is elevated without discarding grouped evidence
      Given a question is pending among repeated skill reads and adjacent subagent controls
      When the summary and narrative render
      Then the pending judgment is prominent
      And related execution can group while every source fact remains inspectable

  Rule: Prose is readable, bounded, and linked only to real evidence

    @req-al-fr-007 @markdown
    Scenario Outline: Agent Markdown renders its emitted block vocabulary
      Given prose contains <shape>
      When Agent Lens renders it
      Then semantic native text represents that shape without literal markup noise

      Examples:
        | shape |
        | headings and paragraphs |
        | nested ordered and task lists |
        | fenced or unterminated streaming code |
        | blockquotes and thematic rules |
        | pipe tables |
        | bold, italic, code, links, and strikethrough |

    @req-al-fr-008 @responsive
    Scenario Outline: Dense content adapts without horizontal reading traps
      Given <content>
      When it renders in <width>
      Then <outcome>

      Examples:
        | content | width | outcome |
        | a fitting table | wide | columns align naturally |
        | the same table | narrow | each row reflows to labeled fields |
        | an overlong message | any | bounded source renders with a Show all path |

    @req-al-fr-009 @file-link
    Scenario Outline: Only contained resolving citations become file links
      Given an inline span names <value>
      When it resolves against the workspace
      Then <outcome>

      Examples:
        | value | outcome |
        | an existing relative source path with an optional line suffix | a file link is created |
        | an existing absolute file in the workspace | a file link is created |
        | a missing file | plain text remains |
        | a path escaping the workspace | plain text remains |
        | a command, flag, URL, directory, or bare word | plain text remains |

    @req-al-fr-010 @req-al-nfr-008 @file-link
    Scenario: Activating a cited file uses same-owner placement
      Given a valid file link appears in Lens prose
      When the person activates it
      Then the typed workspace service smart-opens that file
      And Lens does not send workspace.content.open.v1 to itself

  Rule: Provider evidence binds to the current root session or degrades explicitly

    @req-al-fr-011 @capability
    Scenario Outline: Capability claims follow authoritative evidence
      Given a terminal has <evidence>
      When Lens discovery settles
      Then <result>

      Examples:
        | evidence | result |
        | an identified Claude or Codex process plus authoritative binding | supported semantic capability is announced |
        | only a process match | process-only capability is reported |
        | an unsupported provider | no invented semantic capability appears |

    @req-al-fr-012 @identity
    Scenario: Attachment identity is more than a pane or process name
      Given a root provider session is accepted
      When its identity is recorded
      Then it includes pane ID, surface incarnation, foreground process group, root session ID, and canonical transcript where applicable

    @req-al-fr-013 @req-al-nfr-003 @ingress
    Scenario Outline: Hook ingress refuses unauthenticated or oversized events
      Given a hook post is <condition>
      When the loopback listener admits it
      Then <outcome>

      Examples:
        | condition | outcome |
        | authenticated under the app bearer and bounds | it may decode into an event |
        | missing or using the wrong bearer | it is refused before host mutation |
        | beyond header or body limits | it is refused before full decoding |
        | sent to a non-loopback interface | no listener accepts it |

    @req-al-fr-014 @codex
    Scenario Outline: Codex root identity cannot be stolen by a nearby transcript
      Given a Codex fact is <condition>
      When the registry evaluates it
      Then <outcome>

      Examples:
        | condition | outcome |
        | a child fact carrying agent_id | it cannot establish or replace the root |
        | from an old surface incarnation | it is rejected |
        | from the wrong foreground process group | it is rejected |
        | for a symlink or non-user file outside active sessions root | it is rejected |
        | a newer authoritative SessionStart | it may replace the previous root |

    @req-al-fr-015 @claude
    Scenario: Claude hook and transcript accounts keep their distinct authority
      Given Claude is waiting on a question before writing its transcript turn
      When hook and transcript evidence reconcile
      Then the hook supplies live tool/question lifecycle
      And transcript prose and byte-anchored evidence remain the record
      And Stop prose is not duplicated as an unanchored claim

    @req-al-fr-016 @reconciliation
    Scenario Outline: One provider tool ID remains one run
      Given hook and transcript facts share a tool_use_id
      When <late fact> arrives
      Then <result>

      Examples:
        | late fact | result |
        | a start after completion | the completed run is not reopened |
        | transcript evidence after hook completion | the run gains the stronger source anchor without duplication |
        | a record of an already answered question | the question is not raised again |

    @req-al-fr-017 @taxonomy
    Scenario Outline: Claude tools read as human work rather than raw JSON
      Given Claude reports <tool>
      When it is projected
      Then its kind and summary describe <meaning>

      Examples:
        | tool | meaning |
        | Bash | a command and result |
        | Read, Write, or Edit | file work |
        | Grep or Glob | search |
        | Task | subagent work |
        | WebFetch or WebSearch | web work |
        | TodoWrite | plan work |
        | Skill | skill use |
        | AskUserQuestion | pending or answered judgment |

    @req-al-fr-018 @installation
    Scenario: Missing Claude hook support is actionable
      Given hook installation failed or no pane hook has arrived
      When Lens shows provider capability
      Then it does not claim live questions or lifecycle
      And the failure includes a retry action from the same surface

  Rule: Streams and reduction preserve completeness or say where it broke

    @req-al-fr-019 @req-al-nfr-002 @stream
    Scenario: Semantic overflow terminates instead of silently dropping history
      Given a transcript or native source fills its 1024-event buffer
      When another semantic event cannot be retained
      Then the source terminates with overflow
      And the coordinator publishes an explicit incomplete-projection diagnostic

    @req-al-fr-020 @req-al-nfr-005 @req-al-nfr-006 @reducer
    Scenario: The reducer produces a replayable evidence snapshot
      Given the same ordered normalized events
      When they are reduced
      Then immutable items retain authority, source, anchor, fingerprint, capture time, freshness, and status
      And collection eviction follows the same documented bounds

    @req-al-fr-036 @stream
    Scenario: A bounded window opens at a record that stands on its own
      Given a transcript larger than the initial window
      And the window falls between a tool call and the result that answers it
      When the source attaches
      Then the stranded result opens nothing and projects no tool
      And reading resumes at the first record that carries its own meaning

    @req-al-fr-037 @req-al-nfr-006 @reducer
    Scenario: A shortened history says where it begins
      Given history was bounded by the initial window or trimmed in memory
      When Session draws the conversation
      Then the snapshot carries evidence naming the transcript and the byte it begins at
      And the notice states that boundary rather than only that one exists

    @req-al-fr-038 @req-al-fr-031 @timeline
    Scenario: A reading says what it is doing while it runs
      Given a reading of this session has started
      When the agent CLI announces its session and begins writing the reply
      Then the pane reports that work instead of an unchanging spinner
      And a superseded or cancelled run reports nothing

    @req-al-fr-038 @req-al-nfr-002 @timeline
    Scenario: A reading expires on silence rather than on duration
      Given a reading is still writing after the old fixed deadline would have killed it
      When it keeps producing output
      Then it is allowed to finish
      But a run that produces nothing for the silence bound is stopped and says so
      And a run that never stops talking is stopped at the ceiling and says that instead

    @req-al-fr-044 @req-al-fr-038 @timeline
    Scenario: A busy API is waited out, not blamed on the reading
      Given a reading is running and the API returns a retryable error
      When the agent CLI announces that it is backing off before its next attempt
      Then the pane says the API is busy and which attempt this is
      And the quiet that follows the announcement does not expire the run
      But a run that never speaks again is still stopped at the ceiling

    @req-al-fr-049 @req-al-fr-038 @timeline
    Scenario: The wait before the model answers is not read as a hang
      Given a reading has handed its request to the API and the reply has not started
      When the agent CLI publishes no frame at all for longer than the silence bound
      Then the run is not stopped for silence, because nothing it emits could have said otherwise
      And the pane says it is waiting for the model rather than claiming to be reading
      But a run that never answers at all is still stopped at the ceiling

    @req-al-fr-049 @req-al-fr-038 @timeline
    Scenario: Once the reply is arriving the deadline is in charge again
      Given a reading has received the first frame of its reply
      When it then goes quiet for the silence bound with nothing accounting for it
      Then the run is stopped and reports the silence

    @req-al-fr-040 @req-al-fr-030 @timeline
    Scenario: A reading keeps the options it was started with
      Given the reader, model, span and lens have been chosen on the invitation
      When a reading is requested and different options are chosen while it runs
      Then the run is taken with the options it started with
      And the finished reading states those options rather than the pending ones

    @req-al-fr-041 @req-al-fr-031 @timeline
    Scenario Outline: Each reader is offered and invoked on its own terms
      Given the machine's installed agent CLIs have been scanned
      Then only those CLIs are offered as readers
      When "<provider>" is chosen
      Then the run is spelled "<invocation>"
      And model choice is limited to "<models>"
      And silence is treated as "<silence>"

      Examples:
        | provider | invocation                                 | models                       | silence          |
        | claude   | one-shot print with a streaming reply      | the CLI's documented aliases | evidence of death |
        | codex    | headless exec reading its prompt from stdin| the CLI's own configured model | nothing at all  |

    @req-al-fr-042 @req-al-fr-025 @timeline
    Scenario: A narrower span is a different question
      Given a session with more facts than the narrow span admits
      When a reading is requested over recent work rather than the whole session
      Then the digest keeps the newest facts, says it was cut, and fingerprints differently
      And no span takes the session below the six-fact bar that refuses a synthesis

    @req-al-fr-043 @req-al-fr-028 @timeline
    Scenario: A different lens changes the question, never the checks
      Given the reading can be asked for milestones, problems or decisions
      When each lens builds its instruction
      Then every one carries the identical schema, anchor, partition and settled rules
      And no two lenses ask for the same thing

    @req-al-fr-039 @req-al-fr-012 @discovery
    Scenario: A session is known before its provider writes the transcript
      Given a root hook declares the transcript this terminal's session will write
      When the provider has not created that file yet
      Then the pane binds the declared transcript and names the session it is watching
      And the wait for the first byte is reported as nothing at all

    @req-al-nfr-011 @discovery
    Scenario: A path trusted before it existed cannot deliver another file's bytes
      Given a session is bound to a transcript path that nothing occupies yet
      When a symlink to another transcript appears at that path
      Then its bytes are refused because the path is no longer a regular file of this user
      And the genuine transcript is read from its beginning once it is written there

    @req-al-nfr-009 @degradation
    Scenario Outline: Source failure has an honest semantic outcome
      Given the source is <failure>
      When ingestion encounters it
      Then <outcome>

      Examples:
        | failure | outcome |
        | an unknown optional protocol method | it is safely ignored |
        | malformed, missing, rotated, or oversized evidence | a named diagnostic explains the gap |
        | replaced transcript | history reloads with degraded freshness |

  Rule: Input is serialized and guarded against the current foreground process

    @req-al-fr-021 @input
    Scenario: Text submission cannot interleave or inject a paste terminator
      Given two drafts target the same attached foreground process
      When they are submitted concurrently
      Then one actor drains them FIFO
      And each sanitized text travels in one bracketed-paste frame
      And Return travels separately only after identity is checked again

    @req-al-fr-022 @option
    Scenario Outline: Option answers match the provider terminal grammar
      Given a pending interaction belongs to <provider>
      When the person selects an option
      Then <bytes> are sent once
      And repeat activation stays disabled until the interaction advances

      Examples:
        | provider | bytes |
        | Claude | the option hotkey plus guarded Return |
        | Codex | only the committing hotkey |

    @req-al-fr-023 @recovery
    Scenario: Foreground identity change prevents trailing input
      Given the foreground process changes after the paste frame
      When Lens prepares the Return frame
      Then Return is withheld
      And the submission fails visibly
      And the pane returns to Terminal for exact recovery

  Rule: AI Timeline interprets evidence without owning checkable facts

    @req-al-fr-024 @account
    Scenario: Chat and Timeline do not alter attachment or renderer mode
      Given an attached pane is showing Split
      When the person changes from Chat to Timeline
      Then the same session and terminal remain attached
      And Split remains selected

    @req-al-fr-025 @req-al-nfr-002 @timeline
    Scenario Outline: Timeline avoids a model call when no reading is useful
      Given the session is <state>
      When the person requests Timeline
      Then <outcome>

      Examples:
        | state | outcome |
        | unattached or empty | an honest empty state appears without synthesis |
        | fewer than six digest facts | a too-short state appears without synthesis |
        | sufficiently evidenced | at most 320 facts and 96 KiB enter synthesis |

    @req-al-fr-035 @req-al-fr-025 @timeline
    Scenario: A session that grows past the bar becomes readable where it stands
      Given Timeline is open on a pane whose session is still attaching
      Then an honest empty state appears without synthesis
      When the session reaches six digest facts
      Then Timeline offers the reading, with no re-attachment
      And no reading has been requested on the person's behalf

    @req-al-fr-026 @timeline
    Scenario: A raw event relabeling is refused
      Given the model returns one milestone per digest fact
      When the Timeline validator checks compression and bounds
      Then the result is refused rather than rendered
      And no partial milestone UI appears

    @req-al-fr-027 @anchors
    Scenario Outline: Checkable milestone metadata comes from the host
      Given a draft milestone cites <anchors>
      When validation succeeds
      Then <outcome>

      Examples:
        | anchors | outcome |
        | existing digest IDs | labels and time span are derived from those facts |
        | an invented ID | the whole reading is refused |

    @req-al-fr-028 @truth
    Scenario Outline: Milestones cannot double-count or falsely settle work
      Given a draft <defect>
      When the host validates it
      Then the reading is refused

      Examples:
        | defect |
        | shares one anchor between milestones |
        | uses fewer than three facts per milestone |
        | claims settled over a still-running tool |
        | claims settled over a pending question |
        | adds a session-level completion verdict |

    @req-al-fr-029 @states
    Scenario Outline: Timeline state never takes Chat away
      Given a valid prior reading exists
      When generation is <state>
      Then Chat remains usable
      And <reading outcome>

      Examples:
        | state | reading outcome |
        | loading | the prior reading remains until replacement |
        | cancelled | the prior reading remains |
        | failed | the failure and retry are visible beside the prior reading |
        | made stale by new facts | the prior reading stays marked stale |

    @req-al-fr-030 @lifecycle
    Scenario: A late older run cannot overwrite a newer request
      Given two Timeline refreshes finish out of order
      When the older result arrives last
      Then only the newest requested run may publish
      And cancelling advances the ledger so its in-flight result cannot land

    @req-al-fr-031 @req-al-nfr-007 @synthesis
    Scenario: Synthesis is a bounded headless task
      Given a valid digest is ready
      When the person's installed agent CLI synthesizes it
      Then it runs one noninteractive turn in scratch space
      And output and process lifetime are bounded
      And timeout terminates the process and reports failure

    @req-al-fr-032 @req-al-nfr-004 @lifecycle
    Scenario Outline: Lens resources end only at their ownership boundary
      Given an attached Lens has streams and a Timeline run
      When <transition> occurs
      Then <outcome>

      Examples:
        | transition | outcome |
        | the pane hides, loses focus, switches tabs, or changes mode | work remains attached |
        | the slot closes | pane-owned streams, input, and synthesis cancel exactly once |
        | the app stops | all Lens work, bindings, and hook ingress close before exit |

  Rule: Fleet supervision uses the same terminal platform and requires live proof

    @req-al-fr-033 @req-al-nfr-008 @fleet
    Scenario: Fleet launch is not an Agent Lens command API
      Given an automation launches parallel agents
      When their work is observed in separate panes
      Then tenon.agents.run composes terminal open, wait, and scrollback intents
      And Agent Lens only projects each pane's evidence

    @req-al-fr-034 @req-al-nfr-010 @pending @manual
    Scenario Outline: The installed workflow proves assembled behavior
      Given a supported real provider runs in an installed Tenon app
      When the reviewer performs <flow>
      Then the end-to-end outcome matches this PRD without hidden component assumptions

      Examples:
        | flow |
        | a very fast fleet command followed by wait and aggregation |
        | a live Claude AskUserQuestion answered from Session |
        | a file citation activated from selectable Markdown text |
        | agent detection and reattachment while the chosen renderer is preserved |

  Rule: Native presentation and evidence privacy remain cross-cutting constraints

    @req-al-nfr-001 @accessibility
    Scenario: Lens states remain operable without color or a wide pane
      Given keyboard, VoiceOver, increased contrast, or a narrow pane is in use
      When Session or Timeline shows status, controls, and evidence
      Then every action has a native label and focus path
      And state is conveyed by text or symbol as well as semantic color
      And content reflows without horizontal reading

    @req-al-nfr-003 @privacy
    Scenario: One pane or plugin cannot inspect another pane's private agent evidence
      Given hook and transcript facts are bound to one surface identity
      When an unrelated pane or plugin asks for them
      Then no public intent or plugin path exposes the evidence
      And identity admission refuses cross-pane facts

    @req-al-nfr-006 @authority
    Scenario: Reported and observed facts remain distinguishable
      Given a provider reports a successful edit while the host observes a conflicting file state
      When Lens presents the evidence
      Then each fact keeps its authority and freshness
      And provider prose is not relabeled as direct observation

  Rule: A session that already happened is read by the same lens, and holds no PTY until resumed

    @req-al-fr-045 @security
    Scenario: A recorded session opens a pane that reads it with Agent Lens itself
      Given a plugin lists a session it recorded and names its transcript
      When it opens that reference through workspace.content.open.v1
      Then the host resolves symlinks on both the path and the allowed provider roots
      And a transcript under one of those roots opens a pane reading it with the chat spine, the evidence inspector, and the Timeline
      And the pane that already reads a recorded session takes the next one rather than opening another

    @req-al-fr-045 @security
    Scenario: A named transcript the host cannot vouch for opens nothing
      Given a plugin names a path that resolves outside every allowed provider root
      When it opens that reference through workspace.content.open.v1
      Then the refusal is typed invalid input
      And no pane opens and no partial reference is built

    @req-al-fr-046
    Scenario: A recorded pane cannot say anything to anyone
      Given a pane is reading a session that has already finished
      Then it holds no terminal surface and starts no discovery
      And it draws no composer
      And a request left pending when the session ended is still shown with no control to answer it

    @req-al-fr-047
    Scenario: Resuming converts the pane that is reading the session
      Given a recorded pane whose agent is installed on this machine
      When the operator presses + Resume
      Then the command line is composed by the one typed agent composer, carrying the options this person runs that agent with
      And that same pane becomes a live terminal continuing the same session

    @req-al-fr-047
    Scenario: An unavailable agent states its reason before it is pressed
      Given a recorded pane whose recording agent is not installed on this machine
      Then the pane states why the session cannot be continued here
      And the reading stays available

    @req-al-fr-048
    Scenario: A recorded pane survives a restart, and gives up its content when the transcript does not
      Given a recorded pane is captured into the workspace catalog
      When the workspace is restored and the transcript is still readable
      Then the pane comes back carrying provider, session, transcript, and title
      But when the transcript is gone, its provider is unrecognised, or its stored reference is malformed
      Then the pane comes back empty, keeping its place in the layout
