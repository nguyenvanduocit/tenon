# language: en

@prd-TENON_PRD_008
Feature: Work with project files and changes without losing workspace context
  Operators need plugin-owned exploration to open bounded host-native content in the
  intended tab while preserving edits and filesystem authority.
  PRD: files-and-content.prd.md

  Rule: Files is a replaceable plugin over native declarative rows

    @req-fc-fr-001 @plugin
    Scenario: Files opens as the bundled plugin rather than a built-in browser
      Given the bundled file explorer is installed
      When the operator opens Files from the launcher
      Then the pane identifies the file-explorer plugin tree view
      And the host has no separate built-in Files content kind

    @req-fc-fr-002 @req-fc-fr-003 @root
    Scenario Outline: Each Files instance resolves its own root by precedence
      Given the Files pane belongs to a known workspace
      And <available source>
      When the plugin resolves its root
      Then it uses <expected root>
      And another Files instance keeps independent state

      Examples:
        | available source | expected root |
        | rootPath is configured | the configured path |
        | only a followed project root exists | the followed project root |
        | only the owning workspace exists | the workspace path |
        | no other source exists | the home fallback |

    @req-fc-fr-004 @req-fc-fr-033 @listing
    Scenario: Files consumes every directory-list v2 page
      Given a directory requires several bounded pages
      When Files renders it
      Then Files sends filesystem.directory.list.v2 until nextCursor is null
      And it never sends filesystem.directory.list.v1
      And the output carries the resolved absolute path

    @req-fc-fr-005 @tree
    Scenario: Async tree rendering is deterministic
      Given a directory contains subdirectories, a .git entry, and files
      When the current render generation completes
      Then directories appear before files
      And .git is absent
      And only expanded directories contribute descendants
      And a stale generation cannot replace current rows

    @req-fc-fr-006 @file-menu
    Scenario: A file row exposes the complete native menu
      Given a file row is visible
      When its context menu opens
      Then the actions are Open, Open to the Side, Open in Default App, Reveal in Finder, Copy Path, Rename, and Move to Trash
      And Move to Trash is destructive

    @req-fc-fr-007 @directory-menu
    Scenario: A directory row exposes directory operations
      Given a directory row is visible
      When its context menu opens
      Then it can open externally, reveal, copy, cd, create a file, create a folder, rename, or move to Trash

    @req-fc-fr-008 @req-fc-nfr-010 @inline-edit
    Scenario Outline: Inline editing settles exactly once
      Given a new or renamed row is editing
      When the operator <exit>
      Then the plugin receives <submission>
      And a following blur does not submit again

      Examples:
        | exit | submission |
        | presses Enter with a name | that name |
        | moves focus with a name | that name |
        | presses Escape | an empty cancellation |
        | leaves an empty field | an empty cancellation |

    @req-fc-fr-009 @trash
    Scenario: Trash is recoverable and clears stale tree state
      Given a selected or expanded path is visible
      When filesystem.path.trash.v1 succeeds
      Then Files clears expansion and selection for that path
      And it refreshes filesystem truth
      And it never invokes permanent deletion

    @req-fc-fr-012 @utilities
    Scenario Outline: Files utilities cross the matching public intent
      Given Files has the declared permission
      When the operator chooses <action>
      Then it sends <intent>
      And the host enforces that contract's effect and confirmation policy

      Examples:
        | action | intent |
        | Open in Default App | file.open.v1 |
        | Reveal in Finder | file.reveal.v1 |
        | Copy Path | clipboard.write.v1 |
        | cd Here | terminal.write.v1 |

    @req-fc-nfr-004 @req-fc-nfr-010 @rows
    Scenario: A declarative row retains native input and scanning behavior
      Given rows declare stable IDs, labels, details, disclosure, accessories, and paths
      When the host renders them lazily
      Then labels outrank secondary detail
      And accessories align in a bounded trailing column
      And path rows drag as file URLs without losing click or menu access

  Rule: Smart open stays in scope and reuses the correct pane

    @req-fc-fr-010 @req-fc-fr-013 @smart-open
    Scenario Outline: Every ordinary producer reaches the same placement service
      Given <producer> requests typed content in a valid scope
      When the host accepts it
      Then WorkspaceStore smart placement selects and focuses one target
      And the workspace tab count is unchanged

      Examples:
        | producer |
        | Files |
        | Git |
        | Agent Lens |
        | CLI |
        | an agent |

    @req-fc-fr-013 @scope
    Scenario Outline: Invocation scope selects one placement tab
      Given content open carries <scope>
      When placement resolves
      Then it acts only in <target>
      And no pane in another tab or workspace is reused

      Examples:
        | scope | target |
        | pane ID | that pane's tab |
        | tab ID | that tab |
        | workspace ID | that workspace's active tab |

    @req-fc-fr-014 @reuse
    Scenario Outline: Smart placement chooses the highest-priority candidate
      Given the tab has <candidates>
      When <content> opens
      Then <winner> receives it
      And no new pane is created

      Examples:
        | candidates | content | winner |
        | a focused file, another file, and empty pane | a file | the focused file pane |
        | an unfocused file and focused empty pane | a file | the file pane |
        | two empty panes with one focused | a diff | the focused empty pane |
        | the same plugin view and an empty pane | that plugin view | the existing plugin pane |

    @req-fc-fr-014 @split
    Scenario: No qualifying pane causes one horizontal split
      Given the tab has only a terminal and unrelated plugin pane
      When a file smart-opens
      Then one new file pane splits from the active pane
      And existing content survives

    @req-fc-fr-011 @open-side
    Scenario: Open to the Side bypasses reuse intentionally
      Given an editor already exists beside Files
      When the operator chooses Open to the Side
      Then Files requests a horizontal split and sets the new pane content
      And the existing editor keeps its file

  Rule: Native file panes choose a safe renderer and preserve edits

    @req-fc-fr-015 @renderer
    Scenario Outline: The final extension selects the renderer
      Given a path ends with <name>
      When FilePaneKind classifies it
      Then the host uses <renderer>

      Examples:
        | name | renderer |
        | photo.PNG | image |
        | page.html | local web |
        | main.swift | text |
        | .gitignore | text |
        | unknown.data | text |

    @req-fc-fr-016 @req-fc-nfr-002 @image
    Scenario Outline: Image preview settles off-main
      Given an image is <condition>
      When the pane loads it
      Then decoding runs away from MainActor
      And it shows <outcome>
      And stale work cannot publish for another path

      Examples:
        | condition | outcome |
        | readable | a scaled-to-fit image |
        | unreadable | Cannot read this image |

    @req-fc-fr-017 @html
    Scenario: Local HTML cannot silently become a browser
      Given HTML contains scripts, remote resources, and links
      When local preview loads
      Then JavaScript is disabled
      And website data is nonpersistent
      And file access is limited to the containing directory
      And remote resources and later navigation are blocked

    @req-fc-fr-018 @editor
    Scenario: Text opens as a native code editor
      Given valid bounded UTF-8 text
      When its pane loads
      Then STTextView shows line numbers and current-line highlight
      And native selection and find are available
      And unwrapped long lines scroll horizontally
      And Command-S targets this document

    @req-fc-fr-019 @syntax
    Scenario Outline: Highlighting degrades to readable text
      Given the file has <grammar>
      When syntax configures
      Then <result>

      Examples:
        | grammar | result |
        | a bundled grammar | tree-sitter colors captures |
        | TSX | the vendored grammar and inherited queries apply |
        | supported injections | embedded regions use their grammar |
        | no grammar | plain text remains readable |

    @req-fc-fr-020 @editor-bound
    Scenario Outline: Unsuitable text fails explicitly
      Given a file is <condition>
      When the editor reads it
      Then it reports <message>
      And no lossy or partial buffer is created

      Examples:
        | condition | message |
        | larger than 8 MB | the size limit |
        | invalid UTF-8 | the encoding failure |

    @req-fc-fr-021 @req-fc-nfr-011 @editor-state
    Scenario: Editor state follows pane and exact path
      Given a dirty editor has selection and scroll state
      When its view is destroyed and recreated
      Then the same pane and path recover scroll, selection, pending text, baseline, and conflict
      And a different path inherits none of it
      And the store holds at most 64 pane records

    @req-fc-fr-022 @header
    Scenario Outline: One highest-priority file state reaches pane chrome
      Given the document has <state>
      When header projection runs
      Then it shows <indicator>
      And lower-priority indicators are absent

      Examples:
        | state | indicator |
        | an error | the red error label |
        | a conflict without error | Changed on disk |
        | unsaved edits only | the amber dirty dot |
        | no issue | no file status |

    @req-fc-fr-023 @external-change
    Scenario Outline: Disk events never discard user work
      Given the editor is <buffer>
      And disk text <relation>
      When its watcher fires
      Then it <action>

      Examples:
        | buffer | relation | action |
        | clean | matches baseline | ignores the echo or no-op touch |
        | clean | differs from baseline | reloads while retaining place |
        | dirty | differs from baseline | keeps the buffer and marks conflict |

  Rule: Cwd and project root remain distinct facts

    @req-fc-fr-024 @req-fc-nfr-003 @project-root
    Scenario Outline: Automatic root follows the nearest Git marker
      Given cwd is inside <layout>
      When the host resolves PaneDirectory
      Then cwd is canonical
      And projectRoot is <root>

      Examples:
        | layout | root |
        | a plain checkout | the nearest checkout |
        | a linked worktree with a .git file | the worktree |
        | a submodule | the submodule |
        | nested repositories | the nearest repository |
        | no repository | null |

    @req-fc-fr-025 @event
    Scenario Outline: Panels reroot only when the project anchor changes
      Given a pane already reported its directories
      When cwd moves <movement>
      Then the host <publication>
      And Files and Git <result>

      Examples:
        | movement | publication | result |
        | inside one repository | records cwd without another root-change fact | keep their root |
        | into another worktree | publishes pane.cwd-changed | follow the new root |
        | outside repositories | publishes a null projectRoot | use workspace fallback |

    @req-fc-fr-026 @restore
    Scenario Outline: Restored cwd seeds a fresh shell fail-soft
      Given persisted cwd is <state>
      When the unmaterialized pane restores
      Then first view spawns a fresh shell in <directory>
      And no prior process or scrollback returns

      Examples:
        | state | directory |
        | an existing directory | that directory |
        | missing or invalid | the workspace path |

    @req-fc-fr-035 @pending @manual-pin
    Scenario: Retained manual root pin is implemented completely
      Given product retains manual project-root pin
      When the operator sets a directory for one pane
      Then it outranks automatic resolution
      And pane chrome can restore Use Automatic
      And the pin round-trips in the one workspace catalog

    @req-fc-fr-035 @pending @manual-pin-retirement
    Scenario: Retired manual root pin corrects stale claims
      Given product retires manual project-root pin
      When the decision is reviewed
      Then T-030 and derived docs stop claiming its UI and persisted field exist
      And the canonical non-goal records why

  Rule: The redundant Docs content kind retires without damaging unrelated saved state

    @req-fc-fr-036 @docs-retirement
    Scenario Outline: Legacy Docs references degrade to the nearest honest current state
      Given <legacy source> names Docs
      When the user-directed Docs-pane removal is applied
      Then <outcome>

      Examples:
        | legacy source | outcome |
        | launcher and bundled core-command inventory | Open Docs and docs.open.v1 are absent |
        | current slot and default-content types | no docs case or dedicated Docs renderer exists |
        | a saved workspace slot | it restores as empty instead of failing the workspace |
        | a preferences document | the unknown content value is ignored while accent, sidebar width, and schedule settings survive |
        | a recent-item record | the row is dropped rather than surfaced |

  Rule: Changes, Git, and diff share content without erasing semantics

    @req-fc-fr-027 @req-fc-nfr-012 @git-form
    Scenario: Git remains a plugin-owned repository form
      Given Git has status, commit, stage, merge, and history controls
      When it renders
      Then it uses form/body nodes and inline verbs
      And it is not forced into TreeRowItem for appearance alone

    @req-fc-fr-028 @changes
    Scenario Outline: Changes uses shared rows without inventing row menus
      Given staged and worktree changes exist
      When layout is <layout>
      Then Staged and Changes remain separate sections
      And shared TreeRowsView renders file rows
      And <result>
      And no file row publishes a menu

      Examples:
        | layout | result |
        | tree | directory rows collapse independently by section |
        | flat | each file shows once with path detail |

    @req-fc-fr-029 @req-fc-nfr-002 @diff-source
    Scenario Outline: Git diff resolves the correct sides off-main
      Given a file is <state>
      When native diff resolves it
      Then it compares <sides>
      And stale generations cannot publish

      Examples:
        | state | sides |
        | staged | HEAD and index |
        | modified | index or HEAD fallback and worktree |
        | untracked | empty and worktree |
        | deleted | previous and empty |
        | renamed | original previous path and current path |

    @req-fc-fr-030 @diff-state
    Scenario Outline: Diff presents an explicit state
      Given the model is <state>
      When the pane renders
      Then it shows <presentation>

      Examples:
        | state | presentation |
        | loading | skeleton and style picker |
        | binary | Binary file — no text diff |
        | failed or too complex | the bounded error |
        | unchanged | No changes |
        | changed | counts and Unified or Split rows |

    @req-fc-fr-031 @req-fc-nfr-003 @req-fc-nfr-004 @lazy-diff
    Scenario: Accepted large diff is projected once and rendered lazily
      Given text is within production complexity bounds
      When diff opens
      Then bounded Myers hunks compute once off-main
      And both row styles flatten once with line-number identities
      And LazyVStack builds visible rows
      And widest candidates establish horizontal extent

    @req-fc-fr-031 @req-fc-nfr-006 @diff-refusal
    Scenario Outline: Adversarial diff is refused before runaway allocation
      Given text exceeds <bound>
      When production projection begins
      Then it reports Diff is too complex to render safely
      And no unbounded trace or view tree is allocated

      Examples:
        | bound |
        | 5000 total lines |
        | 512 changed-span lines |

  Rule: Filesystem operations stay authorized, bounded, and atomic

    @req-fc-fr-032 @filesystem
    Scenario Outline: Filesystem work uses the matching bounded behavior
      Given the caller holds the required capability
      When it requests <operation>
      Then the provider uses <behavior>

      Examples:
        | operation | behavior |
        | directory list | bounded v2 pages |
        | text read | identity-bound pages or non-text failure |
        | exists | a boolean result |
        | single-page write | atomic replacement |
        | create | exclusive file or directory creation |
        | move | exclusive destination rename |
        | trash | recoverable Trash move |

    @req-fc-fr-033 @metadata
    Scenario Outline: Directory metadata is opt-in and honest
      Given includeMetadata is <setting>
      When v2 lists an entry
      Then it returns <fields>
      And metadata does not change isDirectory semantics

      Examples:
        | setting | fields |
        | absent or false | name and isDirectory |
        | true and readable | name, isDirectory, sizeBytes, and modifiedAt |
        | true and entry vanished | name, isDirectory, and null metadata |

    @req-fc-fr-033 @errno
    Scenario: Normal end of directory ignores unrelated errno
      Given loop work changed errno after a successful entry
      When the next readdir reaches ordinary end
      Then the page succeeds with a null nextCursor
      And no false POSIX error is reported

    @req-fc-nfr-005 @path-security
    Scenario Outline: Missing descendants bind without granting escape
      Given an absolute request is under an approved root
      And <path state>
      When policy binds and later uses it
      Then <result>

      Examples:
        | path state | result |
        | ancestors are absent | the deepest existing directory is pinned and the suffix is walked no-follow |
        | the suffix remains absent | reads list not-found and exists is false |
        | a symlink grows into the suffix | use fails closed |
        | the path is outside the grant | authorization is denied |

    @req-fc-fr-034 @req-fc-nfr-007 @staged-write
    Scenario: Multi-page write publishes only at commit
      Given an existing target requires several UTF-8 pages
      When each page continues the exact returned cursor
      Then intermediate bytes remain in a provider-owned staging file
      And the cursor binds target token and byte offset
      And final commit fsyncs and atomically renames over the target

    @req-fc-fr-034 @req-fc-nfr-006 @req-fc-nfr-011 @staging-bounds
    Scenario Outline: Staging has a deterministic terminal condition
      Given a provider owns an open staging
      When <condition>
      Then <settlement>

      Examples:
        | condition | settlement |
        | a fifth concurrent staging opens | capacity refuses it |
        | bytes exceed 1 MiB | the sequence fails and is discarded |
        | 300 seconds pass | next use reclaims it |
        | a forged or out-of-order cursor arrives | continuation fails closed |
        | provider generation retires | registry authority ends |
        | commit succeeds | registry ownership ends |

    @req-fc-nfr-009 @pending @version
    Scenario: Retained staged write receives a new major
      Given cursor and commit widened a formerly closed schema
      When staged write remains public
      Then it is filesystem.file.write.v2
      And inventories, manifests, callers, tests, and architecture docs use v2
      And filesystem.file.write.v1 is deleted

    @req-fc-nfr-002 @req-fc-nfr-006 @bounds
    Scenario Outline: Expensive work respects cancellation and bounds
      Given <operation> is in progress
      When its deadline, generation, cancellation, or size bound ends
      Then it stops without publishing partial or stale output

      Examples:
        | operation |
        | directory or file paging |
        | file or image load |
        | Git source resolution |
        | diff projection |
        | staged write |

    @req-fc-nfr-008 @boundary
    Scenario: Plugins receive no native file or terminal authority
      Given Files or Git needs host work
      When it crosses the boundary
      Then it uses bounded declarative values through intents contributions or events
      And receives no native view, editor model, terminal surface, or filesystem handle

    @req-fc-nfr-001 @design
    Scenario: Native content follows Tenon's design system
      Given a file, preview, Changes, diff, or row surface is visible
      When it renders in supported appearance and contrast settings
      Then it uses Tenon density, type, semantic colors, geometry, and components
      And no feature-local token overrides them

    @req-fc-nfr-010 @accessibility
    Scenario: Status remains understandable without color
      Given color is unavailable
      When dirty, conflict, error, added, or removed state appears
      Then text, signs, accessible names, or tooltips convey the same meaning

    @req-fc-nfr-012 @row-boundary
    Scenario: Shared rows follow interaction shape
      Given Files and Changes behave as selectable file-tree rows
      And Git behaves as a repository action form
      When renderers are selected
      Then Files and Changes share TreeRowsView
      And Git remains outside it
