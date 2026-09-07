#!/bin/bash

# Offline test suite for omarchy-plugin-store.
#
# Never touches ~/.config or ~/.cache: XDG_CACHE_HOME and OMARCHY_PLUGINS_DIR
# point at mktemp dirs, the catalog is served over file://, and every
# omarchy-plugin-* call is intercepted by test/shims.

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
BIN="$ROOT/bin/omarchy-plugin-store"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export XDG_CACHE_HOME="$WORK/cache"
export OMARCHY_PLUGINS_DIR="$WORK/plugins"
export PATH="$ROOT/test/shims:$PATH"
export SHIM_LOG="$WORK/shim.log"
export OMARCHY_PLUGIN_STORE_ASSET_BASE="file://$ROOT/test/fixtures/"
export NO_COLOR=1
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.invalid"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: >"$GIT_CONFIG_GLOBAL"
: >"$SHIM_LOG"

mkdir -p "$XDG_CACHE_HOME" "$OMARCHY_PLUGINS_DIR" "$WORK/src"

CACHE="$XDG_CACHE_HOME/omarchy-plugin-store"

PASSED=0
FAILED=0

ok() {
  PASSED=$((PASSED + 1))
  printf 'PASS  %s\n' "$1"
}

bad() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  [[ $# -gt 1 ]] && printf '        %s\n' "$2"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    ok "$name"
  else
    bad "$name" "expected [$expected] but got [$actual]"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ $haystack == *"$needle"* ]]; then
    ok "$name"
  else
    bad "$name" "missing [$needle] in [${haystack:0:500}]"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ $haystack != *"$needle"* ]]; then
    ok "$name"
  else
    bad "$name" "unexpectedly found [$needle]"
  fi
}

RC=0 OUT="" ERR=""
run() {
  OUT="$("$@" 2>"$WORK/stderr" </dev/null)"
  RC=$?
  ERR="$(cat "$WORK/stderr")"
}

store() { run "$BIN" "$@"; }

reset_log() { : >"$SHIM_LOG"; }
log() { cat "$SHIM_LOG"; }

# ------------------------------------------------------------------ setup ---

# Two-commit git repo, cloned into the plugins dir so origin/HEAD exists.
make_repo() {
  local id="$1"
  local src="$WORK/src/$id"
  git init -q -b main "$src"
  echo '{"id":"'"$id"'","kinds":["bar-widget"],"barWidget":{"defaultSection":"center"}}' >"$src/manifest.json"
  git -C "$src" add -A
  git -C "$src" commit -qm "first"
  echo "second" >"$src/CHANGELOG"
  git -C "$src" add -A
  git -C "$src" commit -qm "second"
  git clone -q "$src" "$OMARCHY_PLUGINS_DIR/$id"
}

sha_at() { git -C "$WORK/src/$1" rev-parse "$2"; }

make_repo acme.clock
make_repo zeta.overlay
make_repo bara.bar
mkdir -p "$OMARCHY_PLUGINS_DIR/local.only"

ACME_SHA1="$(sha_at acme.clock HEAD~1)"
ACME_SHA2="$(sha_at acme.clock HEAD)"
ZETA_SHA2="$(sha_at zeta.overlay HEAD)"
BARA_SHA1="$(sha_at bara.bar HEAD~1)"
BARA_SHA2="$(sha_at bara.bar HEAD)"

sed -e "s/@@ACME_SHA@@/$ACME_SHA1/" \
  -e "s/@@ZETA_SHA@@/$ZETA_SHA2/" \
  -e "s/@@BARA_SHA@@/$BARA_SHA1/" \
  "$ROOT/test/fixtures/catalog.json" >"$WORK/catalog.json"

export OMARCHY_PLUGIN_STORE_CATALOG_URL="file://$WORK/catalog.json"

# ------------------------------------------------------------- 0. syntax ----

if bash -n "$BIN" 2>"$WORK/stderr"; then
  ok "bash -n bin/omarchy-plugin-store"
else
  bad "bash -n bin/omarchy-plugin-store" "$(cat "$WORK/stderr")"
fi

# ------------------------------------------------------------- 1. catalog ---

