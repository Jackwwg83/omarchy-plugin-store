# omarchy-plugin-store — SPEC Phase 2: Quickshell overlay

Phase 1 (done, see SPEC.md + `bin/omarchy-plugin-store`) is the engine. Phase 2
turns this repo into an installable Omarchy shell plugin whose `overlay` kind
renders a thumbnail grid of the marketplace and drives every action through the
Phase 1 CLI's `--json` outputs. Nothing about plugin management is
reimplemented in QML — the overlay is a renderer.

## 0. Ground truth about the host (verified — do not re-derive)

Host: Omarchy `4.0.0.alpha`, single long-lived Quickshell process
(`quickshell -n -p /usr/share/omarchy/shell`, pid changes). Laptop panel
`eDP-1 2880x1800 @ scale 2` (logical 1440×900). `grim` is available for
screenshots; `hyprshot` is not.

### 0.1 Plugin contract (from `/usr/share/omarchy/shell/shell.qml` 581–650 and `plugins/emojis/Emojis.qml`)

The shell creates one `Loader` per enabled `panel|overlay|menu` plugin,
`asynchronous: true`, active when `keepLoaded: true` or when summoned. After
load it assigns, if the root Item declares them:

```
property string omarchyPath   // = $OMARCHY_PATH (/usr/share/omarchy)
property var    shell         // host object: shell.hide(id), shell.summon(id, json), shell.toggle(id, json)
property var    manifest      // this plugin's manifest, with __sourceDir (absolute dir path) and __isFirstParty stamped in
property var    pluginRegistry, barWidgetRegistry, service   // optional; not needed here
```

It then calls `item.open(payloadJson)` on summon; `shell.isPluginOpen(id)`
reads `item.opened === true`; `shell.hide(id)` is what a plugin calls from its
own `dismiss()`. Follow Emojis.qml literally for the skeleton:

```
Item { id: root
  property string omarchyPath; property var shell: null; property var manifest: null
  property bool opened: false
  function open(payloadJson) { opened = true; ...; Qt.callLater(() => keyCatcher.forceActiveFocus()) }
  function close() { opened = false }
  function dismiss() { opened = false; if (shell && typeof shell.hide === "function") shell.hide(manifest.id) }
  function toggle() { opened ? dismiss() : open("{}") }
  PanelWindow { anchors { top:true; bottom:true; left:true; right:true }
    visible: root.opened
    WlrLayershell.namespace: "omarchy-plugin-store"; WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive; exclusionMode: ExclusionMode.Ignore
    Rectangle { anchors.fill: parent; color: root.scrim }          // scrim
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }   // click-outside closes
    BorderSurface { id: card; anchors.centerIn: parent; borderSpec: root.borderSpec; padding: ...
      MouseArea { anchors.fill: parent; onClicked: {} }             // swallow clicks inside
      Item { id: keyCatcher; focus: true; Keys.priority: Keys.BeforeItem; Keys.onPressed: ... }
      ...
```

Imports used by first-party overlays: `Quickshell`, `Quickshell.Io`,
`Quickshell.Wayland`, `QtQuick`, `QtQuick.Layouts` (if needed), `qs.Commons`,
`qs.Ui`. Read Emojis.qml (≈420 lines) and `plugins/image-picker/ImagePicker.qml`
(grid of thumbnails) before writing a line.

### 0.2 Theme + UI kit (`/usr/share/omarchy/shell/Commons`, `/usr/share/omarchy/shell/Ui`)

Use the `menu` surface tokens like Emojis does so themes that style the menu
style us: `Color.menu.background/text/border/scrim/selectedBackground/selectedText`,
`Color.accent`, `Color.urgent`, `Color.muted`, `Color.foreground`.
Spacing/typography: `Style.space(px)`, `Style.spacing.{md,panelPadding,controlPaddingY,...}`,
`Style.font.{bodySmall,body,title,heading,display,menuFamily,family,icon}`,
`Style.cornerRadius`, `Style.gapsOut`, `Border.surfaceSpec("menu","border",color,width)`.
Reusable components (read their headers for props): `Ui/Button` (text,
iconText, selected, hasCursor, bordered, onClicked), `Ui/TextField`,
`Ui/Dropdown` (label, value, options[], onValueChanged/onSelected — check),
`Ui/Toggle` (label, checked, clicked()), `Ui/ConfirmDialog` (opened, message,
confirmText, cancelText, confirmed(), canceled()), `Ui/PanelSectionHeader`,
`Ui/BorderSurface`. Never copy `Ui/` files into the plugin; import them via
`qs.Ui`. `Util.fileUrl(path)`, `Util.alpha(color, a)`, `Util.editsFilter(event, text)`
/ `Util.editedFilter(...)` exist in `qs.Commons`.

