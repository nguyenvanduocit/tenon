# language: en

@prd-TENON_PRD_015
Feature: Produce fast honest evidence for domain rules and real native interactions
  Engineers need every green claim to be reachable, falsifiable, and proportional to the boundary it proves.
  PRD: engineering-quality.prd.md

  Rule: A feature starts headless and crosses only the native boundaries it changes

    @req-enq-fr-001 @tdd
    Scenario: Delivery proves red before green and shell wiring
      Given a new product rule is expressible below the UI
      When the feature is developed
      Then its test first fails for the intended missing or wrong behavior
      And minimal core implementation makes it green
      And shell wiring follows without moving the rule into the view
      And the smallest valid adapter smoke completes before handoff

    @req-enq-fr-002 @functional-core
    Scenario Outline: Product decisions live in a typed testable owner
      Given a <rule> affects visible behavior
      When code ownership is reviewed
      Then the rule exists in typed core/service state and is headlessly testable
      And SwiftUI/AppKit projects or adapts the result rather than deciding it again

      Examples:
        | rule |
        | workspace or spatial mutation |
        | intent policy or schema |
        | plugin lifecycle |
        | layout and interaction transaction |

    @req-enq-fr-003 @layer-routing
    Scenario Outline: The lowest valid layer proves the rule
      Given the requirement is <truth>
      When its evidence seam is selected
      Then <layer>

      Examples:
        | truth | layer |
        | pure value/state transition | headless core test |
        | AppKit target-action, hit test, responder, menu, or drag adapter | hosted app-state test plus core rule |
        | real PTY, WebKit, FSEvent, relaunch, or OS boundary | real-service integration receipt |
        | built-app launch, Accessibility tree, global shortcut, or complete gesture | narrow XCUITest |
        | pixel geometry or theme appearance | controlled native render and visual review |
        | hitch or launch budget | benchmark, signpost, or Instruments receipt |

    @req-enq-fr-007 @hosted
    Scenario: Hosted native test proves an adapter postcondition
      Given a changed AppKit card/header/control is hosted with real view objects
      When a synthetic event or responder action crosses it
      Then target/action, hit region, focus/responder, menu, drag, or lifecycle postcondition changes as the user contract requires
      And the test does not merely inspect view construction

    @req-enq-fr-008 @black-box
    Scenario: XCUITest proves wiring through the built app
      Given a user path depends on launch, accessibility, shortcut, focus, menu, or pointer routing
      When XCUIAutomation performs the actual path
      Then a product state/count/order/focus/value postcondition changes
      And element existence alone is not considered success

    @req-enq-fr-009 @visual
    Scenario Outline: Layout evidence uses real pixels in meaningful variants
      Given a layout-sensitive view changes
      When native rendering covers <variant>
      Then the retained review shows typography, spacing, truncation, controls, and overflow in that variant
      And a tree-shape assertion is kept as structure evidence only

      Examples:
        | variant |
        | narrow and wide window |
        | light and dark appearance |
        | increased contrast or larger text |
        | localized or pseudolocalized content |

    @req-enq-fr-010 @accessibility-tree
    Scenario: Accessibility is inspected as semantics rather than pixels
      Given a control, modal, canvas, or attention state changes
      When accessibility verification runs
      Then labels, values, actions, hierarchy, traversal, focus, modality, and spoken meaning are inspected
      And screenshot appearance cannot substitute for that tree

    @req-enq-fr-011 @real-service
    Scenario Outline: A stub cannot certify a real external boundary
      Given a requirement depends on <service>
      When release evidence is selected
      Then at least one focused integration uses the real service under bounded fixtures

      Examples:
        | service |
        | Ghostty and PTY lifecycle |
        | WebKit data/process behavior |
        | filesystem watching |
        | JavaScriptCore plugin runtime |
        | persistence and relaunch |
        | native OS dialog or workspace operation |

    @req-enq-fr-012 @performance
    Scenario: Passing interaction tests do not imply a performance budget
      Given an interaction is functionally correct
      When launch, hitch, CPU, memory, or latency is claimed
      Then a signpost, benchmark, Instruments trace, or equivalent measured receipt supports it

    @req-enq-fr-013 @manual
    Scenario: Manual verification is finite and falsifiable
      Given automation cannot establish one native visual or assistive truth
      When a manual receipt is requested
      Then it names setup, exact observable truth, failure condition, operator, environment, and retained artifact
      And unrelated behavior is not delegated to an open-ended smoke pass

  Rule: Every test file is reachable by a documented runner

    @req-enq-fr-004 @manifest-parity
    Scenario: Package and Xcode manifests agree on current test targets
      Given Package.swift, project.yml, generated scheme, docs, and Tests directories are enumerated
      When target membership is compared
      Then the same three headless targets are reachable in SwiftPM and Xcode
      And Xcode-only integration/UI targets have explicit scheme membership and reasons

    @req-enq-fr-005 @coverage-reachability
    Scenario Outline: A test directory earns its runner status
      Given a directory under Tests <status>
      When evidence coverage is audited
      Then <outcome>

      Examples:
        | status | outcome |
        | is headless | swift test compiles and runs it |
        | needs a real GPU/PTY | TenonIntegrationTests and its Xcode command document the exclusion |
        | needs a logged-in Accessibility session | TenonUITests and its Xcode command document the exclusion |
        | appears in no runnable target | it is repaired, moved, or removed and cannot be cited as coverage |

    @req-enq-fr-006 @fast-bar
    Scenario: Focused success is followed by complete headless verification
      Given a developer used a focused test filter during red/green work
      When the change is handed off
      Then swift build succeeds
      And swift test runs all headless suites
      And the focused filter is recorded only as intermediate evidence

    @req-enq-fr-019 @receipt
    Scenario: Verification receipts are reproducible and do not rot by count
      Given build or test evidence is recorded
      When it enters durable documentation
      Then worktree or commit, exact command, destination, exit code, failing names, and exclusions are stated
      And no expected total test count is frozen as the contract

  Rule: Deterministic tests wait for facts and prove they can fail

    @req-enq-fr-014 @isolation
    Scenario Outline: A test owns its mutable environment
      Given a test uses <state>
      When the fixture starts and finishes or fails
      Then the state is isolated to that test and bounded cleanup is observable

      Examples:
        | state |
        | workspace and filesystem fixtures |
        | preferences or Application Support root |
        | plugin inventory and persistence |
        | clock, random seed, network, terminal, or WebKit choice |
        | launched app/process and result artifacts |

    @req-enq-fr-015 @req-enq-nfr-002 @fact-wait
    Scenario Outline: Asynchronous correctness follows an observable fact
      Given a test previously used <wait>
      When it is made deterministic
      Then <replacement>

      Examples:
        | wait | replacement |
        | a fixed sleep after debounce | inspect the one live timer then await a read fact |
        | a fixed number of polling turns | poll the terminal predicate until a finite deadline |
        | an immediate deallocation assertion | boundedly wait for the run loop to release the object |

    @req-enq-fr-016 @mutation
    Scenario: A critical green test demonstrates its sensitivity
      Given a test claims to protect one behavior
      When that behavior alone is deliberately removed or inverted
      Then the named test fails for its own assertion
      And the source is restored byte-identically

    @req-enq-fr-017 @flake
    Scenario: Retry cannot convert a nondeterministic gate to green
      Given a test passes alone and fails under load
      When it is diagnosed
      Then representative repeated runs expose the seam
      And the assertion is rewritten around a fact, ownership, or finite deadline
      And any retry remains diagnostic rather than acceptance policy

    @req-enq-nfr-004 @non-tautological
    Scenario: An expectation is independent of the implementation constant
      Given a test protects a positive gutter, bound, or semantic invariant
      When the implementation constant is mutated
      Then the expectation does not move with the same constant
      And the test turns red if the product rule is violated

    @req-enq-nfr-003 @diagnostics
    Scenario: A timeout identifies the missing fact and environment
      Given an asynchronous or GUI assertion reaches its finite deadline
      When failure is reported
      Then the broken rule, last actual state, expected state, test layer, environment, and retained artifact are named

  Rule: Build storage and compiler output remain bounded and shared

    @req-enq-fr-020 @cache-layout
    Scenario: SwiftPM and Xcode use two steady-state build trees
      Given development and install builds have completed
      When .build storage is inspected
      Then SwiftPM products live under the platform triple tree
      And all Xcode configurations share .build/xcode
      And dependencies and repositories have one shared checkout/cache

    @req-enq-fr-021 @shared-dependencies
    Scenario: Install does not resolve a private CLI dependency graph
      Given Xcode and the tenon-cli product are built
      When build commands resolve packages
      Then clonedSourcePackagesDirPath points at the shared .build cache
      And CLI uses the shared SwiftPM scratch rather than a separate checkout tree

    @req-enq-fr-022 @req-enq-nfr-006 @prune
    Scenario Outline: Cache pruning is recoverable and concurrency-safe
      Given the prune script runs while <state>
      When it inspects regenerable data
      Then <outcome>

      Examples:
        | state | outcome |
        | no build holds the tree | duplicate/intermediate junk is removed while products and incremental inputs remain |
        | another build owns the tree | pruning skips successfully and deletes nothing |
        | nothing is stale | the operation is idempotent and reports nothing to prune |

    @req-enq-fr-023 @warnings
    Scenario Outline: First-party diagnostics fail the build
      Given compilation emits <diagnostic>
      When local or CI build runs
      Then <result>

      Examples:
        | diagnostic | result |
        | a Swift or Xcode source warning | warnings-as-errors makes the build fail |
        | a known missing-debug-symbol warning from the pinned vendored archive | the exception is documented separately and does not disguise source warnings |

  Rule: Domain tags improve retrieval without pretending to prove completeness

    @req-enq-fr-024 @domain-file
    Scenario Outline: Source files carry a small product-domain statement
      Given a source file serves <scope>
      When its imports are inspected
      Then one or two declared domain tags appear above them
      And <review>

      Examples:
        | scope | review |
        | one product concept | the smallest true tag set is used |
        | more than two product concepts | the file is reviewed as a split candidate |

    @req-enq-fr-025 @domain-mark
    Scenario: Large-file sections remain retrievable
      Given a source file exceeds 400 lines and contains MARK sections
      When domain fitness scans it
      Then every MARK line carries its section domain

    @req-enq-fr-026 @domain-vocabulary
    Scenario Outline: Domain vocabulary is controlled and meaningful
      Given a domain entry is <condition>
      When docs/domains.md and source use are validated
      Then <outcome>

      Examples:
        | condition | outcome |
        | declared with a slug, product concept, and Excludes line | at least one source file must use it |
        | used only in source | missing declaration fails |
        | a code fact or invalid slug | declaration fails |

    @req-enq-fr-027 @edge-retrieval
    Scenario: Tag search is only the first retrieval step
      Given a domain tag search returns a starting file set
      When a symbol in that set is touched
      Then the symbol is searched source-wide for hidden Swift edges
      And the tag set is not cited as complete dependency proof

    @req-enq-fr-028 @domain-fitness
    Scenario Outline: Domain fitness fails loudly rather than vacuously
      Given the scanner encounters <defect>
      When the test runs
      Then it fails with the exact defect
      And the untagged budget is never raised to make it green

      Examples:
        | defect |
        | no source files found |
        | undeclared, unused, or invalid domain |
        | untagged source above the ratchet |
        | untagged MARK in a large file |

  Rule: Structure, accessibility, and localization remain product quality

    @req-enq-fr-029 @decomposition
    Scenario: A multi-responsibility coordinator splits without behavior drift
      Given domain/typed-phase boundaries reveal separable responsibilities
      When files and types are decomposed
      Then existing behavior tests remain unchanged and green
      And new types own one responsibility with no wider public package API
      And fitness paths and domain tags update together

    @req-enq-fr-030 @one-implementation
    Scenario Outline: Repeated semantics converge before limits diverge
      Given <duplicate> exists in several callers
      When quality review finds different limits or behavior
      Then one bounded typed implementation replaces the copies
      And focused tests cover that single owner

      Examples:
        | duplicate |
        | subprocess execution |
        | event routing gates |
        | contribution projection |
        | parser stages |

    @req-enq-fr-031 @req-enq-nfr-008 @no-color-only
    Scenario Outline: Meaning survives color and speech constraints
      Given a surface contains <content>
      When Differentiate Without Color or VoiceOver is used
      Then <outcome>

      Examples:
        | content | outcome |
        | attention state | a glyph and localized spoken state accompany semantic color |
        | icon-only action | localized accessibility label and help describe it |
        | decorative icon beside text | it is hidden from the accessibility tree |
        | stable UUID/grid rect | it stays in machine identifier/value placement and is not spoken as the label |

    @req-enq-fr-032 @localization
    Scenario: User-facing and AppKit-spoken strings enter the catalog
      Given the package declares its base language and String Catalog
      When a label, spoken state, accessibility value, menu title, or diagnostic is added
      Then it is localized through the supported string path
      And raw implementation literals do not bypass AppKit seams

    @req-enq-fr-033 @reduced-motion
    Scenario: Reduced motion preserves outcome and focus
      Given a transition or overlay normally animates
      When Reduce Motion is enabled
      Then unnecessary motion is removed or reduced
      And state, focus, dismissal, and action outcome remain identical

    @req-enq-nfr-005 @evidence-label
    Scenario: A receipt states exactly what its layer proves
      Given a change has headless shape, hosted interaction, black-box, pixel, accessibility, service, performance, or manual evidence
      When the evidence is summarized
      Then each receipt keeps its own label and limitation
      And one evidence type is not used to claim another truth

    @req-enq-nfr-009 @docs-current
    Scenario: Documentation agrees with runnable manifests and source
      Given commands, targets, paths, design metrics, or feature status are documented
      When the quality audit compares current manifests and source
      Then stale or unreachable prose is corrected or marked historical
      And it cannot remain the basis for a shipped claim

    @req-enq-nfr-010 @dirty-worktree
    Scenario: Refactoring preserves unrelated work and hidden symbol edges
      Given the worktree contains changes from another owner
      When a quality refactor proceeds
      Then only scoped files/hunks are edited
      And source-wide symbol edges and behavior receipts are rechecked
      And unrelated changes remain intact

    @req-enq-nfr-011 @quality-velocity
    Scenario: A quality gate must earn its developer cost
      Given a review step or test adds recurring time or ceremony
      When its continued value is evaluated
      Then it names the failure class it uniquely catches and its proportional cost
      And redundant, vacuous, or lower-signal ceremony is removed

  Rule: The complete native-interaction strategy remains an explicit planned deliverable

    @req-enq-fr-034 @req-enq-nfr-007 @req-enq-nfr-012 @pending @native-test-strategy
    Scenario: Representative native testing spikes produce one routing contract
      Given hosted context-menu/focus, black-box focus loop, automated accessibility audit, and controlled visual-regression spikes are available
      When each is repeated under recorded macOS, Xcode, runner, runtime, and load conditions
      Then fidelity, speed, determinism, diagnostics, maintenance, flake rate, and unsupported truths are compared
      And selected tools/runners/artifacts receive ownership and docs
      And rejected experimental code is removed
      And a feature author can select the lowest valid layer and required adapter receipt from one decision matrix

    @req-enq-fr-018 @pending @failure-artifacts
    Scenario: GUI failure retains enough state for remote diagnosis
      Given a hosted integration or XCUITest fails on its assigned runner
      When cleanup completes
      Then the applicable xcresult, activity trace, window screenshot, accessibility hierarchy, logs, launch environment, and state snapshot are retained

    @req-enq-nfr-001 @fast-loop
    Scenario: Slow evidence is scoped rather than imposed on every edit
      Given a feature changes only pure domain behavior during red/green iteration
      When the developer runs the default feedback loop
      Then the relevant headless test and build return without GUI startup
      And hosted, GUI, performance, or manual suites run only when their boundary is changed or at their scheduled gate

  Rule: A distributed build carries an identity macOS can remember, and nothing wider

    @req-enq-fr-035 @req-enq-fr-038 @signing
    Scenario: The published archive is what gets verified
      Given a release is cut from the current tree
      When the app, its embedded frameworks, and the bundled CLI are signed innermost-first with one Developer ID identity
      Then the signature carries the runtime flag rather than only the build setting that asked for it
      And the archive is unpacked again and that extracted copy is the one verified, stapled, and assessed
      And a signature produced with a recursive deep sign is refused as a distribution artifact

    @req-enq-fr-036 @signing @plugin-runtime
    Scenario: Plugin JavaScript keeps its compiler under a hardened runtime
      Given the distribution build hardens the runtime
      When a bundled plugin evaluates JavaScript in the host runtime
      Then the view it renders is identical to the same build running unhardened
      And the only runtime exception granted is the narrowest one that permits mapping JIT pages
      And no entitlement granting unsigned executable memory, disabling page protection, disabling library validation, permitting dyld environment variables, or allowing debugger attach is present

    @req-enq-fr-037 @signing @developer-experience
    Scenario: A local install needs no certificate
      Given several agents build in one shared working tree
      When one of them installs the app it just built
      Then the install completes with an ad-hoc signature and an unhardened runtime
      And no signing identity is required of it
      And the hardened runtime is not applied to that path, because library validation would refuse the app's own embedded frameworks

    @req-enq-fr-039 @release-metadata
    Scenario: Distribution metadata is derived rather than transcribed
      Given a signed archive has been produced
      When the package manager definition is written
      Then version, checksum, bundle identifier, and minimum macOS are read out of the built artifact
      And a definition pointing at an unreachable download is reported before it is published rather than by the first install

    @req-enq-fr-040 @req-enq-nfr-012 @build-inputs
    Scenario: A build input exists because setup makes it, not because a laptop has it
      Given a checkout on a machine that has never built this project
      When setup runs and the project is generated
      Then every source directory the project declares is present
      And each one was produced from a tracked or checksummed source rather than found already in place

    @req-enq-fr-040 @build-inputs
    Scenario: A verified download says nothing about what setup compiles itself
      Given the downloaded artifact is already installed and passes its checksums
      And a compiled build input is missing from that tree
      When setup runs
      Then it produces the missing input instead of reporting the installation current and returning
      And the input it produces is identical to the one the last release shipped

    @req-enq-fr-041 @script-surface
    Scenario: One door into the scripts
      Given a person who has never run anything in this checkout
      When they look at the repository root for something to run
      Then exactly one file there is executable, and running it with no argument lists every verb
      And each verb's one-line description is read out of that verb's own script rather than kept in a second list
      And a script that only another script calls is not offered as a verb

    @req-enq-fr-041 @script-surface
    Scenario: A verb that forgets to describe itself is caught before a person meets it
      Given a new script is added under scripts/
      When it carries no description or names a group the dispatcher does not print
      Then the fitness suite fails naming that script
      And the failure says the verb would otherwise be listed with an empty description

    @req-enq-fr-042 @release
    Scenario: One road out to a published release
      Given a version is ready to publish
      When the release is created
      Then exactly one file in the repository invoked the release-creating command
      And it ran on the machine that already holds the signing identity
      And no second automated road exists to publish the same tag, disabled or otherwise

    @req-enq-fr-043 @script-surface @documentation
    Scenario: A moved script cannot leave a stale command behind
      Given a script is renamed or moved into internal plumbing
      When the suite runs
      Then every script path named by an operator document, a script comment, or a workflow step resolves to a file that exists
      And the failure names the document and the path it names, because nothing else would have failed until someone typed the command

    @req-enq-nfr-013 @credentials
    Scenario: Signing credentials never enter the repository or the environment
      Given a release is cut locally or on a shared runner
      When the artifact is signed and submitted for notarization
      Then credentials are read from a stored keychain profile rather than from repository files, command arguments, or logged environment variables
      And a runner imports the identity into a keychain it creates for the job and destroys afterwards
