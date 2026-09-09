import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "StoreModel.js" as Model

// Plugin Store overlay. Everything it knows comes from the repo's own CLI
// (`bin/omarchy-plugin-store`, --json everywhere); nothing about plugin
// management is reimplemented here. The overlay is a renderer plus a consent
// step, because the CLI has to run with --yes inside a non-interactive shell.
Item {
  id: root

  // Injected by omarchy-shell after the Loader resolves.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string selfId: (manifest && manifest.id) ? String(manifest.id) : "io.github.jackwwg83.plugin-store"
  readonly property string sourceDir: (manifest && manifest.__sourceDir) ? String(manifest.__sourceDir) : ""
  readonly property string cli: sourceDir !== "" ? sourceDir + "/bin/omarchy-plugin-store" : "omarchy-plugin-store"

  property bool opened: false

  // ------------------------------------------------------------ view state

  property string tab: "browse"                 // "browse" | "installed"
  property string query: ""
  property string filterCategory: ""
  property string filterKind: ""
  property bool onlyVerified: false
  property bool onlyInstalled: false
  property bool onlyInstallable: false

  property var catalog: []                      // whole `search --json` array
  property var results: []                      // client-side filtered view
  property bool catalogLoaded: false
  property bool loading: false
  property string loadError: ""
  property string catalogCount: ""
  property string catalogAge: ""

  property int selectedIndex: 0
  property bool cursorActive: false

  // id -> cached image path. Reassigned (never mutated) so delegates rebind.
  property var thumbPaths: ({})
  property var detailPaths: ({})
  property var thumbRequested: ({})
  property var thumbQueue: []
  property var thumbBuffer: ({})

  property var detailInfo: null                 // `show --json` for the cursor row
  property string detailInfoId: ""
  property string pendingDetailId: ""
  property string pendingShowId: ""

  property string installSection: ""            // "" lets the CLI pick the default
  property bool installPin: true

  property bool mutationRunning: false
  property string mutationLabel: ""
  property string mutationStderr: ""
  property string pendingCursorId: ""
  property string statusText: ""

  property bool confirmOpen: false
  property string confirmMode: ""
  property string confirmId: ""

  // ---------------------------------------------------------------- theme

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int gap: Style.spacing.md
  readonly property int controlHeight: Style.spacing.controlHeight
  readonly property int headerHeight: Math.max(Style.space(32), Style.font.heading + Style.spacing.controlPaddingY * 2)

  readonly property int cardWidth: Math.min(Style.space(1180), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(760), panel.height - Style.gapsOut * 2)

  readonly property int cellMinWidth: Style.space(200)
  readonly property int columns: Math.max(1, Math.floor(gridPane.width / cellMinWidth))
  readonly property int cellWidth: Math.max(cellMinWidth, Math.floor(gridPane.width / columns))
  readonly property int cellPad: Style.space(5)
  readonly property int thumbHeight: Math.round((cellWidth - cellPad * 2) * 9 / 16)
  readonly property int cellHeight: thumbHeight + Style.font.body + Style.font.bodySmall + Style.space(24)

  // ------------------------------------------------------- plugin contract

  function open(payloadJson) {
    root.opened = true

    var payload = null
    try {
      var raw = String(payloadJson || "").trim()
      if (raw !== "") payload = JSON.parse(raw)
    } catch (e) {
      payload = null
    }
    if (payload && typeof payload === "object") {
      if (payload.tab === "installed" || payload.tab === "browse") root.tab = payload.tab
      if (typeof payload.query === "string") root.query = payload.query
    }

    if (!root.catalogLoaded && !root.loading) root.reload(false)
    else root.rebuild(true)

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.confirmOpen = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // --------------------------------------------------------------- loading

  function reload(force) {
    if (root.loading) return
    root.loading = true
    root.loadError = ""
    catalogProc.command = force ? [root.cli, "catalog", "--refresh"] : [root.cli, "catalog"]
    catalogProc.running = true
  }

  function runSearch() {
    searchProc.command = [root.cli, "search", "--json"]
    searchProc.running = true
  }

  function applySummary(line) {
    // "2534 plugins · generated 2026-09-06T02:55Z · cache age 3h"
    var text = String(line || "").trim()
    var count = text.match(/^([0-9]+) plugins/)
    root.catalogCount = count ? count[1] : ""
    var age = text.match(/cache age ([^\s·]+)/)
    root.catalogAge = age ? age[1] : ""
  }

  function applyCatalog(rows, keepCursor) {
    root.catalog = rows
    root.catalogLoaded = true
    root.rebuild(keepCursor === true)
  }

  function rebuild(keepCursor) {
    var keepId = keepCursor ? (root.pendingCursorId || root.currentId()) : ""
    root.pendingCursorId = ""

    root.results = Model.filterRows(root.catalog, {
      query: root.query,
      category: root.filterCategory,
      kind: root.filterKind,
      verifiedOnly: root.onlyVerified,
      installedOnly: root.onlyInstalled || root.tab === "installed",
      installableOnly: root.onlyInstallable
    })

    var index = keepId !== "" ? Model.indexOfId(root.results, keepId) : -1
    root.selectedIndex = index >= 0 ? index : 0
    root.cursorActive = root.results.length > 0

    Qt.callLater(function() {
      if (root.results.length > 0) resultGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    })
    root.requestDetail()
  }

  function setQuery(next) {
    root.query = next
    root.rebuild(false)
  }

  function setTab(next) {
    if (root.tab === next) return
    root.tab = next
    root.rebuild(false)
  }

  // ---------------------------------------------------------- cursor model

  function currentRow() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.results.length) return null
    return root.results[root.selectedIndex]
  }

  function currentId() {
    var row = root.currentRow()
    return row ? String(row.id) : ""
  }

  function setIndex(index) {
    if (index < 0 || index >= root.results.length) return
    root.cursorActive = true
    root.selectedIndex = index
    resultGrid.positionViewAtIndex(index, GridView.Contain)
    root.requestDetail()
  }

  function select(delta) {
    if (root.results.length === 0) return
    if (!root.cursorActive) root.setIndex(delta < 0 ? root.results.length - 1 : 0)
    else root.setIndex((root.selectedIndex + delta + root.results.length) % root.results.length)
  }

  function selectRow(delta) {
    if (root.results.length === 0) return
    if (!root.cursorActive) {
      root.setIndex(delta < 0 ? root.results.length - 1 : 0)
      return
    }
    var next = root.selectedIndex + delta * root.columns
    if (next < 0) next = 0
    if (next >= root.results.length) next = root.results.length - 1
    root.setIndex(next)
  }

  function selectPage(delta) {
    if (root.results.length === 0) return
    if (!root.cursorActive) {
      root.setIndex(delta < 0 ? root.results.length - 1 : 0)
      return
    }
    var rows = Math.max(1, Math.floor(resultGrid.height / root.cellHeight))
    var next = root.selectedIndex + delta * root.columns * rows
    if (next < 0) next = 0
    if (next >= root.results.length) next = root.results.length - 1
    root.setIndex(next)
  }

  // ------------------------------------------------------------ thumbnails

  function requestThumb(id, hasPreview) {
    if (!root.opened || !id || hasPreview !== true) return
    if (root.thumbPaths[id] !== undefined) return
    if (root.thumbRequested[id] === true) return
    root.thumbRequested[id] = true
    root.thumbQueue.push(id)
    root.pumpThumbs()
  }

  function pumpThumbs() {
    if (thumbsProc.running || root.thumbQueue.length === 0) return
    var batch = root.thumbQueue.splice(0, 24)
    thumbsProc.command = [root.cli, "thumbs", "--tsv"].concat(batch)
    thumbsProc.running = true
  }

  function bufferThumb(line) {
    var parts = String(line || "").split("\t")
    if (parts.length < 2 || parts[0] === "" || parts[1] === "") return
    root.thumbBuffer[parts[0]] = parts[1]
    thumbFlushTimer.restart()
  }

  function flushThumbs() {
    var pending = false
    for (var probe in root.thumbBuffer) { pending = true; break }
    if (!pending) return
    var next = ({})
    for (var a in root.thumbPaths) next[a] = root.thumbPaths[a]
    for (var b in root.thumbBuffer) next[b] = root.thumbBuffer[b]
    root.thumbBuffer = ({})
    root.thumbPaths = next
  }

  function thumbFor(id) {
    var path = root.thumbPaths[id]
    return path ? Util.fileUrl(path) : ""
  }

  // ----------------------------------------------------------- detail pane

  function requestDetail() {
    detailTimer.restart()
  }

  function requestDetailNow() {
    if (!root.opened) return
    var row = root.currentRow()
    if (!row) {
      root.detailInfo = null
      root.detailInfoId = ""
      return
    }
    var id = String(row.id)

    if (row.hasPreview === true && root.detailPaths[id] === undefined && !detailProc.running) {
      root.pendingDetailId = id
      detailProc.command = [root.cli, "thumb", id, "--detail"]
      detailProc.running = true
    }

    if (row.installed === true) {
      if (root.detailInfoId !== id && !showProc.running) {
        root.pendingShowId = id
        showProc.command = [root.cli, "show", id, "--json"]
        showProc.running = true
      }
    } else if (root.detailInfoId !== id) {
      root.detailInfo = null
      root.detailInfoId = id
    }
  }

  function setDetailPath(id, path) {
    var next = ({})
    for (var k in root.detailPaths) next[k] = root.detailPaths[k]
    next[id] = path
    root.detailPaths = next
  }

  function detailImageFor(row) {
    if (!row) return ""
    var id = String(row.id)
    var detail = root.detailPaths[id]
    if (detail) return Util.fileUrl(detail)
    return root.thumbFor(id)
  }

  // ------------------------------------------------------------- mutations

  function setStatus(text) {
    root.statusText = String(text || "")
    if (root.statusText !== "") statusTimer.restart()
  }

  function runMutation(argv, label) {
    if (root.mutationRunning || !argv || argv.length === 0) return
    root.mutationRunning = true
    root.mutationLabel = label
    root.mutationStderr = ""
    root.pendingCursorId = root.currentId()
    mutationProc.command = argv
    mutationProc.running = true
    root.setStatus(label + "…")
  }

  function effectivePin(row) {
    return root.installPin && Model.validatedCommit(row) !== ""
  }

  function askInstall() {
    var row = root.currentRow()
    if (!Model.canInstall(row) || root.mutationRunning) return
    root.confirmMode = "install"
    root.confirmId = String(row.id)
    confirmDialog.confirmText = "Install"
    confirmDialog.message = Model.installConfirmMessage(row, root.installSection, root.effectivePin(row))
    root.confirmOpen = true
  }

  function askRemove() {
    var row = root.currentRow()
    if (!row || row.installed !== true || root.mutationRunning) return
    if (String(row.id) === root.selfId) {
      root.setStatus("The plugin store cannot remove itself")
      return
    }
    root.confirmMode = "remove"
    root.confirmId = String(row.id)
    confirmDialog.confirmText = "Remove"
    confirmDialog.message = Model.removeConfirmMessage(row)
    root.confirmOpen = true
  }

  function confirmAccepted() {
    var mode = root.confirmMode
    var id = root.confirmId
    root.confirmOpen = false
    root.confirmMode = ""

    var row = root.currentRow()
    if (!row || String(row.id) !== id) row = null

    if (mode === "install" && row)
      root.runMutation(Model.installCommand(root.cli, id, root.installSection, root.effectivePin(row)), "Install " + id)
    else if (mode === "remove")
      root.runMutation([root.cli, "remove", id, "--yes"], "Remove " + id)

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmCanceled() {
    root.confirmOpen = false
    root.confirmMode = ""
    root.setStatus("Canceled")
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function toggleEnabled() {
    var row = root.currentRow()
    if (!row || row.installed !== true || root.mutationRunning) return
    var id = String(row.id)
    if (row.enabled === true) {
      if (id === root.selfId) {
        root.setStatus("The plugin store cannot disable itself")
        return
      }
      root.runMutation([root.cli, "disable", id], "Disable " + id)
    } else {
      root.runMutation(Model.enableCommand(root.cli, id, root.installSection), "Enable " + id)
    }
  }

  function updateCurrent() {
    var row = root.currentRow()
    if (!row || row.installed !== true) return
    root.runMutation([root.cli, "update", String(row.id), "--yes"], "Update " + row.id)
  }

  function togglePinned() {
    var row = root.currentRow()
    if (!row || row.installed !== true) return
    var pinned = root.detailInfo && root.detailInfo.id === row.id && root.detailInfo.pinned === true
    root.runMutation([root.cli, pinned ? "unpin" : "pin", String(row.id)],
      (pinned ? "Unpin " : "Pin ") + row.id)
  }

  function openRepo() {
    var row = root.currentRow()
    if (!row || String(row.repo) === "") return
    Util.execArgv(["xdg-open", String(row.repo)])
    root.setStatus("Opening " + row.repo)
  }

  function primaryAction() {
    var row = root.currentRow()
    var action = Model.primaryAction(row, root.selfId)
    if (action === "install") root.askInstall()
    else if (action === "enable" || action === "disable") root.toggleEnabled()
  }

  // --------------------------------------------------------------- filters

  function categoryOptions() { return Model.distinctValues(root.catalog, "category", "All categories") }
  function kindOptions() { return Model.distinctValues(root.catalog, "kind", "All kinds") }

  // ------------------------------------------------------------- processes

  Process {
    id: catalogProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySummary(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") console.info("plugin-store: catalog:", String(text).trim())
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.catalogLoaded) {
        root.loading = false
        root.loadError = "Could not reach the marketplace catalog."
        return
      }
      root.runSearch()
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        var rows = Model.parseCatalog(raw)
        if (rows.length === 0 && !root.catalogLoaded) {
          root.loadError = "The catalog came back empty."
          return
        }
        root.applyCatalog(rows, true)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") console.info("plugin-store: search:", String(text).trim())
    }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0 && !root.catalogLoaded)
        root.loadError = "omarchy-plugin-store search failed (exit " + exitCode + ")."
    }
  }

  Process {
    id: thumbsProc
    stdout: SplitParser {
      onRead: function(line) { root.bufferThumb(line) }
    }
    onExited: function() {
      root.flushThumbs()
      root.pumpThumbs()
    }
  }

  Process {
    id: detailProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").trim()
        if (root.pendingDetailId !== "") root.setDetailPath(root.pendingDetailId, path)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.pendingDetailId !== "" && root.detailPaths[root.pendingDetailId] === undefined)
        root.setDetailPath(root.pendingDetailId, "")
      root.pendingDetailId = ""
      Qt.callLater(root.requestDetailNow)
    }
  }

  Process {
    id: showProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var parsed = JSON.parse(raw)
          root.detailInfo = parsed
          root.detailInfoId = String(parsed.id || root.pendingShowId)
        } catch (e) {
          console.warn("plugin-store: show returned unparsable JSON")
        }
      }
    }
    onExited: function() {
      root.pendingShowId = ""
      Qt.callLater(root.requestDetailNow)
    }
  }

  Process {
    id: mutationProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n")
        for (var i = lines.length - 1; i >= 0; i--) {
          var line = lines[i].trim()
          if (line !== "") { root.mutationStderr = line; break }
        }
      }
    }
    onExited: function(exitCode) {
      root.mutationRunning = false
      if (exitCode === 0) root.setStatus(root.mutationLabel + " — done")
      else root.setStatus(root.mutationStderr !== "" ? root.mutationStderr : root.mutationLabel + " failed")
      root.detailInfoId = ""
      root.detailInfo = null
      root.runSearch()
    }
  }

  Timer { id: detailTimer; interval: 150; onTriggered: root.requestDetailNow() }
  Timer { id: thumbFlushTimer; interval: 90; onTriggered: root.flushThumbs() }
  Timer { id: statusTimer; interval: 4000; onTriggered: root.statusText = "" }

  onOpenedChanged: {
    if (root.opened) root.pumpThumbs()
    else {
      detailTimer.stop()
      statusTimer.stop()
      root.statusText = ""
    }
  }

  // ------------------------------------------------------------------ view

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-plugin-store"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.confirmOpen) {
            if (confirmDialog.handleKey(event)) event.accepted = true
            else event.accepted = true          // the dialog owns every key while open
            return
          }
          if (categoryDropdown.popupOpen || kindDropdown.popupOpen || sectionDropdown.popupOpen) return

          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

          if (event.key === Qt.Key_Escape) {
            if (root.query !== "") root.setQuery("")
            else root.dismiss()
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_R) {
            root.reload(true)
            root.setStatus("Refreshing catalog…")
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_O) {
            root.openRepo()
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_V) {
            root.onlyVerified = !root.onlyVerified
            root.rebuild(false)
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.setTab(root.tab === "browse" ? "installed" : "browse")
            event.accepted = true
          } else if (Util.editsFilter(event, root.query)) {
            root.setQuery(Util.editedFilter(event, root.query))
            event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.selectRow(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.selectRow(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.selectPage(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.selectPage(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.setIndex(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.setIndex(root.results.length - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.primaryAction()
            event.accepted = true
          } else if (!ctrl && event.text && event.text.length === 1
            && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setQuery(root.query + event.text)
            event.accepted = true
          }
        }
      }

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ------------------------------------------------------- header row

        Item {
          id: header
          anchors { top: parent.top; left: parent.left; right: parent.right }
          height: root.headerHeight

          Row {
            id: headerActions
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: Style.spacing.controlGap

            Button {
              text: "Browse"
              fontFamily: root.fontFamily
              foreground: root.foreground
              selected: root.tab === "browse"
              height: root.controlHeight
              onClicked: root.setTab("browse")
            }

            Button {
              text: "Installed"
              fontFamily: root.fontFamily
              foreground: root.foreground
              selected: root.tab === "installed"
              height: root.controlHeight
              onClicked: root.setTab("installed")
            }

            Button {
              iconText: "󰑐"
              fontFamily: root.fontFamily
              foreground: root.foreground
              iconSpinning: root.loading
              tooltipText: "Refresh the marketplace catalog (Ctrl+R)"
              height: root.controlHeight
              onClicked: { root.reload(true); root.setStatus("Refreshing catalog…") }
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.catalogCount === "" ? "" : (root.catalogCount + (root.catalogAge === "" ? "" : " · " + root.catalogAge))
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          BorderSurface {
            id: searchBox
            anchors {
              left: parent.left
              right: headerActions.left
              rightMargin: root.gap
              verticalCenter: parent.verticalCenter
            }
            height: root.controlHeight
            radius: root.cornerRadius
            color: Style.controlFill(false, false, root.foreground, Color.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

            Text {
              textFormat: Text.PlainText
              anchors {
                left: parent.left
                leftMargin: parent.contentLeftInset + Style.spacing.controlPaddingX
                right: parent.right
                rightMargin: parent.contentRightInset + Style.spacing.controlPaddingX
                verticalCenter: parent.verticalCenter
              }
              text: root.query !== "" ? root.query : "Type to search the marketplace…"
              color: root.foreground
              opacity: root.query !== "" ? 1 : 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }
        }

        // ------------------------------------------------------- filter row

        Item {
          id: filterRow
          anchors {
            top: header.bottom
            topMargin: root.gap
            left: parent.left
            right: parent.right
          }
          height: root.controlHeight

          Row {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            spacing: Style.spacing.controlGap

            Dropdown {
              id: categoryDropdown
              width: Style.space(170)
              showLabel: false
              rowHeight: root.controlHeight
              value: root.filterCategory
              options: root.categoryOptions()
              fontFamily: root.fontFamily
              onChanged: function(value) {
                root.filterCategory = value
                root.rebuild(false)
              }
            }

            Dropdown {
              id: kindDropdown
              width: Style.space(150)
              showLabel: false
              rowHeight: root.controlHeight
              value: root.filterKind
              options: root.kindOptions()
              fontFamily: root.fontFamily
              onChanged: function(value) {
                root.filterKind = value
                root.rebuild(false)
              }
            }

            Button {
              text: "Verified"
              iconText: "✓"
              fontFamily: root.fontFamily
              foreground: root.foreground
              bordered: true
              selected: root.onlyVerified
              height: root.controlHeight
              tooltipText: "Only marketplace-verified plugins (Ctrl+V)"
              onClicked: { root.onlyVerified = !root.onlyVerified; root.rebuild(false) }
            }

            Button {
              text: "Installed"
              fontFamily: root.fontFamily
              foreground: root.foreground
              bordered: true
              selected: root.onlyInstalled || root.tab === "installed"
              height: root.controlHeight
              onClicked: { root.onlyInstalled = !root.onlyInstalled; root.rebuild(false) }
            }

            Button {
              text: "Installable"
              fontFamily: root.fontFamily
              foreground: root.foreground
              bordered: true
              selected: root.onlyInstallable
              height: root.controlHeight
              onClicked: { root.onlyInstallable = !root.onlyInstallable; root.rebuild(false) }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            text: root.results.length + (root.results.length === 1 ? " result" : " results")
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ------------------------------------------------------------ body

        Item {
          id: body
          anchors {
            top: filterRow.bottom
            topMargin: root.gap
            bottom: footer.top
            bottomMargin: root.gap
            left: parent.left
            right: parent.right
          }

          Item {
            id: gridPane
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
            width: Math.floor(parent.width * 0.6) - Math.floor(root.gap / 2)

            GridView {
              id: resultGrid
              anchors.fill: parent
              visible: root.results.length > 0
              model: root.results
              clip: true
              cacheBuffer: root.cellHeight * 2
              cellWidth: root.cellWidth
              cellHeight: root.cellHeight
              boundsBehavior: Flickable.StopAtBounds

              delegate: Item {
                id: cell
                required property int index
                required property var modelData

                readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
                readonly property string cellId: modelData ? String(modelData.id) : ""

                width: root.cellWidth
                height: root.cellHeight

                Component.onCompleted: root.requestThumb(cellId, modelData ? modelData.hasPreview : false)
                onModelDataChanged: root.requestThumb(cellId, modelData ? modelData.hasPreview : false)

                BorderSurface {
                  anchors.fill: parent
                  anchors.margins: Math.floor(root.cellPad / 2)
                  radius: root.cornerRadius
                  color: cell.hasCursor ? root.selectedBackground : "transparent"
                  borderSpec: cell.hasCursor
                    ? Border.flat(root.selectedText, Style.normalBorderWidth)
                    : Border.none()

                  Column {
                    anchors.fill: parent
                    anchors.margins: Math.floor(root.cellPad / 2)
                    spacing: Style.spacing.xs

                    Rectangle {
                      id: thumbFrame
                      width: parent.width
                      height: root.thumbHeight
                      radius: root.cornerRadius
                      clip: true
                      color: Util.alpha(Color.accent, 0.14)

                      Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        visible: thumbImage.status !== Image.Ready
                        text: cell.modelData ? String(cell.modelData.initials || "") : ""
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.display
                        font.bold: true
                      }

                      Image {
                        id: thumbImage
                        anchors.fill: parent
                        source: root.thumbFor(cell.cellId)
                        asynchronous: true
                        cache: true
                        smooth: true
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: root.cellWidth * 2
                        visible: status === Image.Ready
                      }
                    }

                    Item {
                      width: parent.width
                      height: Style.font.body + Style.space(3)

                      Text {
                        textFormat: Text.PlainText
                        anchors {
                          left: parent.left
                          right: verifiedBadge.left
                          rightMargin: verifiedBadge.visible ? Style.spacing.xs : 0
                          verticalCenter: parent.verticalCenter
                        }
                        text: cell.modelData ? String(cell.modelData.name || cell.modelData.id) : ""
                        color: cell.hasCursor ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }

                      Text {
                        id: verifiedBadge
                        textFormat: Text.PlainText
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        visible: cell.modelData && cell.modelData.verificationStatus === "verified"
                        text: "✓"
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    Item {
                      width: parent.width
                      height: Style.font.bodySmall + Style.space(3)

                      Text {
                        textFormat: Text.PlainText
                        anchors {
                          left: parent.left
                          right: cellBadges.left
                          rightMargin: Style.spacing.xs
                          verticalCenter: parent.verticalCenter
                        }
                        text: cell.modelData ? String(cell.modelData.kind || cell.modelData.category || "") : ""
                        color: root.foreground
                        opacity: 0.6
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }

                      Row {
                        id: cellBadges
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: Style.spacing.xs

                        Text {
                          textFormat: Text.PlainText
                          visible: cell.modelData && Number(cell.modelData.stars || 0) > 0
                          text: "★ " + (cell.modelData ? Number(cell.modelData.stars || 0) : 0)
                          color: root.foreground
                          opacity: 0.7
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }

                        Text {
                          textFormat: Text.PlainText
                          visible: cell.modelData && cell.modelData.installed === true
                          text: "●"
                          color: (cell.modelData && cell.modelData.enabled === true) ? Color.accent : root.foreground
                          opacity: (cell.modelData && cell.modelData.enabled === true) ? 1 : 0.6
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.setIndex(cell.index)
                    onClicked: root.setIndex(cell.index)
                    onDoubleClicked: { root.setIndex(cell.index); root.primaryAction() }
                  }
                }
              }
            }

            Column {
              anchors.centerIn: parent
              width: parent.width
              spacing: Style.spacing.lg
              visible: root.results.length === 0

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.loading ? "Loading catalog…"
                  : root.loadError !== "" ? root.loadError
                  : root.query !== "" ? "No plugins match “" + root.query + "”"
                  : "No plugins to show"
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WordWrap
              }
            }
          }

          // --------------------------------------------------- detail pane

          Item {
            id: detailPane
            anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
            width: parent.width - gridPane.width - root.gap

            readonly property var row: root.currentRow()
            readonly property var info: (root.detailInfo && detailPane.row
              && String(root.detailInfo.id) === String(detailPane.row.id)) ? root.detailInfo : null
            readonly property bool isSelf: detailPane.row && String(detailPane.row.id) === root.selfId
            readonly property bool pinned: detailPane.info ? detailPane.info.pinned === true : false
            readonly property bool canPin: detailPane.row && detailPane.row.installed === true
              && Model.validatedCommit(detailPane.row) !== ""

            visible: detailPane.row !== null

            // Actions sit on the floor of the pane so the metadata above can
            // grow or clip without ever pushing them out of the card.
            Column {
              id: actionArea
              anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
              spacing: Style.spacing.sm

              Dropdown {
                id: sectionDropdown
                width: Style.space(200)
                showLabel: false
                rowHeight: root.controlHeight
                visible: Model.canInstall(detailPane.row) && Model.isBarWidget(detailPane.row)
                value: root.installSection
                fontFamily: root.fontFamily
                options: [
                  { value: "", label: "Bar section: default" },
                  { value: "left", label: "Bar section: left" },
                  { value: "center", label: "Bar section: center" },
                  { value: "right", label: "Bar section: right" }
                ]
                onChanged: function(value) { root.installSection = value }
              }

              Toggle {
                id: pinToggle
                width: parent.width
                visible: Model.canInstall(detailPane.row)
                label: "Pin to verified commit"
                description: Model.validatedCommit(detailPane.row) !== ""
                  ? "Check out " + Model.validatedCommit(detailPane.row).substring(0, 7) + " instead of branch HEAD"
                  : "This plugin has no validated commit to pin to"
                checked: root.installPin && Model.validatedCommit(detailPane.row) !== ""
                opacity: Model.validatedCommit(detailPane.row) !== "" ? 1 : 0.5
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (Model.validatedCommit(detailPane.row) === "") root.setStatus("No validated commit to pin to")
                  else root.installPin = !root.installPin
                }
              }

              Flow {
                width: parent.width
                spacing: Style.spacing.controlGap

                Button {
                  text: "Install"
                  fontFamily: root.fontFamily
                  foreground: root.foreground
                  bordered: true
                  height: root.controlHeight
                  visible: Model.canInstall(detailPane.row)
                  opacity: root.mutationRunning ? 0.45 : 1
                  onClicked: root.askInstall()
                }

                Button {
                  text: detailPane.row && detailPane.row.enabled === true ? "Disable" : "Enable"
                  fontFamily: root.fontFamily
                  foreground: root.foreground
                  bordered: true
                  height: root.controlHeight
                  visible: detailPane.row && detailPane.row.installed === true
                  opacity: (root.mutationRunning
                    || (detailPane.isSelf && detailPane.row && detailPane.row.enabled === true)) ? 0.45 : 1
                  tooltipText: detailPane.isSelf && detailPane.row && detailPane.row.enabled === true
                    ? "The plugin store cannot disable itself" : ""
                  onClicked: root.toggleEnabled()
                }

                Button {
                  text: "Update"
                  fontFamily: root.fontFamily
                  foreground: root.foreground
                  bordered: true
                  height: root.controlHeight
                  visible: detailPane.row && detailPane.row.installed === true
                  opacity: root.mutationRunning ? 0.45 : 1
                  onClicked: root.updateCurrent()
                }

                Button {
                  text: detailPane.pinned ? "Unpin" : "Pin"
                  fontFamily: root.fontFamily
                  foreground: root.foreground
                  bordered: true
                  height: root.controlHeight
                  visible: detailPane.canPin
                  opacity: root.mutationRunning ? 0.45 : 1
                  onClicked: root.togglePinned()
                }

                Button {
                  text: "Remove"
                  fontFamily: root.fontFamily
                  foreground: detailPane.isSelf ? root.foreground : Color.urgent
                  bordered: true
                  height: root.controlHeight
                  visible: detailPane.row && detailPane.row.installed === true
                  opacity: (root.mutationRunning || detailPane.isSelf) ? 0.45 : 1
                  tooltipText: detailPane.isSelf ? "The plugin store cannot remove itself" : ""
                  onClicked: root.askRemove()
                }

                Button {
                  text: "Open repo"
                  fontFamily: root.fontFamily
                  foreground: root.foreground
                  bordered: true
                  height: root.controlHeight
                  visible: detailPane.row && String(detailPane.row.repo || "") !== ""
                  onClicked: root.openRepo()
                }
              }
            }

            Item {
              anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                bottom: actionArea.top
                bottomMargin: root.gap
              }
              clip: true

              Column {
                anchors { top: parent.top; left: parent.left; right: parent.right }
                spacing: Style.spacing.sm

                Rectangle {
                  width: parent.width
                  height: Math.round(parent.width * 9 / 16)
                  radius: root.cornerRadius
                  clip: true
                  color: Util.alpha(Color.accent, 0.14)

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: detailImage.status !== Image.Ready
                    text: detailPane.row ? String(detailPane.row.initials || "") : ""
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.displayLarge
                    font.bold: true
                  }

                  Image {
                    id: detailImage
                    anchors.fill: parent
                    source: root.detailImageFor(detailPane.row)
                    asynchronous: true
                    cache: true
                    smooth: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: detailPane.width * 2
                    visible: status === Image.Ready
                  }
                }

                Item {
                  width: parent.width
                  height: Style.font.heading + Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    anchors {
                      left: parent.left
                      right: detailVerified.left
                      rightMargin: detailVerified.visible ? Style.spacing.xs : 0
                      verticalCenter: parent.verticalCenter
                    }
                    text: detailPane.row ? String(detailPane.row.name || detailPane.row.id) : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    id: detailVerified
                    textFormat: Text.PlainText
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    visible: detailPane.row && detailPane.row.verificationStatus === "verified"
                    text: "✓ verified"
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: Model.metaLine(detailPane.row)
                  color: root.foreground
                  opacity: 0.75
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: text !== ""
                  text: Model.kindLine(detailPane.row)
                  color: root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: text !== ""
                  text: detailPane.row ? String(detailPane.row.description || "") : ""
                  color: root.foreground
                  opacity: 0.9
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  maximumLineCount: 4
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: text !== ""
                  text: (detailPane.row && Array.isArray(detailPane.row.tags)) ? detailPane.row.tags.join("  ") : ""
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: text !== ""
                  text: detailPane.row ? String(detailPane.row.repo || "") : ""
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }

                PanelSectionHeader {
                  width: parent.width
                  text: "LOCAL"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: Model.localSummary(detailPane.info, detailPane.row)
                  color: root.foreground
                  opacity: 0.8
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: text !== ""
                  text: detailPane.row && detailPane.row.installed !== true
                    && detailPane.row.installAvailable !== true
                    ? String(detailPane.row.installNote || "")
                    : ""
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        // ------------------------------------------------------------ footer

        Item {
          id: footer
          anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
          height: Style.font.bodySmall + Style.space(6)

          Text {
            textFormat: Text.PlainText
            anchors { left: parent.left; right: statusLabel.left; rightMargin: root.gap; verticalCenter: parent.verticalCenter }
            text: "esc close · ↑↓←→ move · enter primary action · tab tabs · ctrl+r refresh · ctrl+o repo · ctrl+v verified"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: statusLabel
            textFormat: Text.PlainText
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            width: Math.min(implicitWidth, Math.round(footer.width * 0.45))
            horizontalAlignment: Text.AlignRight
            text: root.statusText
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        cancelText: "Cancel"
        background: root.background
        foreground: root.foreground
        scrim: root.scrim
        selectedBackground: root.selectedBackground
        selectedText: root.selectedText
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        onCanceled: root.confirmCanceled()
        onConfirmed: root.confirmAccepted()
      }
    }
  }
}
