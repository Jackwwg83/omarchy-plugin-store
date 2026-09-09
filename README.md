# omarchy-plugin-store

Browse and manage [Omarchy Quattro](https://omarchy.org) shell plugins from the
official marketplace at `https://plugins.omarchy.org`, from the terminal.

One bash engine (`bash` + `jq` + `curl`) with two frontends: an `fzf` TUI and a
Quickshell overlay that renders a thumbnail grid of the marketplace. Every
command has a `--json` mode, and the overlay is nothing but a renderer on top of
them — no plugin management is reimplemented in QML.

Mutations are never done by hand: the store shells out to the stock
`omarchy-plugin-add|enable|disable|remove|update` commands, so
`~/.config/omarchy/shell.json` is only ever touched by Omarchy itself.

## Install

```bash
git clone https://github.com/Jackwwg83/omarchy-plugin-store.git
cd omarchy-plugin-store
ln -sf "$PWD/bin/omarchy-plugin-store" ~/.local/bin/omarchy-plugin-store
```

`~/.local/bin` is already on `PATH` on Omarchy. Requirements: `bash 5`, `jq`,
`curl`, `git`, plus `fzf` and `gum` for the TUI.

## Usage

```
omarchy-plugin-store <command> [options]
```

### Reading

| Command | What it does |
| --- | --- |
| `catalog [--refresh] [--quiet]` | refresh the cached catalog, print `2534 plugins · generated … · cache age …` |
| `search [query] [filters]` | search the catalog; TSV by default, `--json` for structured output |
| `show <id> [--json]` | one merged card: marketplace metadata + local checkout state |
| `thumb <id> [--detail]` | print the path of the cached preview image, downloading it on demand |
| `thumbs [--detail] [--json] <id>...` | fetch many previews at once, 8 in parallel; prints `id<TAB>path` per hit |
| `installed [--json]` | third-party plugins on this machine and how they compare to the marketplace |
| `tui [query]` | interactive browser |

`search` filters combine freely:

```
--category <C>    case-insensitive exact match
--kind <K>        case-insensitive substring ("--kind bar" matches "Bar widget" and "Bar")
--verified        only verificationStatus == verified
--installed       only what is installed here
--not-installed   only what is not
--installable     only entries the marketplace can install automatically
--sort stars|name|updated     default: stars descending, then name
--limit N
--refresh         force a catalog refresh first
```

The query matches case-insensitively against `id`, `name`, `description`,
`author`, and any tag.

`search --json` and `show --json` also carry two fields the catalog does not
print verbatim, so a grid can draw a cell without a `thumb` round trip:

* `hasPreview` — whether a card thumbnail exists at all.
* `initials` — the catalog's own `initials`, or the first letters of the first
  two words of `name`, for the placeholder tile.

`thumbs` reads ids from `stdin` when none are given, skips ids without a
preview (reporting the count on stderr), exits `0` when at least one succeeded
or nothing was asked for, and `1` when every requested id failed.

TSV columns (no header, tabs, seven fields):

```
id    name    kind    category    stars    verified(✓|·)    (enabled|installed|"")
```

`installed` TSV columns:

```
id    name    (enabled|disabled)    (listed|unlisted)    (pinned|at-validated|differs|unknown)
```

* `pinned` — the checkout is detached exactly at the marketplace-validated commit.
* `at-validated` — on a branch that happens to be at the validated commit.
* `differs` — HEAD and the validated commit are both known and different.
* `unknown` — not listed on the marketplace, not a git checkout, or no validated commit.

`installed` never runs `git fetch`; it is entirely offline.

### Managing

```
install <id> [--section left|center|right] [--pin] [--no-enable] [--yes]
enable  <id> [--section left|center|right]
disable <id>
remove  <id> [--yes]
update  [id] [--yes]
pin     <id>          check out the marketplace-validated commit
unpin   <id>          go back to the remote default branch
```

`install` looks the plugin up in the catalog, derives the clone URL from its
`repo` field, prints a security notice, runs `omarchy-plugin-add <url> --yes`,
optionally pins the checkout to the validated commit, and then enables it
(handling `--section` itself, which is why it never passes `--enable` to
`omarchy-plugin-add`). Every mutation finishes with a `rescanPlugins` call and
a desktop notification.

**Plugins are unsandboxed code running inside your long-lived `omarchy-shell`
process.** Read the repo before you install it. Non-interactive installs refuse
to run without `--yes`.

`remove` and `disable` on `io.github.jackwwg83.plugin-store` — the store itself — require
`--yes`.

### TUI keys

| Key | Action |
| --- | --- |
| `enter` | action menu for the highlighted plugin (context-aware: install / enable / disable / update / pin / unpin / remove / open repo / back) |
| `ctrl-r` | refresh the catalog and reload the list |
| `ctrl-i` | toggle installed-only |
| `ctrl-o` | open the plugin's repository in a browser |
| `esc` | quit (or leave the action menu) |

The preview pane on the right is `omarchy-plugin-store show <id>`.

## Overlay

The repo is also an Omarchy shell plugin (`io.github.jackwwg83.plugin-store`, kind
`overlay`): a centered card with a thumbnail grid of the whole marketplace on
the left and a detail pane with context-aware actions on the right. It shells
out to `bin/omarchy-plugin-store` for everything, so what you see is exactly
what the CLI reports.

### Install

```bash
omarchy plugin add https://github.com/Jackwwg83/omarchy-plugin-store.git --enable
```

Then bind a key by adding this line to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + CTRL + P", "Plugin store", "omarchy-shell shell toggle io.github.jackwwg83.plugin-store")
```

Or summon it straight from a terminal:

```bash
omarchy-shell shell toggle io.github.jackwwg83.plugin-store        # also: summon / hide
omarchy-shell shell summon io.github.jackwwg83.plugin-store '{"tab":"installed"}'
omarchy-shell shell summon io.github.jackwwg83.plugin-store '{"query":"clock"}'
```

The payload is optional JSON; `tab` (`browse` | `installed`) and `query` are
honored.

### Keys

| Key | Action |
| --- | --- |
| any printable character | append to the search box; filtering is instant and client-side |
| `backspace` / `ctrl+backspace` / `ctrl+u` | delete a character / a word / the whole query |
| `esc` | clear the query, then close on the next press |
| `↑ ↓ ← →`, `pgup`/`pgdn`, `home`/`end` | move the grid cursor |
| `enter` | primary action for the cursor cell — Install (opens the confirm dialog) or Enable/Disable |
| `tab` | switch Browse / Installed |
| `ctrl+r` | refresh the catalog from the network |
| `ctrl+o` | open the plugin's repository in a browser |
| `ctrl+v` | toggle the Verified filter |

Mouse: hover moves the cursor, click selects, double-click runs the primary
action, a click outside the card closes it.

### Consent

The shell is non-interactive, so every mutation runs the CLI with `--yes` and
the overlay owns the consent step itself. Install and Remove open a
`Ui/ConfirmDialog` first — Install spells out that plugins are unsandboxed code
inside your shell process, together with the id, verification status, stars,
last-updated date, repo URL, and whether it will be pinned to the validated
commit. Enable, Disable, Update, Pin and Unpin apply directly. The store
refuses to remove or disable itself; those buttons are greyed out with a
tooltip, and the CLI guard is the backstop.

### Dev loop

```bash
scripts/dev-install.sh          # rsync the tree into ~/.config/omarchy/plugins/io.github.jackwwg83.plugin-store/ + rescan
omarchy-shell shell toggle io.github.jackwwg83.plugin-store
scripts/dev-uninstall.sh        # disable, delete, rescan
```

`dev-install.sh` runs `omarchy plugin validate` first and refuses to copy a
folder the shell would reject. Editing files inside the plugin directory makes
the shell log `Local plugin changed, reloading`, but a structural QML edit is
not always picked up by that in-process reload — when the overlay still shows
the old layout, `omarchy-restart-shell` is the reliable refresh.

Debugging:

```bash
journalctl --user -n 200 --no-pager | grep -iE "plugin-store|qml"
omarchy plugin validate .
grim -o eDP-1 /tmp/store.png
```

## Configuration

All optional; they exist mostly so the test suite can run fully offline.

| Variable | Default |
| --- | --- |
| `OMARCHY_PLUGIN_STORE_CATALOG_URL` | `https://plugins.omarchy.org/catalog.json` (`file://` works) |
| `OMARCHY_PLUGIN_STORE_ASSET_BASE` | `https://plugins.omarchy.org/` |
| `OMARCHY_PLUGIN_STORE_TTL` | `43200` (12 h) |
| `XDG_CACHE_HOME` | `~/.cache` |
| `OMARCHY_PLUGINS_DIR` | `~/.config/omarchy/plugins` |
| `NO_COLOR` | unset; set it to strip ANSI from `show` |

The cache lives in `$XDG_CACHE_HOME/omarchy-plugin-store/`:

```
catalog.json          the raw download (~6 MB)
index.json            a slimmed, id-sorted projection used by every read command
thumbs/<id>.webp      card previews (720x405)
thumbs/<id>.detail.webp   detail previews (1600x900)
```

`index.json` carries an `indexVersion`; bumping it in the script rebuilds a
cache written by an older build instead of serving it without the new fields.

If a refresh fails but a cached catalog exists, the store warns on stderr and
keeps working with the stale copy. `stdout` is always data; progress, warnings
and security notices go to `stderr`.

## Tests

```bash
bash test/run.sh
```

Fully offline and hermetic: `XDG_CACHE_HOME` and `OMARCHY_PLUGINS_DIR` are
`mktemp -d` directories, the catalog is served over `file://` from
`test/fixtures/`, and `test/shims/` intercepts every `omarchy-plugin-*`, `gum`
and `omarchy-shell` call — recording their argv instead of changing the system.
Nothing under `~/.config` or `~/.cache` is read or written.

## License

MIT — see [LICENSE](LICENSE).