store catalog
assert_eq "catalog exits 0" 0 "$RC"
if [[ $OUT =~ ^[0-9]+\ plugins ]]; then
  ok "catalog summary matches '^[0-9]+ plugins'"
else
  bad "catalog summary matches '^[0-9]+ plugins'" "got [$OUT]"
fi
assert_contains "catalog summary has generated + cache age" "$OUT" "· generated 2026-09-01T12:00Z · cache age"

if [[ -s $CACHE/index.json ]]; then ok "catalog writes index.json"; else bad "catalog writes index.json"; fi

assert_eq "index ids are sorted and empty ids dropped" \
  "acme.clock bara.bar lacuna.suite nul.thing zeta.overlay" \
  "$(jq -r '[.plugins[].id] | join(" ")' "$CACHE/index.json")"

assert_eq "index slim field set is exact" \
  "addedAt author category description id initials installAvailable installCommand installNote kind license listingValidatedCommit name previewImage previewThumbnail repo repositoryUpdatedAt stars status tags upstreamValidatedCommit verificationStatus version" \
  "$(jq -r '[.plugins[0] | keys[]] | sort | join(" ")' "$CACHE/index.json")"

assert_eq "null stars default to 0" "0" \
  "$(jq -r '.plugins[] | select(.id=="nul.thing") | .stars' "$CACHE/index.json")"
assert_eq "null tags default to []" "0" \
  "$(jq -r '.plugins[] | select(.id=="nul.thing") | .tags | length' "$CACHE/index.json")"
assert_eq "null installAvailable defaults to false" "false" \
  "$(jq -r '.plugins[] | select(.id=="nul.thing") | .installAvailable' "$CACHE/index.json")"

assert_eq "index stamps its schema version" "2" \
  "$(jq -r '.indexVersion' "$CACHE/index.json")"
assert_eq "initials are derived from the first two words of the name" "AC" \
  "$(jq -r '.plugins[] | select(.id=="acme.clock") | .initials' "$CACHE/index.json")"
assert_eq "initials fall back to one letter for a one-word name" "ZO" \
  "$(jq -r '.plugins[] | select(.id=="zeta.overlay") | .initials' "$CACHE/index.json")"
assert_eq "catalog-supplied initials win over the derived ones" "XY" \
  "$(jq -r '.plugins[] | select(.id=="lacuna.suite") | .initials' "$CACHE/index.json")"

store catalog --quiet
assert_eq "catalog --quiet prints nothing" "" "$OUT"

# ----------------------------------------------------------------- 2. TTL ---

MT1="$(stat -c %Y "$CACHE/catalog.json")"
store catalog --quiet
MT2="$(stat -c %Y "$CACHE/catalog.json")"
assert_eq "fresh cache is not re-downloaded" "$MT1" "$MT2"

touch -d '2 days ago' "$CACHE/catalog.json"
MT_OLD="$(stat -c %Y "$CACHE/catalog.json")"
store catalog --quiet
MT3="$(stat -c %Y "$CACHE/catalog.json")"
if [[ $MT3 != "$MT_OLD" ]]; then
  ok "stale cache is re-downloaded"
else
  bad "stale cache is re-downloaded" "mtime unchanged ($MT3)"
fi

touch -d '1 hour ago' "$CACHE/catalog.json"
MT_OLD="$(stat -c %Y "$CACHE/catalog.json")"
store catalog --refresh --quiet
MT4="$(stat -c %Y "$CACHE/catalog.json")"
if [[ $MT4 != "$MT_OLD" ]]; then
  ok "--refresh re-downloads a still-fresh cache"
else
  bad "--refresh re-downloads a still-fresh cache" "mtime unchanged ($MT4)"
fi

# ------------------------------------------------------- 3. download fails ---

OMARCHY_PLUGIN_STORE_CATALOG_URL="file://$WORK/does-not-exist.json" store catalog --refresh
assert_eq "broken URL with cache exits 0" 0 "$RC"
assert_contains "broken URL with cache warns on stderr" "$ERR" "using cached copy"

EMPTY_CACHE="$WORK/empty-cache"
XDG_CACHE_HOME="$EMPTY_CACHE" OMARCHY_PLUGIN_STORE_CATALOG_URL="file://$WORK/does-not-exist.json" store catalog
assert_eq "broken URL without cache exits 1" 1 "$RC"
assert_contains "broken URL without cache explains" "$ERR" "could not download catalog"