### 0.3 Running a command and reading JSON (pattern from `plugins/panels/weather/Panel.qml` ~392)

```
Process { id: searchProc
  command: [root.cli, "search", "--json"]
  stdout: StdioCollector { waitForEnd: true
    onStreamFinished: { var raw = String(text || "").trim(); if (!raw) return
      try { root.applyCatalog(JSON.parse(raw)) } catch (e) { console.warn("plugin-store: bad JSON", e) } } }
  stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text) console.warn("plugin-store:", text) }
  onExited: (code, status) => { ... }
}
```

`root.cli = manifest.__sourceDir + "/bin/omarchy-plugin-store"`. It is
executable in git. Fall back to plain `"omarchy-plugin-store"` (PATH) only if
`__sourceDir` is empty.

### 0.4 Images

`Image { source: path ? Util.fileUrl(path) : ""; asynchronous: true; cache: true;
fillMode: Image.PreserveAspectCrop; sourceSize.width: <cell px * 2> }` —
set `sourceSize` so 2000 WebP thumbnails don't decode at full size. Only set
`source` for delegates that are (near) visible; GridView recycles delegates,
so keep the id→path map on root, not in the delegate.

### 0.5 Hooking up, reloading, debugging

- Plugins live at `~/.config/omarchy/plugins/<id>/`. Saving any file there
  hot-reloads plugin code; force with `omarchy-shell shell rescanPlugins`.
- Summon from a terminal: `omarchy-shell shell toggle io.github.jackwwg83.plugin-store`
  (also `summon` / `hide`). This is what a keybinding would call
  (`o.bind("SUPER + SHIFT + P", "Plugin store", "omarchy-shell shell toggle io.github.jackwwg83.plugin-store")`
  in `~/.config/hypr/bindings.lua`) — document it in README, do NOT edit the
  user's bindings.lua.
- Shell log: `journalctl --user -n 200 --no-pager _COMM=quickshell` or
  `journalctl --user -n 200 --no-pager | grep -i "plugin-store\|plugin store\|qml"`;
  a QML load error appears as `panel plugin io.github.jackwwg83.plugin-store failed to load: …`.
  If neither shows anything, `quickshell --help` / `omarchy-shell --help` for a
  log subcommand.
- Screenshot for self-verification: `grim -o eDP-1 /tmp/claude-1000/…/shot.png`
  then view it with the Read tool. The overlay is a layer-shell surface so it
  IS captured by grim.
- `omarchy plugin validate <dir>` must pass on the repo root (no symlinks
  anywhere except under `.git`; `id` not `omarchy.*`; entry point exists).

## 1. Deliverables (add to this repo, keep Phase 1 intact and green)

```
manifest.json                 plugin manifest (§2)
Store.qml                     the overlay (§3) — may split helpers into Store/*.qml or *.js in the repo root or a subdir
scripts/dev-install.sh        rsync the working tree (excluding .git, test, scripts, *.md) into
                              ~/.config/omarchy/plugins/io.github.jackwwg83.plugin-store/ then `omarchy-shell shell rescanPlugins`
scripts/dev-uninstall.sh      remove that dir + rescan
bin/omarchy-plugin-store      Phase 2 additions to the CLI (§4) with tests in test/run.sh
README.md                     new "Overlay" section: install (`omarchy plugin add <repo> --enable`), keybinding line, keys, dev loop
```

## 2. manifest.json

```json
{
  "schemaVersion": 1,
  "id": "io.github.jackwwg83.plugin-store",
  "name": "Plugin Store",
  "version": "0.2.0",
  "author": "Jackwwg83",
  "description": "Browse, install and manage marketplace shell plugins with previews",
  "kinds": ["overlay"],
  "keepLoaded": true,
  "entryPoints": { "overlay": "Store.qml" }
}
```

## 3. Store.qml — behaviour

### 3.1 Layout (card centered, max ≈ `Style.space(1180)` × `Style.space(760)`, shrink to screen − 2·gapsOut)

