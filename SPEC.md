# omarchy-plugin-store — SPEC (Phase 1: core CLI + fzf TUI)

A browser/manager for Omarchy Quattro shell plugins listed on the official
marketplace. One engine (bash + jq + curl), two frontends: an fzf TUI (this
phase) and a Quickshell overlay (phase 2, not in scope here).

Target machine: Arch Linux, Omarchy `4.0.0.alpha`, bash 5, jq 1.7, curl, git,
fzf, gum. No shellcheck/bats available — tests are plain bash.

## 1. Background facts (verified, do not re-derive)

### 1.1 Official catalog endpoint

`https://plugins.omarchy.org/catalog.json` — ~6.2 MB, regenerated daily.
Shape:

```json
{ "generatedAt": "2026-09-06T02:55:42.636Z", "mode": "production",
  "stateSchemaVersion": 1, "warnings": [ ... ],
  "plugins": [ { ...2525 entries... } ] }
```

Per-plugin fields we care about (all may be null/missing; be defensive):

```
id                      manifest id, e.g. "gigasolo.fizzy"  — JOIN KEY with local installs
name description author version license
category                "Widgets" | "Productivity" | "System" | "Hardware" | "Desktop" | ...
kind                    "Bar widget" | "Overlay" | "Service" | "Panel" | "Bar" | "Suite" | ...
tags                    array of strings
stars                   int
status                  e.g. "Beta", "Manual setup"
verificationStatus      "verified" | "unverified" | null
installAvailable        bool | null   (false for suites / non-plugin repos)
installCommand          "omarchy plugin add https://github.com/X/Y.git --enable"  ("" when unavailable)
installNote             human explanation when installAvailable is false
repo                    "https://github.com/X/Y"
repositoryUpdatedAt     ISO date
addedAt                 "YYYY-MM-DD"
previewThumbnail        "assets/img/plugins/…-card.webp"   (720x405) — RELATIVE to https://plugins.omarchy.org/
previewImage            "assets/img/plugins/…-detail.webp" (1600x900) — same base
listingValidatedCommit  sha the listing was first validated at
upstreamValidatedCommit sha most recently validated upstream (prefer this for pinning; fall back to listingValidatedCommit)
```

Gotcha: 404s on that host return HTTP 404 with a ~9 KB HTML body. Always
`curl -fsS` AND validate with `jq -e '.plugins | type == "array"'` before
accepting a download.

### 1.2 Local Omarchy CLI contract (already installed, in PATH via `/usr/share/omarchy/bin`)

```
omarchy-plugin-list --json
  → JSON array: {id, name, kinds[], enabled, active, canDisable, firstParty, clonedFrom}
omarchy-plugin-add <git-url> [--enable] [--yes]
  → clones into ~/.config/omarchy/plugins/<id>/, validates manifest, refuses without --yes when non-interactive.
    Clones branch HEAD (NOT the validated commit). Prints a security warning itself when interactive.
omarchy-plugin-enable <id> [section] [--section left|center|right] [--index N] [--before id] [--after id]
omarchy-plugin-disable <id>
omarchy-plugin-remove <id> [--yes]
omarchy-plugin-update [id] [--yes]
  → git fetch origin HEAD; shows diff; git merge --ff-only FETCH_HEAD. Works from detached HEAD
    as long as HEAD is an ancestor of FETCH_HEAD, so "pin then update" is compatible.
omarchy-plugin-validate <folder>
omarchy-shell shell rescanPlugins
omarchy-notification-send <text>
```

Installed third-party plugins live at `~/.config/omarchy/plugins/<id>/` and are
git checkouts (have `.git`). `omarchy.*` ids are first-party and never in the catalog.

Plugins are unsandboxed code inside the long-lived shell process. Every install
path in this tool MUST surface that fact before proceeding.

## 2. Deliverables

```
omarchy-plugin-store/               (this repo; git init, MIT LICENSE, README.md)
  bin/omarchy-plugin-store          single bash script, all subcommands
  test/run.sh                       offline test suite, exit 0 on pass
  test/fixtures/catalog.json        small hand-written catalog (≥4 plugins, see §5)
  test/shims/                       fake omarchy-plugin-* scripts that record argv
  SPEC.md                           this file
  README.md                         usage, install (symlink to ~/.local/bin), how the TUI keys work
  LICENSE                           MIT
```

Install step (do it, and document it): `ln -sf "$PWD/bin/omarchy-plugin-store" ~/.local/bin/omarchy-plugin-store`.
`~/.local/bin` is already on PATH.

## 3. Script conventions