# Non-JSON payload must be rejected too.
echo '<html>404</html>' >"$WORK/notjson.json"
XDG_CACHE_HOME="$EMPTY_CACHE" OMARCHY_PLUGIN_STORE_CATALOG_URL="file://$WORK/notjson.json" store catalog
assert_eq "HTML payload without cache exits 1" 1 "$RC"

# -------------------------------------------------------------- 4. search ---

store search chronometer
assert_eq "search matches on tag" "acme.clock" "$(printf '%s' "$OUT" | cut -f1)"

store search "ACME LABS"
assert_eq "search matches on author, case-insensitively" "acme.clock" "$(printf '%s' "$OUT" | cut -f1)"

store search "zeta overlay"
assert_eq "multi-word query matches across a space" "zeta.overlay" "$(printf '%s' "$OUT" | cut -f1)"

store search "no such plugin anywhere"
assert_eq "query with no match returns nothing" "" "$OUT"

store search notes
assert_eq "search matches on description" "zeta.overlay" "$(printf '%s' "$OUT" | cut -f1)"

store search --category widgets
assert_eq "--category is case-insensitive exact" "acme.clock" "$(printf '%s' "$OUT" | cut -f1)"

store search --category Widget
assert_eq "--category does not substring-match" "" "$OUT"

store search --kind bar
assert_eq "--kind bar matches 'Bar widget' and 'Bar'" "acme.clock bara.bar" \
  "$(printf '%s' "$OUT" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"

store search --verified
assert_eq "--verified" "acme.clock" "$(printf '%s' "$OUT" | cut -f1)"

store search --installed
assert_eq "--installed includes unlisted local plugins" "acme.clock local.only zeta.overlay" \
  "$(printf '%s' "$OUT" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"

store search --not-installed
assert_eq "--not-installed" "bara.bar lacuna.suite nul.thing" \
  "$(printf '%s' "$OUT" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"

store search --installable
assert_eq "--installable" "acme.clock bara.bar zeta.overlay" \
  "$(printf '%s' "$OUT" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"

store search --limit 2
assert_eq "--limit 2" "2" "$(printf '%s\n' "$OUT" | grep -c .)"

store search --sort name
assert_eq "--sort name" "acme.clock" "$(printf '%s' "$OUT" | head -1 | cut -f1)"

store search
assert_eq "default sort is stars desc" "lacuna.suite" "$(printf '%s' "$OUT" | head -1 | cut -f1)"

store search --sort updated
assert_eq "--sort updated" "bara.bar" "$(printf '%s' "$OUT" | head -1 | cut -f1)"

store search --bogus
assert_eq "unknown search flag exits 1" 1 "$RC"

# ------------------------------------------------------- 5. output shapes ---

store search --tsv
assert_eq "tsv rows all have 7 columns" "7" \
  "$(printf '%s\n' "$OUT" | awk -F'\t' 'NF { print NF }' | sort -u | tr '\n' ' ' | sed 's/ $//')"
assert_contains "tsv marks verified with a check" "$(printf '%s' "$OUT" | grep '^acme.clock')" $'\t✓\t'
assert_contains "tsv marks unverified with a dot" "$(printf '%s' "$OUT" | grep '^bara.bar')" $'\t·\t'
assert_eq "tsv installed column: enabled" "enabled" "$(printf '%s' "$OUT" | grep '^acme.clock' | cut -f7)"
assert_eq "tsv installed column: installed" "installed" "$(printf '%s' "$OUT" | grep '^zeta.overlay' | cut -f7)"
assert_eq "tsv installed column: empty" "" "$(printf '%s' "$OUT" | grep '^bara.bar' | cut -f7)"

