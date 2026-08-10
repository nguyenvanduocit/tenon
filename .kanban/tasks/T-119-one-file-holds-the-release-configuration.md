# T-119: One file holds the release configuration

> Cutting a release meant knowing four things that lived in four places: an identity string
> in a doc table, a profile name defaulted inside a script, a team ID in a commit message,
> and an Apple ID nobody had written down. `.env` collects them.

- **priority**: high
- **effort**: S
- **prd**: TENON-PRD-015 (ENQ-NFR-013 credential hygiene, ENQ-NFR-012 reproducibility)

## What changed

- `.env.example` (tracked) documents every value and why the notarization password is not
  among them; `.env` (gitignored) holds this machine's real ones.
- `scripts/release-sign.sh` reads `.env` from the repository root before it checks its
  arguments, so a misconfigured file is reported by the run that would have used it.
  `scripts/release.sh` inherits the values through it — the file is read in exactly one
  place, not two.
- `.gitignore` covers `.env` and `.env.local`. **This came first**: the file did not exist
  yet and neither did the ignore rule, and creating it in that order would have staged a
  signing configuration into git.
- `docs/releasing.md` gains it as step 3 of one-time setup.

## The password stays in the keychain, and that is the point

The ask was "every secret in `.env`". The identity, team, profile name and Apple ID are
configuration and belong there. The app-specific notarization password is not: it sits in
a keychain profile where macOS encrypts it, and `security` cannot read it back out — which
is a property worth keeping, not an obstacle. Copying it into a dotfile would move a real
secret from encrypted storage into something backups, editors, and `rg` can all see.

So `.env` names `NOTARY_PROFILE` and the keychain holds the secret. One place to look,
without downgrading where the secret is kept.

## Criteria

- [x] `.env` is gitignored before it exists; `.env.example` is trackable
- [x] `.env` supplies the identity to a real run of `release-sign.sh`
- [x] An explicit environment value still overrides the file
- [x] With `.env` absent, the script still discovers the identity as before
- [x] `docs/releasing.md` describes it, including what is not in it

## Evidence

Three runs against a throwaway bundle, reading the identity the script actually resolved:

| Condition | `identity:` line |
|---|---|
| `.env` present | `Developer ID Application: GOLDEN CLOUD TECHNOLOGY COMPANY LIMITED (694MCRBCD6)` |
| `SIGN_IDENTITY=…Override Wins (ZZZZZZ)` exported | `Developer ID Application: Override Wins (ZZZZZZ)` |
| `.env` moved aside | falls back to keychain discovery, same identity |

## Owner / files (agent lock)

Session `b67a9a60` — released 2026-08-11 01:2x.