```
┌ header ───────────────────────────────────────────────────────────────────┐
│ [🔍 type to search…                     ]  Browse | Installed   ⟳ 2534 · 3h │
│ Category ▾   Kind ▾   [✓ Verified]  [Installed]  [Installable]              │
├ grid (≈60%) ─────────────────────────────┬ detail (≈40%) ───────────────────┤
│ ┌────────┐ ┌────────┐ ┌────────┐         │ [detail image 16:9]              │
│ │ thumb  │ │ thumb  │ │ thumb  │         │ Name                 ✓ verified  │
│ │ 16:9   │ │        │ │        │  ...    │ author · v1.0 · MIT · ★ 14       │
│ ├────────┤ ├────────┤ ├────────┤         │ Bar widget · Widgets             │
│ │Name  ★ │ │Name    │ │Name  ✓ │         │ description…                     │
│ │kind    │ │kind ●  │ │kind    │         │ tags                             │
│ └────────┘ └────────┘ └────────┘         │ repo url                         │
│                                          │ ── Local ──                      │
│                                          │ installed · enabled · pinned     │
│                                          │ [Install ▾right] [Pin] [Remove]  │
└──────────────────────────────────────────┴──────────────────────────────────┘
 footer: esc close · ↑↓←→ move · enter primary action · tab tabs · ctrl+r refresh
```

- Grid cells: thumbnail (or a placeholder: catalog `initials`/first letters on an
  `accent`-tinted rectangle when no preview) + name (elide) + one line of
  kind/category, badges: `✓` verified (accent), `●` installed (accent) / enabled
  (foreground), `★ n` when stars > 0. Cursor cell uses `selectedBackground` + `selectedText` like Emojis.
- Detail pane always shows the cursor item. Buttons are context-aware exactly
  like the TUI action menu: Install (only when not installed and installAvailable),
  Enable/Disable, Update, Pin/Unpin, Remove, Open repo. Install row has a
  `Dropdown` for bar section (left/center/right, default from nothing — the CLI
  handles bar-widget default) shown only when kind contains "Bar widget", and a
  `Toggle` "Pin to verified commit" (default ON when a validated commit exists).
- Tabs: Browse = `search --json` (with the current filters), Installed =
  `installed --json` joined with catalog rows (use `search --json --installed`
  which already includes unlisted installed plugins).

### 3.2 Data flow

- On first `open()` (and on ctrl+r / ⟳): run `search --json` (plus
  `--refresh` for ⟳) once, keep the whole array on root (`keepLoaded` means it
  survives between summons). Show a "Loading catalog…" state; show the error text
  if the process exits non-zero.
- Filtering (query, category, kind, verified/installed/installable) is done
  **client-side in JS** over the in-memory array — never re-run the CLI per
  keystroke. Sort like the CLI: stars desc, then name.
- Category/Kind dropdown options are derived from the loaded data (distinct
  values, sorted, "All" first).
- Thumbnails: root keeps `thumbPaths: ({})` and a queue. A delegate whose id has
  no path calls `root.requestThumb(id)`. One worker `Process` runs
  `thumbs --tsv <id> <id> …` (§4.1) for up to 24 ids at a time and merges the
  `id\tpath` lines into `thumbPaths` as they stream in (`SplitParser` on stdout,
  or collect at end — either is fine). Skip ids the catalog says have no preview.
  Detail pane loads `thumb --detail <id>` on cursor change (debounce 150 ms).
- After any mutation completes: re-run `search --json` (no `--refresh`) to
  update local state, keep the cursor on the same id, and show the CLI's last
  stderr line in a transient footer status for ~4 s.

### 3.3 Mutations + consent

Every mutation runs the CLI **with `--yes`** because the shell is
non-interactive. Therefore the overlay itself owns the consent step:
`Ui/ConfirmDialog` with a message that includes, for install:

> Plugins run as arbitrary, unsandboxed code inside your omarchy-shell process.
> <name> (<id>) · <verificationStatus> · ★<stars> · updated <date>
> <repo>
> Install and enable in the <section> section, pinned to the validated commit?

Remove asks "Remove <id> from ~/.config/omarchy/plugins?". Enable/Disable/Pin/
Unpin/Update don't need confirmation. The store refuses to Remove/Disable itself
(`io.github.jackwwg83.plugin-store`) — grey the buttons out with a tooltip; the CLI guard is
the backstop, not the UI.