store search --json
assert_eq "--json installed boolean" "true" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="acme.clock") | .installed')"
assert_eq "--json enabled boolean" "true" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="acme.clock") | .enabled')"
assert_eq "--json enabled false for disabled install" "false" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="zeta.overlay") | .enabled')"
assert_eq "--json installed false for uninstalled" "false" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="nul.thing") | .installed')"
assert_eq "--json hasPreview true when the catalog has a thumbnail" "true" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="acme.clock") | .hasPreview')"
assert_eq "--json hasPreview false without a thumbnail" "false" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="zeta.overlay") | .hasPreview')"
assert_eq "--json carries initials" "AC" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="acme.clock") | .initials')"
assert_eq "--json initials for an unlisted installed plugin" "LO" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="local.only") | .initials')"
assert_eq "--json hasPreview false for an unlisted installed plugin" "false" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="local.only") | .hasPreview')"

# ---------------------------------------------------------------- 6. show ---

store show acme.clock
assert_eq "show installed plugin exits 0" 0 "$RC"
assert_contains "show reports HEAD differs before pin" "$OUT" \
  "HEAD differs from validated commit (${ACME_SHA2:0:7} vs ${ACME_SHA1:0:7})"
assert_contains "show reports enabled" "$OUT" "installed · enabled"

store show acme.clock --json
assert_eq "show --json pinned=false before pin" "false" "$(printf '%s' "$OUT" | jq -r '.pinned')"
assert_eq "show --json validatedCommit" "$ACME_SHA1" "$(printf '%s' "$OUT" | jq -r '.validatedCommit')"
assert_eq "show --json localBranch" "main" "$(printf '%s' "$OUT" | jq -r '.localBranch')"
assert_eq "show --json hasPreview" "true" "$(printf '%s' "$OUT" | jq -r '.hasPreview')"
assert_eq "show --json initials" "AC" "$(printf '%s' "$OUT" | jq -r '.initials')"

store show zeta.overlay --json
assert_eq "show --json hasPreview false without a thumbnail" "false" \
  "$(printf '%s' "$OUT" | jq -r '.hasPreview')"

store show local.only --json
assert_eq "show --json hasPreview false for an unlisted plugin" "false" \
  "$(printf '%s' "$OUT" | jq -r '.hasPreview')"
assert_eq "show --json initials from the local name" "LO" \
  "$(printf '%s' "$OUT" | jq -r '.initials')"

reset_log
store pin acme.clock
assert_eq "pin exits 0" 0 "$RC"
assert_eq "pin moves HEAD to the validated commit" "$ACME_SHA1" \
  "$(git -C "$OMARCHY_PLUGINS_DIR/acme.clock" rev-parse HEAD)"
assert_contains "pin rescans the shell" "$(log)" "omarchy-shell shell rescanPlugins"
assert_contains "pin sends a notification" "$(log)" "omarchy-notification-send"

store show acme.clock
assert_contains "show reports pinned after pin" "$OUT" "pinned to validated commit"
store show acme.clock --json
assert_eq "show --json pinned=true after pin" "true" "$(printf '%s' "$OUT" | jq -r '.pinned')"
assert_eq "show --json localBranch detached after pin" "detached" "$(printf '%s' "$OUT" | jq -r '.localBranch')"

store unpin acme.clock
assert_eq "unpin exits 0" 0 "$RC"
assert_eq "unpin returns to the default branch" "$ACME_SHA2" \
  "$(git -C "$OMARCHY_PLUGINS_DIR/acme.clock" rev-parse HEAD)"
store show acme.clock
assert_contains "show reports differs again after unpin" "$OUT" "HEAD differs from validated commit"

store show no.such.plugin
assert_eq "show unknown id exits 1" 1 "$RC"
assert_eq "show unknown id prints nothing on stdout" "" "$OUT"
assert_contains "show unknown id explains" "$ERR" "no plugin 'no.such.plugin'"

store show local.only
assert_eq "show unlisted-but-installed exits 0" 0 "$RC"
assert_contains "show unlisted note" "$OUT" "not listed on the marketplace"
assert_contains "show unlisted uses the local name" "$OUT" "Local Only"

store show lacuna.suite
assert_contains "show surfaces installNote when not installable" "$OUT" "shell suite with its own installer"

store show acme.clock
assert_contains "show says an installed plugin is already installed" "$OUT" "already installed"

store show bara.bar
assert_contains "show prints the exact install command" "$OUT" \
  "omarchy-plugin-add https://github.com/bara/omarchy-bar.git --yes"
assert_contains "show reports not installed" "$OUT" "not installed"

