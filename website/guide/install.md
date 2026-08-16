# Install

Tenon is a universal macOS app. It needs **macOS 14 or later** and nothing else —
no JavaScript toolchain, no runtime to install first.

## Download a release

Get the newest build from
[Releases](https://github.com/nguyenvanduocit/tenon/releases).

::: danger Extract in Finder or with `ditto`, never with `unzip`
Extracting with `unzip` can produce an app macOS refuses to open.

The archive stores the extended attributes that Tenon's code signature seals
over. Finder restores them, and so does `ditto`. Info-ZIP's `unzip` cannot, so
it writes them out as 735 stray `._*` files *inside* the bundle instead, and
Gatekeeper then rejects the app with **"a sealed resource is missing or
invalid"**. That reads like a corrupt download. It is a corrupt extraction.
:::

```sh
ditto -x -k Tenon-*-macos.zip .        # or just double-click it in Finder
mv Tenon.app /Applications
```

### Check what you downloaded

The build is signed with a Developer ID certificate, hardened, notarized and
stapled, so a machine that has never seen Tenon verifies it offline — with no
right-click-to-open dance. Confirm that for yourself:

```sh
shasum -a 256 Tenon-*-macos.zip          # compare with SHA256SUMS on the release
spctl --assess -vv /Applications/Tenon.app
```

The second command should say `accepted` and `source=Notarized Developer ID`.

::: warning Releases are marked pre-release
That is deliberate while Tenon is pre-alpha: interfaces still change between
builds. Read the [changelog](https://github.com/nguyenvanduocit/tenon/blob/main/CHANGELOG.md)
before upgrading a setup you rely on.
:::

## Homebrew

A cask is generated with every release in Tenon's own tap. Once the release
repository is public, install it with:

```sh
brew tap nguyenvanduocit/tap
brew install --cask tenon
```

Homebrew fetches release assets anonymously, so a private release repository
cannot be used by the cask.

## Build from source

You need macOS 14+ and Xcode. You do **not** need to install a project
generator or fetch libghostty yourself — the verbs do it, with the exact pinned
versions and checksum verification.

```sh
git clone https://github.com/nguyenvanduocit/tenon.git
cd tenon
./tenon dev                # build Debug and launch
./tenon install --launch   # build Release and install to /Applications
```

`./tenon` on its own lists every verb, and each one fetches the build inputs it
needs, so a fresh clone has nothing to set up first. The first run downloads a
pinned `GhosttyKit.xcframework` — about 130 MB — and caches it.

That local install is signed ad-hoc, which is all a machine needs to run
software it just compiled itself. `./tenon install --staging` puts a second copy
beside the first under its own identity, so you can exercise a candidate build
without replacing the one you work in.

::: tip Going around the verbs
`swift build`, `swift test` and `xcodebuild` do not fetch anything themselves.
On a clone that has never run a verb, run `./scripts/internal/setup-ghostty.sh`
first or they will not find the framework.
:::

## Install the CLI

`tenon-cli` is how a shell — or an agent sitting in a pane — talks to the
running app. It ships inside the app bundle:

Open **Settings ▸ CLI ▸ Install** in the running production app, then run:

```sh
tenon-cli ping
```

A healthy answer names the running instance and its wire version:

```json
{
  "active" : false,
  "build" : "1",
  "pid" : 59949,
  "protocolVersion" : 3,
  "socketPath" : "/tmp/tenon-501/tenon.sock",
  "version" : "0.1.0"
}
```

Inside a Tenon terminal you do not have to point it anywhere: every pane exports
`TENON_SOCKET_PATH` and `TENON_PANE_ID`, and the CLI defaults to them. See
[Driving Tenon from a terminal](/guide/cli).

The installer places the binary in `~/.local/bin`; add that directory to your
`PATH` if your shell cannot find `tenon-cli`.

## First launch

Tenon opens on a workspace and one full-size terminal. Which directory it picks:

1. `TENON_WORKSPACE_PATH`, if set;
2. otherwise a meaningful launch directory;
3. falling back to your home directory when LaunchServices starts the app at `/`.

Next: **[Your first workspace](/guide/first-workspace)**.