- `#!/bin/bash`, `set -euo pipefail`, functions, `fail()` to stderr exit 1 — mirror
  the style of `/usr/share/omarchy/bin/omarchy-plugin-add` (read it first).
- Header comment lines in the official style:
  `# omarchy:summary=Browse and manage marketplace shell plugins`
- Env overrides (all optional, used by tests):
  - `OMARCHY_PLUGIN_STORE_CATALOG_URL` (default `https://plugins.omarchy.org/catalog.json`; `file://` URLs must work — curl supports them)
  - `OMARCHY_PLUGIN_STORE_ASSET_BASE` (default `https://plugins.omarchy.org/`)
  - `OMARCHY_PLUGIN_STORE_TTL` seconds (default `43200` = 12h)
  - `XDG_CACHE_HOME` (cache root; default `~/.cache`)
  - `OMARCHY_PLUGINS_DIR` (default `~/.config/omarchy/plugins`)
- Cache dir: `$XDG_CACHE_HOME/omarchy-plugin-store/` containing
  `catalog.json` (raw), `index.json` (slimmed, see §4.1), `thumbs/<id>.webp`, `thumbs/<id>.detail.webp`.
- Never edit `~/.config/omarchy/shell.json` directly — always go through `omarchy-plugin-*`.
- `SELF_ID="jackom.plugin-store"` constant. `remove`/`disable` on SELF_ID print a
  warning ("this is the plugin store itself") and require `--yes`.
- All jq programs must tolerate null/missing fields (`// ""`, `// 0`, `// []`).
- Output to stdout is data; everything else (progress, warnings) goes to stderr.
- `-h|--help` on every subcommand and on the bare command.

## 4. Subcommands

### 4.1 `catalog [--refresh] [--quiet]`

Ensure a fresh cache. If `catalog.json` missing or older than TTL or `--refresh`:
download to a temp file in the cache dir, validate (`jq -e '.plugins|type=="array"'`),
atomically `mv` over `catalog.json`, then regenerate `index.json`.
On download/validation failure: if an old cache exists, warn to stderr and keep
using it (exit 0); otherwise exit 1 with a clear message.

`index.json` = `{ "generatedAt": ..., "plugins": [ slim... ] }` where slim keeps
exactly: `id name description author version license category kind tags stars
status verificationStatus installAvailable installCommand installNote repo
repositoryUpdatedAt addedAt previewThumbnail previewImage listingValidatedCommit
upstreamValidatedCommit`, with null-safe defaults, sorted by `id`. Entries with
empty/null `id` are dropped.

Unless `--quiet`, print one summary line to stdout:
`2525 plugins · generated 2026-09-06T02:55Z · cache age 3h`.

Every other read command calls the same "ensure cache" routine implicitly
(without forcing refresh). Other subcommands accept `--refresh` too and pass it through.

### 4.2 `search [query] [filters] [--json|--tsv]`

Filters (combinable):
`--category <C>` (case-insensitive exact), `--kind <K>` (case-insensitive
substring, so `--kind bar` matches "Bar widget" and "Bar"), `--verified`,
`--installed`, `--not-installed`, `--installable` (installAvailable == true),
`--sort stars|name|updated` (default: stars desc, then name), `--limit N`.

`query` (optional, may contain spaces if quoted): case-insensitive substring
match against `id`, `name`, `description`, `author`, and any `tag`.

Installed detection: run `omarchy-plugin-list --json` once, collect ids where
`firstParty == false`; a catalog entry is installed iff its `id` is in that set.
Also compute `enabled` from the same data.

Output:
- default / `--tsv`: one row per plugin, tab-separated, NO header:
  `id \t name \t kind \t category \t stars \t verified \t installed`
  where `verified` ∈ `✓`/`·` and `installed` ∈ `installed`/`enabled`/`` (enabled implies installed; show the most specific).
  Replace any tab/newline inside fields with a space.
- `--json`: JSON array of slim objects plus `installed` (bool) and `enabled` (bool).

### 4.3 `show <id> [--json]`

Merged detail. Catalog slim fields + local block:

```
installed        bool
enabled          bool
localDir         path or ""
localHead        full sha or ""
localBranch      branch name, or "detached"
validatedCommit  upstreamValidatedCommit // listingValidatedCommit // ""
pinned           localHead == validatedCommit
```