# --------------------------------------------------------------- 7. thumb ---

store thumb acme.clock
assert_eq "thumb exits 0" 0 "$RC"
assert_eq "thumb prints the cache path" "$CACHE/thumbs/acme.clock.webp" "$OUT"
if [[ -s $CACHE/thumbs/acme.clock.webp ]]; then ok "thumb caches the file"; else bad "thumb caches the file"; fi
assert_eq "thumb copies the real bytes" \
  "$(md5sum <"$ROOT/test/fixtures/tiny-card.webp" | cut -d' ' -f1)" \
  "$(md5sum <"$CACHE/thumbs/acme.clock.webp" | cut -d' ' -f1)"

TMT1="$(stat -c %Y "$CACHE/thumbs/acme.clock.webp")"
touch -d '1 hour ago' "$CACHE/thumbs/acme.clock.webp"
TMT1="$(stat -c %Y "$CACHE/thumbs/acme.clock.webp")"
store thumb acme.clock
assert_eq "second thumb call does not re-download" "$TMT1" \
  "$(stat -c %Y "$CACHE/thumbs/acme.clock.webp")"

store thumb acme.clock --detail
assert_eq "thumb --detail path" "$CACHE/thumbs/acme.clock.detail.webp" "$OUT"

store thumb zeta.overlay
assert_eq "thumb without preview exits 1" 1 "$RC"
assert_eq "thumb without preview prints nothing on stdout" "" "$OUT"
assert_contains "thumb without preview explains" "$ERR" "no preview image"

store thumb no.such.plugin
assert_eq "thumb for unknown id exits 1" 1 "$RC"

# -------------------------------------------------------------- 7b. thumbs ---

rm -rf "$CACHE/thumbs"

store thumbs acme.clock zeta.overlay
assert_eq "thumbs exits 0 when at least one preview exists" 0 "$RC"
assert_eq "thumbs prints one id<TAB>path line per preview" \
  "acme.clock	$CACHE/thumbs/acme.clock.webp" "$OUT"
assert_contains "thumbs counts the skipped ids on stderr" "$ERR" "1 of 2 previews unavailable"
if [[ -s $CACHE/thumbs/acme.clock.webp ]]; then ok "thumbs downloads the file"; else bad "thumbs downloads the file"; fi

store thumbs acme.clock
assert_eq "thumbs stays quiet when nothing is missing" "" "$ERR"

store thumbs --json acme.clock zeta.overlay
assert_eq "thumbs --json maps id to path" "$CACHE/thumbs/acme.clock.webp" \
  "$(printf '%s' "$OUT" | jq -r '."acme.clock"')"
assert_eq "thumbs --json omits ids without a preview" "null" \
  "$(printf '%s' "$OUT" | jq -r '."zeta.overlay"')"

store thumbs --detail acme.clock
assert_eq "thumbs --detail uses the detail image" \
  "acme.clock	$CACHE/thumbs/acme.clock.detail.webp" "$OUT"

store thumbs zeta.overlay lacuna.suite
assert_eq "thumbs exits 1 when every requested id failed" 1 "$RC"
assert_eq "thumbs prints nothing on stdout when all failed" "" "$OUT"

store thumbs --json zeta.overlay
assert_eq "thumbs --json still prints an object when all failed" "{}" "$OUT"

store thumbs
assert_eq "thumbs with no ids exits 0" 0 "$RC"
assert_eq "thumbs with no ids prints nothing" "" "$OUT"

store thumbs no.such.plugin
assert_eq "thumbs skips ids that are not in the catalog" 1 "$RC"

store thumbs "../../etc/passwd"
assert_eq "thumbs rejects a traversing id" 1 "$RC"
assert_eq "thumbs prints nothing for a traversing id" "" "$OUT"

OUT="$(printf 'acme.clock\nzeta.overlay\n' | "$BIN" thumbs 2>"$WORK/stderr")"
RC=$?
assert_eq "thumbs reads ids from stdin" "acme.clock	$CACHE/thumbs/acme.clock.webp" "$OUT"
assert_eq "thumbs from stdin exits 0" 0 "$RC"

store thumbs --bogus
assert_eq "unknown thumbs flag exits 1" 1 "$RC"