Commands (argv arrays, no shell string interpolation):
```
install: [cli, "install", id, "--yes", (pin ? "--pin" : ""), (section ? "--section", section : "")]   (drop empties)
enable:  [cli, "enable", id, ("--section", section)?]   disable: [cli, "disable", id]
update:  [cli, "update", id, "--yes"]   remove: [cli, "remove", id, "--yes"]
pin/unpin: [cli, "pin"|"unpin", id]     open repo: Quickshell.execDetached(["xdg-open", repo])
```
Only one mutation runs at a time; disable the action buttons while one is running.

### 3.4 Keyboard

Follow Emojis: `Keys.priority: Keys.BeforeItem` on the keyCatcher; every
printable char appends to the query (with `Util.editsFilter` handling backspace
etc.), `Esc` clears the query first and closes when it's empty, arrows / PgUp /
PgDn move the grid cursor (`columns` computed from width), `Enter` = primary
action of the cursor item (Install → opens the confirm dialog; if installed →
Enable/Disable toggle), `Tab` switches Browse/Installed, `Ctrl+R` refresh,
`Ctrl+O` open repo, `Ctrl+V` toggles the Verified filter. Mouse: hover moves the
cursor (like Emojis), click = select, double-click = primary action. The
ConfirmDialog must take keyboard focus while open and give it back after.

### 3.5 Performance guardrails

- `search --json` on 2534 entries is ≈ 1–2 MB; parse once. Keep filtered
  results in a `ListModel` rebuilt on filter change (≤ 2600 appends is fine) or
  bind a JS array to the GridView model — either, but the grid must stay smooth.
- Thumbnail `sourceSize.width` ≤ 2 × cell width. Card ~ 300 px wide at scale 2 →
  sourceSize 600.
- No timers polling. No work while `opened === false` except finishing an
  in-flight process.

## 4. CLI additions (bin/omarchy-plugin-store) — with tests

### 4.1 `thumbs [--detail] [--tsv] <id>...` (also reads ids from stdin when none given)

Downloads missing previews for all given ids concurrently (`xargs -P 8`
calling `thumb` on itself, or a bash job pool of 8), then prints one
`id \t path` line per id that has a preview (stdout, in completion order).
Ids without a preview or failed downloads are skipped silently (mention count on
stderr). Exit 0 if at least one succeeded or if nothing was requested; exit 1 if
all requested failed. `--json` variant: `{"id": "path", ...}`.

### 4.2 `search --json` gains `hasPreview` (bool) and `initials` (string, from
the catalog's `initials` field when present, else first letters of the first two
words of `name`) so the grid can render placeholders without a `thumb` round trip.

### 4.3 `show --json` gains `hasPreview` too. All existing tests must remain
green; add tests for 4.1 (fixture has both a thumbnail-having and a
thumbnail-less plugin already) and 4.2.

## 5. Acceptance (the reviewer will do this on the live shell)

```
bash test/run.sh                                        # all PASS incl. new thumbs/hasPreview cases
omarchy plugin validate ~/Projects/omarchy/omarchy-plugin-store   # exit 0
scripts/dev-install.sh                                  # installs to ~/.config/omarchy/plugins/io.github.jackwwg83.plugin-store/
omarchy plugin list | grep io.github.jackwwg83.plugin-store          # enabled, third-party, overlay
omarchy-shell shell toggle io.github.jackwwg83.plugin-store          # overlay appears; grim screenshot reviewed
  - grid shows thumbnails within ~2 s for the first screen; placeholders for no-preview entries
  - typing filters instantly; esc clears; esc again closes; click-outside closes
  - Installed tab lists jackom.clash (unlisted) and io.github.jackwwg83.plugin-store itself with Remove greyed out
  - selecting a listed plugin shows detail image + metadata; Install button opens ConfirmDialog; Cancel works
journalctl --user -n 100 --no-pager | grep -iE "plugin-store|qml|warn"   # no QML warnings from Store.qml
```

Real installs/removals of third-party plugins through the overlay are NOT part
of the subagent's job — the reviewer decides that with the user. You (the
implementer) MAY dev-install/uninstall *this* plugin as often as needed; a QML
load error is caught by the shell (it logs and hides the plugin) and does not
crash the shell.

## 6. Out of scope

Keybinding edits to the user's hypr config; publishing to the marketplace;
bar-widget kind for the store; a settings UI for TTL.