Human output (default): a compact card readable in an 80x24 fzf preview pane —
name + id on line 1, then author/version/license/stars/kind/category,
verification status, updated/added dates, description word-wrapped to 76 cols,
tags, repo URL, then a `Local:` section (not installed / installed+enabled /
HEAD vs validated commit, "pinned to verified commit" or "HEAD differs from
validated commit (abc1234 vs def5678)"), then an `Install:` line showing the
exact command that `install` would run, or `installNote` when unavailable.
Use `gum style`/ANSI colors sparingly; must degrade fine when `NO_COLOR` is set.

Exit 1 with a message if the id is not in the catalog — BUT if the id is a
locally installed third-party plugin not in the catalog, still show the local
block with a "not listed on the marketplace" note (exit 0).

### 4.4 `thumb <id> [--detail]`

Print the local path of the cached thumbnail (or detail image with `--detail`),
downloading it first from `$ASSET_BASE + previewThumbnail` if missing
(`curl -fsS --max-time 20`, temp file, mv). Exit 1 (with stderr message, no
stdout) if the plugin has no preview or download fails.

### 4.5 `installed [--json]`

List third-party installed plugins (`firstParty == false`) enriched with catalog
match: tsv `id \t name \t enabled|disabled \t listed|unlisted \t update-status`
where update-status ∈ `pinned` / `at-validated` / `differs` / `unknown`
(`differs` when localHead != validatedCommit and both known; `unknown` when
unlisted or no validated commit). Do NOT run `git fetch` here — this is offline.

### 4.6 Mutations

All mutations: print what will be executed, then execute, then
`omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true`, then
`omarchy-notification-send "<short result>" >/dev/null 2>&1 || true`.

`install <id> [--section left|center|right] [--pin] [--no-enable] [--yes]`
1. Look up the catalog entry; fail if not found; fail with `installNote` if
   `installAvailable != true`; fail if already installed (suggest `update`).
2. Derive the git URL from `repo` (append `.git` if missing). Do not parse
   `installCommand` — it is display-only.
3. Print a security notice to stderr (unsandboxed code in the shell process,
   repo URL, verificationStatus, stars, last updated). If not `--yes`: when
   interactive (`[[ -t 0 && -t 1 ]]`) run `gum confirm`, else fail asking for `--yes`.
4. `omarchy-plugin-add "$url" --yes` (never pass `--enable` here; we handle enable ourselves so `--section` works).
5. If `--pin` and validatedCommit non-empty: `git -C "$dir" checkout --quiet "$validatedCommit"`;
   if the sha isn't present locally, `git fetch --quiet origin "$sha"` first; on failure warn, don't abort.
6. Unless `--no-enable`: `omarchy-plugin-enable "$id" ${section:+--section "$section"}`.
   When the manifest has `kinds` containing `bar-widget` and no `--section`,
   and interactive, offer `gum choose left center right` defaulting to
   `manifest.barWidget.defaultSection // "center"`; non-interactive → let
   omarchy-plugin-enable use its own default.

`pin <id>` — checkout validatedCommit as above (fail if not installed / not listed / no commit).
`unpin <id>` — checkout the remote default branch:
`git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD` → strip `origin/` → `git checkout --quiet <branch>`;
if that ref is missing, `git remote set-head origin --auto` first.

`enable <id> [--section S]`, `disable <id>`, `remove <id> [--yes]`, `update [id] [--yes]`
— thin passthroughs to the matching `omarchy-plugin-*` (forward args verbatim
after the SELF_ID guard for remove/disable).

### 4.7 `tui [initial-query]`

```
omarchy-plugin-store search --tsv [query] |
fzf --ansi --delimiter '\t' --with-nth 2,3,4,5,6,7 --nth 1,2 \
    --header 'enter: actions · ctrl-r: refresh catalog · ctrl-i: toggle installed-only · ctrl-o: open repo · esc: quit' \
    --preview 'omarchy-plugin-store show {1}' --preview-window 'right,55%,wrap' \
    --bind 'ctrl-r:reload(omarchy-plugin-store search --refresh --tsv)' \
    --bind 'ctrl-i:...' (toggle between full list and `search --installed --tsv` via reload)
    --bind 'ctrl-o:execute-silent(xdg-open $(omarchy-plugin-store show {1} --json | jq -r .repo))'
    --expect enter
```

On enter: read the selected id, then `gum choose` from a context-aware action
list — `install` (only if not installed & installable), `enable`/`disable`
(depending on state), `update`, `pin`/`unpin` (depending on state), `remove`,
`open repo`, `back`. Run the chosen mutation (interactive, so `gum confirm`
prompts appear naturally), press-any-key, then loop back into fzf with the same
query. `back`/esc returns to the list. Quit on esc from the list.

Invoke the real script path via `${BASH_SOURCE[0]}` resolved to an absolute
path (readlink -f) so the fzf `--preview`/`reload` commands work even when the
symlink in `~/.local/bin` is how it was launched.

## 5. Tests (`test/run.sh`)

Must run fully offline and never touch `~/.config` or `~/.cache`:
- export `XDG_CACHE_HOME=$(mktemp -d)`, `OMARCHY_PLUGINS_DIR=$(mktemp -d)`,
  `OMARCHY_PLUGIN_STORE_CATALOG_URL=file://$PWD/test/fixtures/catalog.json`,
  `OMARCHY_PLUGIN_STORE_ASSET_BASE=file://$PWD/test/fixtures/`,
  and `PATH=$PWD/test/shims:$PATH`.
- `test/shims/omarchy-plugin-list` prints a fixed JSON array (2 third-party
  installed ids that exist in the fixture, one of them enabled; plus one
  `omarchy.clock` first-party entry that must be ignored).
- `test/shims/omarchy-plugin-add|enable|disable|remove|update`,
  `omarchy-shell`, `omarchy-notification-send`, `gum`: append `"$0 $*"` to
  `$SHIM_LOG` and exit 0. `gum confirm` shim exits 0. `gum choose` shim prints its
  last positional arg.
- For installed fixtures, create real git repos in `$OMARCHY_PLUGINS_DIR/<id>`
  with two commits so pin/unpin/`show` can be asserted (`validatedCommit` in the
  fixture must equal the first commit sha — generate the fixture's sha at test
  time by writing a temp catalog.json from a template, or make the test create
  the repos first and then `jq` the real sha into a temp copy of the fixture).
- Fixture plugins (at least): one verified bar-widget with a thumbnail (a tiny
  real `.webp` file in fixtures), one unverified overlay without thumbnail, one
  `installAvailable: false` suite with `installNote`, one with null `stars`/`tags`.
- Assertions (use a small `assert_eq`/`assert_contains` helper, print PASS/FAIL
  per case, exit non-zero if any fail):
  1. `catalog` creates `index.json` with the slim field set and sorted ids; summary line matches `^[0-9]+ plugins`.
  2. TTL: touch `catalog.json` old → `catalog` re-downloads; fresh → does not (compare mtime).
  3. Broken URL with existing cache → exit 0 + stderr warning; broken URL with no cache → exit 1.
  4. `search` query matches on tag and on author, case-insensitive; `--category`, `--kind bar`, `--verified`, `--installed`, `--not-installed`, `--installable`, `--limit`, `--sort name` each behave.
  5. `search --tsv` has exactly 7 columns per row; `--json` has `installed`/`enabled` booleans.
  6. `show <installed-id>` reports `pinned` correctly before/after `pin`/`unpin`; `show <unknown>` exits 1; `show <unlisted-but-installed>` exits 0 with the unlisted note.
  7. `thumb` downloads (copies) the webp into cache and prints the path; second call doesn't re-download; no-preview id exits 1 with empty stdout.
  8. `install` non-interactive without `--yes` fails; with `--yes` the shim log shows `omarchy-plugin-add <url>.git --yes` followed by `omarchy-plugin-enable <id> --section right` when `--section right`; `--no-enable` omits enable; `--pin` leaves HEAD at validatedCommit; `installAvailable:false` id fails mentioning the note.
  9. `remove jackom.plugin-store` without `--yes` fails with the self-guard message.
  10. `installed` tsv shows `enabled|disabled`, `listed|unlisted`, and `pinned|differs|unknown` correctly.
- Also run `bash -n bin/omarchy-plugin-store` as the first test.

## 6. Acceptance (what the reviewer will run on the real machine)

```
omarchy-plugin-store catalog                      # downloads 6.2MB, prints summary
omarchy-plugin-store search clock --kind bar --limit 5
omarchy-plugin-store search --installed           # must show jackom.clash (unlisted, installed)
omarchy-plugin-store show jackom.clash            # unlisted note, exit 0
omarchy-plugin-store show gigasolo.fizzy          # real listed plugin
omarchy-plugin-store thumb gigasolo.fizzy && file "$(omarchy-plugin-store thumb gigasolo.fizzy)"
omarchy-plugin-store installed
omarchy-plugin-store tui                          # manual: browse, preview renders, esc quits cleanly
bash test/run.sh                                  # all PASS
```

No mutation against the real machine will be run by the reviewer without
explicit user consent; the shims cover that path.

## 7. Out of scope (phase 2)

Quickshell overlay (`manifest.json`, `Store.qml`), thumbnail grid, keybinding.
Design the CLI output so a QML `Process` can consume `--json` everywhere.