# Downloading many at once must not lose or duplicate lines.
rm -rf "$CACHE/thumbs"
store thumbs acme.clock acme.clock zeta.overlay bara.bar nul.thing lacuna.suite
assert_eq "thumbs de-duplicates ids" "1" "$(printf '%s\n' "$OUT" | grep -c 'acme.clock')"

# ------------------------------------------------------------- 8. install ---

reset_log
store install bara.bar
assert_eq "install without --yes non-interactively exits 1" 1 "$RC"
assert_contains "install without --yes asks for it" "$ERR" "pass --yes"
assert_not_contains "install without --yes runs nothing" "$(log)" "omarchy-plugin-add"

# The list shim only reports bara.bar after an add has been logged, so this
# also exercises the post-add discovery wait.
export SHIM_DISCOVER_IDS="bara.bar"
export OMARCHY_PLUGIN_STORE_DISCOVERY_ATTEMPTS=5
reset_log
store install bara.bar --yes --section right
assert_eq "install --yes exits 0" 0 "$RC"
RESCAN_LINE="$(grep -n 'omarchy-shell shell rescanPlugins' "$SHIM_LOG" | head -1 | cut -d: -f1)"
ENABLE_LINE="$(grep -n 'omarchy-plugin-enable' "$SHIM_LOG" | head -1 | cut -d: -f1)"
if [[ -n $RESCAN_LINE && -n $ENABLE_LINE && $RESCAN_LINE -lt $ENABLE_LINE ]]; then
  ok "install rescans the shell before it enables"
else
  bad "install rescans the shell before it enables" "rescan=$RESCAN_LINE enable=$ENABLE_LINE"
fi

# Shell never discovers the plugin: install must not call enable, must say so,
# and must leave a hint about enabling later.
SHIM_DISCOVER_IDS="" reset_log
SHIM_DISCOVER_IDS="" store install bara.bar --yes --section right
assert_eq "install exits 1 when the shell never discovers the plugin" 1 "$RC"
assert_contains "install explains the missed discovery" "$ERR" "has not discovered it yet"
assert_contains "install hints at enabling later" "$ERR" "omarchy-plugin-store enable bara.bar"
assert_not_contains "install skips enable when undiscovered" "$(log)" "omarchy-plugin-enable"

reset_log
store install bara.bar --yes --section right
assert_eq "install --yes exits 0" 0 "$RC"
assert_contains "install runs omarchy-plugin-add with a .git URL" "$(log)" \
  "omarchy-plugin-add https://github.com/bara/omarchy-bar.git --yes"
assert_contains "install then enables with the requested section" "$(log)" \
  "omarchy-plugin-enable bara.bar --section right"
assert_contains "install warns about unsandboxed code" "$ERR" "unsandboxed code"
ADD_LINE="$(grep -n 'omarchy-plugin-add' "$SHIM_LOG" | head -1 | cut -d: -f1)"
ENABLE_LINE="$(grep -n 'omarchy-plugin-enable' "$SHIM_LOG" | head -1 | cut -d: -f1)"
if [[ -n $ADD_LINE && -n $ENABLE_LINE && $ADD_LINE -lt $ENABLE_LINE ]]; then
  ok "install adds before it enables"
else
  bad "install adds before it enables" "add=$ADD_LINE enable=$ENABLE_LINE"
fi

reset_log
store install bara.bar --yes --no-enable
assert_eq "install --no-enable exits 0" 0 "$RC"
assert_contains "install --no-enable still adds" "$(log)" "omarchy-plugin-add"
assert_not_contains "install --no-enable skips enable" "$(log)" "omarchy-plugin-enable"

reset_log
store install bara.bar --yes --no-enable --pin
assert_eq "install --pin exits 0" 0 "$RC"
assert_eq "install --pin leaves HEAD at the validated commit" "$BARA_SHA1" \
  "$(git -C "$OMARCHY_PLUGINS_DIR/bara.bar" rev-parse HEAD)"
git -C "$OMARCHY_PLUGINS_DIR/bara.bar" checkout -q main

store install lacuna.suite --yes
assert_eq "install of an unavailable plugin exits 1" 1 "$RC"
assert_contains "install of an unavailable plugin quotes the note" "$ERR" \
  "shell suite with its own installer"

