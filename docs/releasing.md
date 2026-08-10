# Releasing Tenon

How a build on this machine becomes something a stranger's Mac will run.

`install.sh` and this document solve different problems, and the difference is the whole
subject. `install.sh` puts a build on the machine that produced it: that machine already
trusts the bytes it just compiled, so an ad-hoc signature is enough and no certificate is
involved — which matters, because several agents build in this tree concurrently and none
of them should need one. A release goes to a machine that has never seen Tenon, where
Gatekeeper starts from the opposite assumption.

## What a signature buys, beyond Gatekeeper

An ad-hoc signature is a hash of the contents, so it changes with every build. macOS keys
two things to the code identity rather than to the path:

- **TCC consent.** Tenon runs agents in real PTYs, so a shell child reaching
  `~/Documents` prompts on Tenon's behalf. Under ad-hoc, the grant belongs to a signature
  that the next `./install.sh` replaces, and the prompt returns.
- **Keychain ACLs.** `SecretStore` writes `kSecClassGenericPassword` items
  (`Sources/TenonCore/SecretStore.swift:111`) whose access control names the app that
  created them.

A Developer ID signature is stable across builds, so both survive. This is the practical
reason to sign a build nobody is distributing.

## One-time setup

### 1. A Developer ID Application certificate

Distribution needs `Developer ID Application`. An `Apple Development` certificate cannot
sign for it — it only authorises running on registered machines.

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Nothing listed means the certificate is not in this keychain. It is created from the
Apple Developer account that will own the release, by an Account Holder or Admin. The
Team ID in parentheses is what ends up embedded in every build, and it is what Gatekeeper
shows the user — under an Organization account that is the organization's legal name, not
the product's.

### 2. Notarization credentials

Stored once in the keychain, never in the repository or the environment:

```sh
xcrun notarytool store-credentials tenon-notary \
  --apple-id <you@example.com> \
  --team-id <TEAMID> \
  --password <app-specific-password>
```

The password is an **app-specific password** from <https://appleid.apple.com>, not the
Apple ID password. `tenon-notary` is the profile name the scripts default to; override
with `NOTARY_PROFILE`.

## Cutting a release

```sh
./scripts/release.sh          # verify, build universal, sign, notarize, staple, package
./scripts/make-cask.sh        # write dist/tenon.rb from the artifact just built
```

`release.sh` refuses to continue when the generated Xcode project differs from the
committed one, and warns — without stopping — when the worktree is dirty, because a
release built from uncommitted work cannot be reproduced from its own commit.

It produces:

```
dist/Tenon-<version>-macos.zip          universal, signed, notarized, stapled
dist/Tenon-<version>-macos.zip.sha256
dist/SHA256SUMS
dist/tenon.rb                           the Homebrew cask (from make-cask.sh)
```

The final check extracts the zip and verifies *that* copy. A bundle verified in place
proves nothing about the file people receive — the stapled ticket has to survive the
round trip.

### Version

`MARKETING_VERSION` in `project.yml` is the source. Bump it, run `xcodegen generate`, and
commit the regenerated project before cutting.

### Publishing

```sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Tenon.app/Contents/Info.plist)
git tag "v$VERSION" && git push origin "v$VERSION"
gh release create "v$VERSION" dist/Tenon-*-macos.zip dist/SHA256SUMS \
  --title "Tenon $VERSION" --notes-file <(...)
```

Release notes distinguish implemented capability from roadmap. Tenon is pre-alpha and its
README says so; a release that reads as finished product is the one mistake this step can
make on its own.

## Homebrew

Tenon installs as a **cask** (a GUI application), from a **tap of our own** rather than
`homebrew/cask`. The central repository requires a project to be notable and stable, which
this is not yet, and a tap costs nothing to run:

```sh
gh repo create <owner>/homebrew-tap --public
TAP_REPO=~/projects/homebrew-tap ./scripts/make-cask.sh
cd ~/projects/homebrew-tap && git add Casks/tenon.rb && git commit -m "tenon <version>" && git push
```

Users then:

```sh
brew tap <owner>/tap
brew install --cask tenon
```

`make-cask.sh` reads version, checksum, bundle identifier and minimum macOS out of the
built artifact, so none of them can be copied wrong.

**The repository must be public first.** Homebrew fetches the release asset with no
credentials; a cask pointing into a private repository installs for nobody.
`make-cask.sh` checks this and says so rather than letting the first `brew install`
discover it.

The cask deliberately does not symlink `tenon-cli` into Homebrew's bin. Tenon installs the
CLI itself from **Settings ▸ CLI ▸ Install**, which owns its location and keeps it matched
to the running app; a second path to the same file lets a stale symlink outlive the bundle
it points into.

## Releasing from CI

`.github/workflows/release.yml` runs the same two scripts on a tag push, so the artifact
people install comes from a commit anyone can check out rather than from one laptop. Run
it once with **workflow_dispatch → dry run** before trusting a tag: a dry run proves the
build, the universal slices, the inside-out signature and the packaging — everything
except Apple's verdict.

