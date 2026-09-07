.pragma library

// Pure helpers for Store.qml. Everything here works on the plain array that
// `omarchy-plugin-store search --json` prints, so filtering a 2500-entry
// catalog never costs a process.

function str(value) {
  return value === null || value === undefined ? "" : String(value)
}

function num(value) {
  var n = Number(value)
  return isFinite(n) ? n : 0
}

function parseCatalog(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    return Array.isArray(data) ? data : []
  } catch (e) {
    return []
  }
}

// Same haystack the CLI's --json query searches: id, name, description,
// author and tags, case-insensitively, every term has to match somewhere.
function matchesQuery(row, terms) {
  if (!terms.length) return true
  var hay = (str(row.id) + " " + str(row.name) + " " + str(row.description) + " "
    + str(row.author) + " " + (Array.isArray(row.tags) ? row.tags.join(" ") : "")).toLowerCase()
  for (var i = 0; i < terms.length; i++)
    if (hay.indexOf(terms[i]) === -1) return false
  return true
}

function queryTerms(query) {
  var raw = str(query).toLowerCase().split(/\s+/)
  var out = []
  for (var i = 0; i < raw.length; i++) if (raw[i] !== "") out.push(raw[i])
  return out
}

// Mirrors the CLI's default ordering: stars descending, then name.
function sortRows(rows) {
  return rows.sort(function(a, b) {
    var d = num(b.stars) - num(a.stars)
    if (d !== 0) return d
    var an = str(a.name).toLowerCase()
    var bn = str(b.name).toLowerCase()
    if (an < bn) return -1
    if (an > bn) return 1
    return 0
  })
}

function filterRows(rows, filters) {
  if (!Array.isArray(rows)) return []
  var terms = queryTerms(filters.query)
  var category = str(filters.category).toLowerCase()
  var kind = str(filters.kind).toLowerCase()
  var out = []

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    if (filters.installedOnly && row.installed !== true) continue
    if (filters.verifiedOnly && str(row.verificationStatus) !== "verified") continue
    if (filters.installableOnly && row.installAvailable !== true) continue
    if (category !== "" && str(row.category).toLowerCase() !== category) continue
    if (kind !== "" && str(row.kind).toLowerCase() !== kind) continue
    if (!matchesQuery(row, terms)) continue
    out.push(row)
  }
  return sortRows(out)
}

// Dropdown options built from whatever the catalog actually contains, so a
// new marketplace category shows up without a code change.
function distinctValues(rows, field, allLabel) {
  var seen = ({})
  var values = []
  for (var i = 0; i < rows.length; i++) {
    var v = str(rows[i] ? rows[i][field] : "")
    if (v === "" || seen[v]) continue
    seen[v] = true
    values.push(v)
  }
  values.sort(function(a, b) { return a.toLowerCase() < b.toLowerCase() ? -1 : (a.toLowerCase() > b.toLowerCase() ? 1 : 0) })
  var out = [{ value: "", label: allLabel }]
  for (var j = 0; j < values.length; j++) out.push({ value: values[j], label: values[j] })
  return out
}

function indexOfId(rows, id) {
  if (!id) return -1
  for (var i = 0; i < rows.length; i++) if (rows[i] && rows[i].id === id) return i
  return -1
}

function validatedCommit(row) {
  if (!row) return ""
  var up = str(row.upstreamValidatedCommit)
  return up !== "" ? up : str(row.listingValidatedCommit)
}

function isBarWidget(row) {
  return row ? str(row.kind).toLowerCase().indexOf("bar widget") !== -1 : false
}

function canInstall(row) {
  return !!row && row.installed !== true && row.installAvailable === true
}

// The action Enter runs, matching the TUI's context-aware action menu.
function primaryAction(row, selfId) {
  if (!row) return ""
  if (canInstall(row)) return "install"
  if (row.installed === true) {
    if (row.enabled === true) return str(row.id) === selfId ? "" : "disable"
    return "enable"
  }
  return ""
}

function shortDate(value) {
  var s = str(value)
  return s.length >= 10 ? s.substring(0, 10) : s
}

function metaLine(row) {
  if (!row) return ""
  var parts = []
  if (str(row.author) !== "") parts.push(str(row.author))
  if (str(row.version) !== "") parts.push("v" + str(row.version))
  if (str(row.license) !== "") parts.push(str(row.license))
  parts.push("★ " + num(row.stars))
  return parts.join(" · ")
}

function kindLine(row) {
  if (!row) return ""
  var parts = []
  if (str(row.kind) !== "") parts.push(str(row.kind))
  if (str(row.category) !== "") parts.push(str(row.category))
  if (str(row.status) !== "") parts.push(str(row.status))
  return parts.join(" · ")
}

// The consent text. Every install goes through the CLI with --yes because the
// shell is non-interactive, so this dialog is the only place the user is told
// what they are about to run inside their shell process.
function installConfirmMessage(row, section, pin) {
  if (!row) return ""
  var verification = str(row.verificationStatus)
  if (verification === "") verification = "unknown"
  var lines = [
    "Plugins run as arbitrary, unsandboxed code inside your omarchy-shell process.",
    "",
    str(row.name) + " (" + str(row.id) + ")",
    verification + " · ★" + num(row.stars) + " · updated " + shortDate(row.repositoryUpdatedAt),
    str(row.repo),
    ""
  ]
  var tail = "Install and enable"
  if (section !== "") tail += " in the " + section + " section"
  tail += pin ? ", pinned to the validated commit?" : "?"
  lines.push(tail)
  return lines.join("\n")
}

function removeConfirmMessage(row) {
  if (!row) return ""
  return "Remove " + str(row.id) + " from ~/.config/omarchy/plugins?"
}

// argv vectors only — nothing here is ever handed to a shell.
function installCommand(cli, id, section, pin) {
  var argv = [cli, "install", id, "--yes"]
  if (pin) argv.push("--pin")
  if (section !== "") { argv.push("--section"); argv.push(section) }
  return argv
}

function enableCommand(cli, id, section) {
  var argv = [cli, "enable", id]
  if (section !== "") { argv.push("--section"); argv.push(section) }
  return argv
}

function localSummary(detail, row) {
  var d = detail || row
  if (!d || d.installed !== true) return "not installed"
  var parts = ["installed"]
  parts.push(d.enabled === true ? "enabled" : "disabled")
  if (detail) {
    if (detail.pinned === true) parts.push("pinned")
    else if (str(detail.localBranch) !== "") parts.push("on " + str(detail.localBranch))
  }
  return parts.join(" · ")
}