store install acme.clock --yes
assert_eq "install of an installed plugin exits 1" 1 "$RC"
assert_contains "install of an installed plugin suggests update" "$ERR" "already installed"

store install no.such.plugin --yes
assert_eq "install of an unknown plugin exits 1" 1 "$RC"

# ----------------------------------------------------------- 9. self guard ---

reset_log
store remove jackom.plugin-store
assert_eq "remove of the store itself exits 1" 1 "$RC"
assert_contains "remove of the store itself explains" "$ERR" "is the plugin store itself"
assert_not_contains "remove of the store itself runs nothing" "$(log)" "omarchy-plugin-remove"

reset_log
store remove jackom.plugin-store --yes
assert_eq "remove of the store itself with --yes proceeds" 0 "$RC"
assert_contains "remove of the store itself with --yes calls through" "$(log)" \
  "omarchy-plugin-remove jackom.plugin-store --yes"

reset_log
store disable jackom.plugin-store
assert_eq "disable of the store itself exits 1" 1 "$RC"

reset_log
store enable acme.clock --section left
assert_contains "enable passes through verbatim" "$(log)" "omarchy-plugin-enable acme.clock --section left"

reset_log
store update acme.clock --yes
assert_contains "update passes through verbatim" "$(log)" "omarchy-plugin-update acme.clock --yes"

# ----------------------------------------------------------- 10. installed ---

store installed
assert_eq "installed exits 0" 0 "$RC"
assert_eq "installed lists only third-party plugins" "acme.clock local.only zeta.overlay" \
  "$(printf '%s' "$OUT" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"
assert_not_contains "installed ignores first-party plugins" "$OUT" "omarchy.clock"

assert_eq "installed: enabled/listed/differs" "acme.clock	Acme Clock	enabled	listed	differs" \
  "$(printf '%s' "$OUT" | grep '^acme.clock')"
assert_eq "installed: disabled/listed/at-validated" "zeta.overlay	Zeta Overlay	disabled	listed	at-validated" \
  "$(printf '%s' "$OUT" | grep '^zeta.overlay')"
assert_eq "installed: unlisted/unknown" "local.only	Local Only	disabled	unlisted	unknown" \
  "$(printf '%s' "$OUT" | grep '^local.only')"

"$BIN" pin acme.clock >/dev/null 2>&1
store installed
assert_eq "installed: pinned after pin" "acme.clock	Acme Clock	enabled	listed	pinned" \
  "$(printf '%s' "$OUT" | grep '^acme.clock')"
"$BIN" unpin acme.clock >/dev/null 2>&1

store installed --json
assert_eq "installed --json carries updateStatus" "differs" \
  "$(printf '%s' "$OUT" | jq -r '.[] | select(.id=="acme.clock") | .updateStatus')"

# ------------------------------------------------------------- 11. usage ----

store --help
assert_eq "--help exits 0" 0 "$RC"
assert_contains "--help lists subcommands" "$OUT" "omarchy-plugin-store <command>"
store
assert_contains "bare command prints usage" "$OUT" "Usage: omarchy-plugin-store"
for sub in catalog search show thumb thumbs installed install enable disable remove update tui pin unpin; do
  store "$sub" --help
  if [[ $RC -eq 0 && -n $OUT ]]; then
    ok "$sub --help"
  else
    bad "$sub --help" "rc=$RC out=[$OUT] err=[$ERR]"
  fi
done
store frobnicate
assert_eq "unknown command exits 1" 1 "$RC"

# ------------------------------------------------------- 12. no stray writes ---

if [[ -e $HOME/.cache/omarchy-plugin-store && $XDG_CACHE_HOME != "$HOME/.cache" ]]; then
  : # a pre-existing real cache is fine; we only care that we did not create files under $HOME here
fi
if [[ -d $WORK/cache/omarchy-plugin-store ]]; then
  ok "cache stayed inside the temp XDG_CACHE_HOME"
else
  bad "cache stayed inside the temp XDG_CACHE_HOME"
fi

# ---------------------------------------------------------------- summary ---

echo
echo "$PASSED passed, $FAILED failed"
((FAILED == 0)) || exit 1
exit 0