The job imports the certificate into a keychain it creates and destroys, so nothing
persists on a shared runner. Five repository secrets:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | the Developer ID certificate **and private key**, exported as `.p12`, base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | the password set while exporting that `.p12` |
| `MACOS_SIGN_IDENTITY` | the identity string, e.g. `Developer ID Application: … (TEAMID)` |
| `NOTARY_APPLE_ID` | Apple ID for notarization |
| `NOTARY_TEAM_ID` | the same Team ID |
| `NOTARY_PASSWORD` | an app-specific password |

Exporting the `.p12`: Keychain Access → **My Certificates** → select the *Developer ID
Application* row → right-click → Export. It must be exported from the My Certificates
category, which is the one that includes the private key; exporting from Certificates
yields a public certificate that signs nothing.

```sh
base64 -i Certificates.p12 | pbcopy   # then paste into the secret
```

Rotate these when someone with access leaves. The certificate is the one credential here
that cannot be re-issued silently — revoking it invalidates signatures on builds already
distributed unless they were notarized and timestamped, which is why `release-sign.sh`
passes `--timestamp`.

## What was measured, so it is not re-derived

Recorded 2026-08-10 against `Tenon.app` built from this tree. These are receipts, not
reasoning — each was contradicted or confirmed by running it.

### Hardened Runtime and ad-hoc signatures are mutually exclusive here

`--options runtime` turns on **Library Validation**, which requires every loaded dylib to
share the process's Team ID. Tenon embeds three frameworks (`TenonCore`, `JSONSchema…`,
`OrderedCollections…`). An ad-hoc signature has no Team ID to share, so the app dies in
dyld before `main`:

```
Library not loaded: @rpath/OrderedCollections_….framework/…
  Reason: … not valid for use in process:
          mapping process and mapped file (non-platform) have different Team IDs
```

Signed with one Developer ID identity — app and all three frameworks — the same build
launches. **Consequence:** `install.sh` stays ad-hoc and unhardened; adding `--options
runtime` to its re-sign would break every local install. And `disable-library-validation`
is *not* needed: signing everything together satisfies the rule that entitlement waives.

### JavaScriptCore keeps its JIT, with one entitlement

`Tenon.entitlements` grants `com.apple.security.cs.allow-jit` and nothing else. Under
Developer ID + Hardened Runtime, the bundled Kanban plugin's JavaScript rendered a view
**byte-identical** to the unhardened control (`TENON_VIEW_SNAPSHOT`).

The escape entitlements form a widening cascade — `allow-jit` →
`allow-unsigned-executable-memory` → `disable-executable-page-protection` — and exactly
one may be set (`research-plugin-runtimes.md:994`). JavaScriptCore needs the narrowest.
`AppSigningFitnessTests` asserts the wider ones stay absent, so adding one turns the suite
red rather than passing review unnoticed.

### Hardened Runtime does not restrict `libproc`

This was PRD-016's open *signed-app feasibility* question: the Resource Monitor had only
ever run unhardened. The same probe binary, signed twice, differing only in the runtime
flag:

| | `listpids` | `PROC_PIDTBSDINFO` | `EPERM` | `PROC_PIDTASKINFO` | `proc_pidpath` |
|---|---|---|---|---|---|
| unhardened | 638 | 419 | 219 | 419 | 635 |
| hardened | 638 | 419 | 219 | 419 | 635 |

Identical. The 219 refusals are processes owned by root or other users, present in both.
Process telemetry survives distribution unchanged.

### Build settings are not the artifact

`ENABLE_HARDENED_RUNTIME` in `project.yml` applies only when the build actually signs.
`install.sh` passes `CODE_SIGNING_REQUIRED=NO`, under which `xcodebuild` runs no
`codesign` step at all — the `flags=0x2(adhoc)` such a build carries comes from the
linker. `scripts/release-sign.sh` is therefore the authority for what a distributed
artifact is signed with, and it verifies the flag word on the bundle rather than trusting
the setting that asked for it.

## Troubleshooting

**`different Team IDs` at launch** — the app and its embedded frameworks were signed by
different identities, or one is still ad-hoc. Re-run `release-sign.sh`, which signs all of
them inside-out.

**Notarization rejected** — `xcrun notarytool log <submission-id> --keychain-profile
tenon-notary` gives the per-file reason. The usual causes are a nested binary that was
never signed, a missing `--options runtime`, or `com.apple.security.get-task-allow` left
in the entitlements.

**`brew install` 404s** — the repository or the release asset is not public.

**`--deep` while signing** — not accepted for distribution: it re-signs nested code with
the outer entitlements and skips anything it does not recognise as code. `--deep` on
`codesign --verify` is a different flag with the opposite meaning ("check nested code
too") and is correct there.

## Related

- [`operations.md`](operations.md) — the release checklist this implements, plus runtime
  troubleshooting
- [`development.md`](development.md) — local build and layout
- PRD [`engineering-quality`](prds/engineering-quality.prd.md) — the owning requirements
- PRD [`diagnostics-and-resource-monitor`](prds/diagnostics-and-resource-monitor.prd.md) —
  the signed-app telemetry question closed above
