import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property bool opened: false
  property string query: ""
  property int selectedIndex: 0
  property bool searching: false

  // Query currently in flight, and one waiting for it to finish. Typing is
  // faster than localsearch, so a keystroke arriving mid-query parks itself
  // here instead of racing a second process against the first.
  property string activeQuery: ""
  property string queuedQuery: ""
  property bool hasQueued: false

  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("search.sh").toString().replace(/^file:\/\//, ""))
  readonly property int minQueryLength: 2

  // Deletes run one at a time through a queue: hold Delete down and the rows
  // are removed in order instead of racing several processes at once.
  property var deleteQueue: []
  property string activeDeletePath: ""
  property bool confirmDeleteOpen: false
  property string pendingDeletePath: ""
  property string pendingDeleteName: ""

  // Shares the [menu] surface tokens, so any theme that styles the Omarchy
  // menu styles this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(38), Style.font.display + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Math.max(Style.space(20), Style.font.caption + Style.space(6))
  property int contentSpacing: Style.spacing.md
  // --- Preview pane --------------------------------------------------------
  //
  // Tab opens a pane on the right. A folder lists its contents there and the
  // keyboard moves into it; anything else is only previewed, with the keyboard
  // staying in the results.
  property bool previewOpen: false
  property string folderPath: "" // "" = pane is not showing a listing
  property int folderIndex: 0
  property bool folderFocused: false
  readonly property string listScript: decodeURIComponent(Qt.resolvedUrl("list.sh").toString().replace(/^file:\/\//, ""))
  readonly property string revealScript: decodeURIComponent(Qt.resolvedUrl("reveal.sh").toString().replace(/^file:\/\//, ""))
  property string activeFolderPath: ""
  property string queuedFolderPath: ""
  property bool hasQueuedFolder: false

  // Widening the card beats splitting the old width: at 950 px a 42% pane
  // would squeeze the result rows into ellipses.
  property int cardWidth: Math.min(Style.space(root.previewOpen ? 1340 : 950), panel.width - Style.gapsOut * 2)
  property int previewWidth: root.previewOpen ? Math.round(root.cardWidth * 0.42) : 0
  property int cardHeight: Math.min(Style.space(620), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(54), Style.font.title + Style.font.caption + Style.spacing.rowPaddingX * 2)
  // Square slot the full height of a row, so a thumbnail fills it edge to edge.
  property int iconWidth: root.rowHeight
  property int thumbSize: root.rowHeight
  // Above this, a thumbnail costs more than it is worth at this size.
  readonly property int maxThumbBytes: 25 * 1024 * 1024
  // Wide enough for "yesterday HH:mm", the longest string formatMtime
  // produces: 110 px at the date's font size, measured in the shell's
  // monospace face.
  property int dateWidth: Style.space(118)

  // A `query` in the payload opens the overlay with the search already
  // running, so a menu entry or script can hand off a term:
  //   omarchy-shell shell summon io.github.corck.filesearch '{"query":"rechnung"}'
  function open(payloadJson) {
    var initial = ""
    try {
      var payload = JSON.parse(payloadJson || "{}")
      if (payload && typeof payload.query === "string")
        initial = payload.query
    } catch (e) {}

    root.opened = true
    root.query = ""
    root.selectedIndex = 0
    root.searching = false
    resultsModel.clear()
    root.closePreview()
    root.disarmPointer()

    if (initial)
      root.setQuery(initial)

    Qt.callLater(function () {
      keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    debounce.stop()
    resultsModel.clear()
    root.closePreview()
  }

  function toggle() {
    if (root.opened)
      root.close()
    else
      root.open("{}")
  }

  // --- Search plumbing -----------------------------------------------------

  function setQuery(next) {
    root.query = next
    root.selectedIndex = 0
    root.disarmPointer()

    if (root.trimmedTerms(next).length < root.minQueryLength) {
      debounce.stop()
      root.searching = false
      resultsModel.clear()
      return
    }

    debounce.restart()
  }

  // The part of the query localsearch actually sees, prefix stripped.
  function trimmedTerms(text) {
    var body = /^[fodi]:/.test(text) ? text.slice(2) : text
    return body.replace(/^\s+|\s+$/g, "")
  }

  function modeLabel(text) {
    if (text.indexOf("f:") === 0)
      return "Filenames"
    if (text.indexOf("o:") === 0)
      return "Folders"
    if (text.indexOf("d:") === 0)
      return "Documents"
    if (text.indexOf("i:") === 0)
      return "Images"
    return "Full text + name"
  }

  function startSearch() {
    if (searchProc.running) {
      root.queuedQuery = root.query
      root.hasQueued = true
      searchProc.running = false // SIGTERM; onExited picks the queued query up
      return
    }
    root.launchQuery(root.query)
  }

  function launchQuery(text) {
    root.activeQuery = text
    root.searching = true
    searchProc.command = [root.scriptPath, text]
    searchProc.running = true
  }

  function applyResults(text) {
    // A result that arrives after the query moved on describes the wrong
    // search; drop it rather than flashing stale rows.
    if (root.activeQuery !== root.query)
      return

    root.searching = false
    resultsModel.clear()

    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i])
        continue
      var cols = lines[i].split("\t")
      if (cols.length < 6)
        continue
      resultsModel.append({
        kind: cols[0],
        name: cols[1],
        dir: cols[2],
        path: cols[3],
        mtime: parseInt(cols[4], 10) || 0,
        size: parseInt(cols[5], 10) || 0
      })
    }

    root.selectedIndex = 0
    root.resultsRevision++

    // Fresh rows slide in under a pointer that never moved. Without re-arming
    // the gate, whichever row lands beneath the cursor steals the selection
    // and Enter opens a file the user never picked.
    root.disarmPointer()

    root.syncPreview()

    Qt.callLater(function () {
      if (resultsModel.count > 0)
        resultList.positionViewAtIndex(0, ListView.Contain)
    })
  }

  // --- Selection -----------------------------------------------------------

  function select(delta) {
    if (resultsModel.count === 0)
      return
    root.disarmPointer()
    root.selectedIndex = (root.selectedIndex + delta + resultsModel.count) % resultsModel.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    root.syncPreview()
  }

  function selectAbsolute(index) {
    if (resultsModel.count === 0)
      return
    root.disarmPointer()
    root.selectedIndex = Math.max(0, Math.min(index, resultsModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    root.syncPreview()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse))
      return
    root.selectedIndex = index
    root.syncPreview()
  }

  // --- Actions -------------------------------------------------------------

  // ListModel.get() hands back a live reference to the row, not a copy. Every
  // action closes the overlay before launching, close() clears the model, and
  // the reference then reads back empty -- so the command was built with an
  // empty path and Nautilus fell back to $HOME. Snapshot the fields instead.
  function snapshot(model, index) {
    if (!model || index < 0 || index >= model.count)
      return null

    var row = model.get(index)
    return {
      kind: String(row.kind),
      name: String(row.name),
      dir: String(row.dir),
      path: String(row.path),
      size: Number(row.size) || 0,
      mtime: Number(row.mtime) || 0
    }
  }

  function rowAt(index) {
    return root.snapshot(resultsModel, index)
  }

  // Whichever pane holds the keyboard owns the actions.
  function currentRow() {
    return root.folderFocused ? root.snapshot(folderModel, root.folderIndex) : root.snapshot(resultsModel, root.selectedIndex)
  }

  // Every action goes through execArgv: paths come from the filesystem and
  // may contain anything, so they must never be re-tokenized by a shell.
  function openPath(index) {
    var row = root.currentRow()
    if (!row)
      return
    root.close()
    Util.execArgv(["setsid", "uwsm-app", "--", "xdg-open", row.path])
  }

  function openFolder(index) {
    var row = root.currentRow()
    if (!row)
      return
    root.close()

    // Via org.freedesktop.FileManager1, so this works on any desktop and
    // still preselects the file -- something xdg-open cannot express.
    var dir = row.kind === "dir" ? row.path : row.path.replace(/\/[^\/]*$/, "")
    Util.execArgv([root.revealScript, row.kind === "dir" ? "ShowFolders" : "ShowItems", root.dbusUri(row.path), dir])
  }

  function openTerminal(index) {
    var row = root.currentRow()
    if (!row)
      return
    root.close()
    var dir = row.kind === "dir" ? row.path : row.path.replace(/\/[^\/]*$/, "")
    Util.execArgv(["setsid", "uwsm-app", "--", "xdg-terminal-exec", "--dir=" + dir])
  }

  function openEditor(index) {
    var row = root.currentRow()
    if (!row)
      return
    root.close()
    // Not wrapped in uwsm-app: omarchy-launch-editor already does its own
    // `setsid uwsm-app --` on both the TUI and the GUI branch.
    Util.execArgv(["omarchy-launch-editor", row.path])
  }

  function copyPath(index) {
    var row = root.currentRow()
    if (!row)
      return
    root.close()
    // No "--" separator: wl-copy does not document one, and every path here
    // is absolute, so it can never be read as an option.
    Util.execArgv(["wl-copy", row.path])
  }

  // --- Delete --------------------------------------------------------------
  //
  // Unlike every other action this one keeps the overlay open, which is the
  // whole point: search once, clear out several hits, carry on.

  function trashIndex(index) {
    var row = root.currentRow()
    if (row)
      root.enqueueDelete(row.path, false)
  }

  function requestPermanentDelete(index) {
    var row = root.currentRow()
    if (!row)
      return

    root.pendingDeletePath = row.path
    root.pendingDeleteName = row.name
    confirmDelete.selectedIndex = 1
    root.confirmDeleteOpen = true
  }

  function cancelPermanentDelete() {
    root.confirmDeleteOpen = false
    root.pendingDeletePath = ""
    root.pendingDeleteName = ""
    root.disarmPointer()
    Qt.callLater(function () {
      keyCatcher.forceActiveFocus()
    })
  }

  function confirmPermanentDelete() {
    var path = root.pendingDeletePath
    root.confirmDeleteOpen = false
    root.pendingDeletePath = ""
    root.pendingDeleteName = ""
    Qt.callLater(function () {
      keyCatcher.forceActiveFocus()
    })

    if (path)
      root.enqueueDelete(path, true)
  }

  function enqueueDelete(path, permanent) {
    var next = root.deleteQueue.slice()
    next.push({
      path: path,
      permanent: permanent
    })
    root.deleteQueue = next
    root.pumpDeletes()
  }

  function pumpDeletes() {
    if (deleteProc.running || root.deleteQueue.length === 0)
      return

    var next = root.deleteQueue.slice()
    var job = next.shift()
    root.deleteQueue = next

    root.activeDeletePath = job.path
    // gio puts it in ~/.local/share/Trash and errors out rather than deleting
    // outright when it cannot, so a failure never turns into a silent rm.
    deleteProc.command = job.permanent ? ["rm", "-rf", "--", job.path] : ["gio", "trash", job.path]
    deleteProc.running = true
  }

  // By path, not by index: earlier removals have already shifted the indices
  // by the time a later delete reports back. A file can sit in both panes at
  // once (a search hit whose folder is open), so clear it from both.
  function removeRowByPath(path) {
    for (var i = resultsModel.count - 1; i >= 0; i--) {
      if (String(resultsModel.get(i).path) === path)
        resultsModel.remove(i)
    }
    for (var j = folderModel.count - 1; j >= 0; j--) {
      if (String(folderModel.get(j).path) === path)
        folderModel.remove(j)
    }

    root.selectedIndex = resultsModel.count === 0 ? 0 : Math.min(root.selectedIndex, resultsModel.count - 1)
    root.folderIndex = folderModel.count === 0 ? 0 : Math.min(root.folderIndex, folderModel.count - 1)
    root.disarmPointer()
  }

  // --- Preview -------------------------------------------------------------

  function togglePreview() {
    var row = root.snapshot(resultsModel, root.selectedIndex)
    if (!row)
      return

    // A folder's contents are the whole point of the pane, so for a folder
    // the keyboard goes straight in rather than merely showing something.
    if (row.kind === "dir") {
      root.previewOpen = true
      root.enterFolder(row.path)
      return
    }

    root.previewOpen = !root.previewOpen
    if (root.previewOpen)
      root.syncPreview()
    else
      root.leaveFolder()
  }

  function closePreview() {
    root.previewOpen = false
    root.leaveFolder()
  }

  function enterFolder(path) {
    root.folderPath = path
    root.folderIndex = 0
    root.folderFocused = true
    root.loadFolder(path)
  }

  function leaveFolder() {
    root.folderFocused = false
    root.folderPath = ""
    folderModel.clear()
  }

  // The pane tracks the results selection: arrow through the hits and the
  // preview follows, folder listings included.
  function syncPreview() {
    if (!root.previewOpen || root.folderFocused)
      return

    var row = root.snapshot(resultsModel, root.selectedIndex)
    if (row && row.kind === "dir") {
      if (row.path !== root.folderPath) {
        root.folderPath = row.path
        root.folderIndex = 0
        root.loadFolder(row.path)
      }
    } else if (root.folderPath) {
      root.folderPath = ""
      folderModel.clear()
    }
  }

  function folderParent(path) {
    if (!path || path === "/")
      return ""
    var parent = path.replace(/\/[^\/]*$/, "")
    return parent || "/"
  }

  function loadFolder(path) {
    if (!path) {
      folderModel.clear()
      return
    }

    if (folderProc.running) {
      root.queuedFolderPath = path
      root.hasQueuedFolder = true
      folderProc.running = false
      return
    }
    root.launchFolder(path)
  }

  function launchFolder(path) {
    root.activeFolderPath = path
    folderProc.command = [root.listScript, path]
    folderProc.running = true
  }

  function applyFolder(text) {
    // Arrowing fast queues several listings; only the current one is wanted.
    if (root.activeFolderPath !== root.folderPath)
      return

    folderModel.clear()

    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i])
        continue
      var cols = lines[i].split("\t")
      if (cols.length < 6)
        continue
      folderModel.append({
        kind: cols[0],
        name: cols[1],
        dir: cols[2],
        path: cols[3],
        mtime: parseInt(cols[4], 10) || 0,
        size: parseInt(cols[5], 10) || 0
      })
    }

    root.folderIndex = folderModel.count === 0 ? 0 : Math.min(root.folderIndex, folderModel.count - 1)
    root.disarmPointer()

    Qt.callLater(function () {
      if (folderModel.count > 0)
        folderList.positionViewAtIndex(root.folderIndex, ListView.Contain)
    })
  }

  function selectInFolder(delta) {
    if (folderModel.count === 0)
      return
    root.disarmPointer()
    root.folderIndex = (root.folderIndex + delta + folderModel.count) % folderModel.count
    folderList.positionViewAtIndex(root.folderIndex, ListView.Contain)
  }

  function descend() {
    var row = root.snapshot(folderModel, root.folderIndex)
    if (row && row.kind === "dir")
      root.enterFolder(row.path)
  }

  function ascend() {
    var parent = root.folderParent(root.folderPath)
    if (parent)
      root.enterFolder(parent)
  }

  readonly property string homeDir: Quickshell.env("HOME") || ""

  // GVariant string literals are single-quoted and encodeURIComponent leaves
  // an apostrophe untouched, so "Mom's file.pdf" would abort gdbus with a
  // parse error. %27 names the same file.
  function dbusUri(path) {
    return Util.fileUrl(path).replace(/'/g, "%27")
  }

  function tildePath(value) {
    if (root.homeDir && String(value).indexOf(root.homeDir) === 0)
      return "~" + String(value).slice(root.homeDir.length)
    return String(value)
  }

  // Content can change without the count changing (clear + append of the same
  // number of rows), which a plain count dependency would miss.
  property int resultsRevision: 0

  readonly property var previewRow: {
    var revision = root.resultsRevision
    if (!root.previewOpen)
      return null
    return root.snapshot(resultsModel, root.selectedIndex)
  }

  readonly property bool previewIsImage: root.previewRow ? root.isImageFile(root.previewRow.kind, root.previewRow.name, root.previewRow.size) : false

  function typeLabel(row) {
    if (!row)
      return ""
    if (row.kind === "dir")
      return "Folder"

    var ext = root.extensionOf(row.name)
    return ext ? ext.toUpperCase() + " file" : "File"
  }

  function formatSize(bytes) {
    if (!bytes)
      return "0 B"

    var units = ["B", "kB", "MB", "GB", "TB"]
    var n = bytes
    var i = 0
    while (n >= 1024 && i < units.length - 1) {
      n /= 1024
      i++
    }
    return (i === 0 ? String(n) : n.toFixed(n < 10 ? 1 : 0)) + " " + units[i]
  }

  // Today and yesterday carry a time, because for a file touched in the last
  // two days that is the part that distinguishes it. Anything older gets a
  // plain date, so the column stays scannable.
  function formatMtime(epoch) {
    if (!epoch)
      return ""

    var d = new Date(epoch * 1000)
    var now = new Date()
    if (d.toDateString() === now.toDateString())
      return "today " + Qt.formatTime(d, "HH:mm")

    var yesterday = new Date(now.getTime() - 86400000)
    if (d.toDateString() === yesterday.toDateString())
      return "yesterday " + Qt.formatTime(d, "HH:mm")

    // Locale pinned on purpose: "MMM" would otherwise follow the system
    // locale and turn March into "Mär" the moment LANG changes. Day-month-
    // year with a spelled-out month reads the same everywhere.
    return d.toLocaleDateString(Qt.locale("en_US"), "dd MMM yyyy")
  }

  readonly property var imageExtensions: ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "avif"]

  function extensionOf(name) {
    return name.indexOf(".") >= 0 ? name.split(".").pop().toLowerCase() : ""
  }

  // A thumbnail only where one is both possible and cheap. Everything else
  // keeps its glyph -- an image whose decode fails included, since the
  // delegate falls back on Image.status.
  function isImageFile(kind, name, size) {
    if (kind === "dir" || size > root.maxThumbBytes)
      return false
    return root.imageExtensions.indexOf(root.extensionOf(name)) >= 0
  }

  function iconFor(kind, name) {
    if (kind === "dir")
      return ""
    var ext = root.extensionOf(name)
    if (["pdf"].indexOf(ext) >= 0)
      return ""
    if (root.imageExtensions.indexOf(ext) >= 0)
      return ""
    if (["mp3", "flac", "wav", "ogg", "m4a", "opus"].indexOf(ext) >= 0)
      return ""
    if (["mp4", "mkv", "webm", "mov", "avi"].indexOf(ext) >= 0)
      return ""
    if (["zip", "tar", "gz", "xz", "zst", "7z", "rar", "bz2"].indexOf(ext) >= 0)
      return ""
    if (["doc", "docx", "odt", "rtf"].indexOf(ext) >= 0)
      return ""
    if (["xls", "xlsx", "ods", "csv"].indexOf(ext) >= 0)
      return ""
    if (["ppt", "pptx", "odp"].indexOf(ext) >= 0)
      return ""
    if (["js", "ts", "py", "rb", "go", "rs", "c", "h", "cpp", "sh", "qml", "json", "yml", "yaml", "toml", "html", "css"].indexOf(ext) >= 0)
      return ""
    if (["md", "txt", "org"].indexOf(ext) >= 0)
      return ""
    return ""
  }

  ListModel {
    id: resultsModel
  }

  ListModel {
    id: folderModel
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  // Keystrokes outrun the index. Waiting out a short pause turns a burst of
  // eight characters into one query instead of eight.
  Timer {
    id: debounce
    interval: 160
    repeat: false
    onTriggered: root.startSearch()
  }

  Process {
    id: searchProc

    onExited: {
      if (root.hasQueued) {
        root.hasQueued = false
        var next = root.queuedQuery
        root.queuedQuery = ""
        root.launchQuery(next)
      } else {
        root.searching = false
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyResults(text)
    }
  }

  Process {
    id: folderProc

    onExited: {
      if (root.hasQueuedFolder) {
        root.hasQueuedFolder = false
        var next = root.queuedFolderPath
        root.queuedFolderPath = ""
        root.launchFolder(next)
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFolder(text)
    }
  }

  Process {
    id: deleteProc

    // The row only disappears once the delete actually succeeded. Dropping it
    // optimistically would leave the list claiming a file is gone while it
    // sits there untouched.
    onExited: function (exitCode, exitStatus) {
      if (exitCode === 0) {
        root.removeRowByPath(root.activeDeletePath)
      } else {
        var reason = String(deleteError.text || "").replace(/\s+$/, "")
        Util.execArgv(["omarchy-notification-send", "Delete failed", reason || root.activeDeletePath])
      }

      root.activeDeletePath = ""
      root.pumpDeletes()
    }

    stderr: StdioCollector {
      id: deleteError
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-filesearch"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
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

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.confirmDeleteOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          // While the confirmation is up it owns the keyboard: no typing into
          // the query behind it, no navigating a list you cannot see.
          if (root.confirmDeleteOpen) {
            if (confirmDelete.handleKey(event))
              event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            // Staged, innermost first, so one key always undoes the last step.
            if (root.folderFocused)
              root.folderFocused = false
            else if (root.previewOpen)
              root.closePreview()
            else if (root.query)
              root.setQuery("")
            else
              root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            if (root.folderFocused)
              root.folderFocused = false
            else
              root.togglePreview()
            event.accepted = true
          } else if (root.folderFocused && (event.key === Qt.Key_Right)) {
            root.descend()
            event.accepted = true
          } else if (root.folderFocused && (event.key === Qt.Key_Left)) {
            root.ascend()
            event.accepted = true
          } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
            root.copyPath(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_E && (event.modifiers & Qt.ControlModifier)) {
            root.openEditor(root.selectedIndex)
            event.accepted = true
          } else if (Util.editsFilter(event, root.query)) {
            root.setQuery(Util.editedFilter(event, root.query))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            // Delete, not Backspace: editsFilter above owns Backspace and Ctrl+U
            // for editing the query, so the two never collide.
            if (event.modifiers & Qt.ShiftModifier)
              root.requestPermanentDelete(root.selectedIndex)
            else
              root.trashIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            if (root.folderFocused)
              root.selectInFolder(-1)
            else
              root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            if (root.folderFocused)
              root.selectInFolder(1)
            else
              root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            if (root.folderFocused)
              root.selectInFolder(-6)
            else
              root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            if (root.folderFocused)
              root.selectInFolder(6)
            else
              root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            if (root.folderFocused)
              root.folderIndex = 0
            else
              root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            if (root.folderFocused)
              root.folderIndex = Math.max(0, folderModel.count - 1)
            else
              root.selectAbsolute(resultsModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (event.modifiers & Qt.ShiftModifier)
              root.openFolder(root.selectedIndex)
            else if (event.modifiers & Qt.ControlModifier)
              root.openTerminal(root.selectedIndex)
            else
              root.openPath(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            // Typing means "back to searching": no dead end in browse mode.
            root.folderFocused = false
            root.setQuery(root.query + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: confirmDelete

          anchors.fill: parent
          opened: root.confirmDeleteOpen
          z: 10
          message: "Permanently delete “" + root.pendingDeleteName + "”? This cannot be undone."
          // ConfirmDialog hardwires its buttons to Style.space(88) and gives
          // the label no elide, so anything past ~14 characters at caption
          // size spills out of the frame. The warning lives in the message.
          confirmText: "Delete"
          cancelText: "Cancel"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelPermanentDelete()
          onConfirmed: root.confirmPermanentDelete()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // Header: the query itself, plus what it is currently searching.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: prompt
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: prompt.right
            anchors.leftMargin: Style.space(12)
            anchors.right: modeTag.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.query || "Search files…"
            color: root.foreground
            opacity: root.query ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            elide: Text.ElideLeft
          }

          Text {
            id: modeTag
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.searching ? "searching…" : root.modeLabel(root.query)
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2
          clip: true

          Item {
            id: resultsPane
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width - root.previewWidth
            clip: true
            // Dimmed while the keyboard lives in the preview pane, so which
            // list the arrow keys move is never in doubt.
            opacity: root.folderFocused ? 0.45 : 1.0

            ListView {
              id: resultList
              anchors.fill: parent
              anchors.rightMargin: root.previewOpen ? root.contentMargin : 0
              model: resultsModel
              clip: true
              spacing: Style.space(2)
              boundsBehavior: Flickable.StopAtBounds

              delegate: Rectangle {
                id: row
                required property int index
                required property string kind
                required property string name
                required property string dir
                required property string path
                required property int mtime
                required property int size

                // The same delegate serves both lists; the folder pane is narrow,
                // so it drops the directory line and the date column.
                readonly property bool compact: ListView.view === folderList
                readonly property bool activePane: compact ? root.folderFocused : !root.folderFocused
                readonly property bool hasCursor: compact ? (index === root.folderIndex) : (index === root.selectedIndex)
                readonly property int dateColumn: compact ? 0 : root.dateWidth

                width: ListView.view.width
                height: root.rowHeight
                radius: root.cornerRadius
                color: hasCursor ? (activePane ? root.selectedBackground : Util.alpha(root.selectedBackground, 0.5)) : "transparent"

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(12)

                  Item {
                    id: iconSlot
                    width: root.iconWidth
                    height: parent.height

                    readonly property bool wantsThumb: root.isImageFile(row.kind, row.name, row.size)

                    // The glyph is the ground state and stays visible until a
                    // thumbnail has actually decoded, so a broken or unsupported
                    // image shows its icon instead of a blank gap.
                    Text {
                      textFormat: Text.PlainText
                      anchors.fill: parent
                      visible: thumb.status !== Image.Ready
                      text: root.iconFor(row.kind, row.name)
                      color: row.hasCursor ? root.selectedText : root.foreground
                      opacity: row.hasCursor ? 1 : 0.6
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.displayLarge
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                    }

                    // Square crop: a wrapper that clips, with the image filling
                    // it. Portraits and panoramas then line up in one column
                    // instead of each claiming its own width.
                    Item {
                      anchors.centerIn: parent
                      width: root.thumbSize
                      height: root.thumbSize
                      clip: true

                      Image {
                        id: thumb
                        anchors.fill: parent
                        source: iconSlot.wantsThumb ? Util.fileUrl(row.path) : ""
                        // Decode at 2x the drawn size, not at full resolution:
                        // a 24 MP photo would otherwise be unpacked whole to
                        // fill 38 px.
                        sourceSize.width: root.thumbSize * 2
                        sourceSize.height: root.thumbSize * 2
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                        mipmap: true
                      }
                    }
                  }

                  Column {
                    width: parent.width - root.iconWidth - row.dateColumn - parent.spacing * (row.compact ? 1 : 2)
                    height: parent.height
                    spacing: Style.space(2)

                    Item {
                      width: parent.width
                      height: (parent.height - parent.spacing) / 2

                      Text {
                        textFormat: Text.PlainText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        text: row.name
                        color: row.hasCursor ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        elide: Text.ElideRight
                      }
                    }

                    Item {
                      width: parent.width
                      height: (parent.height - parent.spacing) / 2

                      Text {
                        textFormat: Text.PlainText
                        visible: !row.compact
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        text: row.dir
                        color: row.hasCursor ? root.selectedText : root.foreground
                        opacity: 0.6
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                      }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: !row.compact
                    width: row.dateColumn
                    height: parent.height
                    text: root.formatMtime(row.mtime)
                    color: row.hasCursor ? root.selectedText : root.foreground
                    opacity: row.hasCursor ? 0.75 : 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption + 2
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onPositionChanged: function (mouse) {
                    if (row.compact) {
                      if (pointerGate.moved(row, mouse))
                        root.folderIndex = row.index
                    } else {
                      root.selectFromPointer(row.index, row, mouse)
                    }
                  }
                  onClicked: function (mouse) {
                    if (row.compact) {
                      root.folderFocused = true
                      root.folderIndex = row.index
                      // A folder in the pane is a place to go, not a file to open.
                      if (row.kind === "dir" && mouse.button === Qt.LeftButton) {
                        root.descend()
                        return
                      }
                    } else {
                      root.folderFocused = false
                      root.selectedIndex = row.index
                      root.syncPreview()
                    }

                    if (mouse.button === Qt.RightButton)
                      root.openFolder(row.index)
                    else
                      root.openPath(row.index)
                  }
                }
              }
            }

            Column {
              // Explicit width: the children size themselves off the column,
              // so letting the column size itself off the children resolves
              // to zero and the whole empty state renders invisibly.
              width: parent.width
              anchors.centerIn: parent
              spacing: Style.space(8)
              visible: resultsModel.count === 0

              Text {
                text: ""
                color: root.selectedText
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.trimmedTerms(root.query).length < root.minQueryLength ? "Type to search the localsearch index" : (root.searching ? "Searching…" : "No matches for “" + root.trimmedTerms(root.query) + "”")
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                visible: root.trimmedTerms(root.query).length < root.minQueryLength
                text: "Prefixes:  f: filename   o: folders   d: documents   i: images"
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption + 1
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }
            }
          }

          Item {
            id: previewPane
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: root.previewWidth
            visible: root.previewOpen
            clip: true

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.normalBorderWidth
              color: Util.alpha(root.border, 0.28)
            }

            // A folder: its contents, navigable in place.
            Item {
              anchors.fill: parent
              anchors.leftMargin: root.contentMargin
              visible: root.folderPath !== ""

              Text {
                id: folderCrumb
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                text: root.tildePath(root.folderPath)
                color: root.foreground
                opacity: root.folderFocused ? 0.8 : 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }

              ListView {
                id: folderList
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: folderCrumb.bottom
                anchors.topMargin: Style.space(6)
                anchors.bottom: parent.bottom
                model: folderModel
                // Same Component instance as the results list, so a row looks
                // and behaves identically in both places.
                delegate: resultList.delegate
                clip: true
                spacing: Style.space(2)
                boundsBehavior: Flickable.StopAtBounds
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                visible: folderModel.count === 0
                text: "Empty folder"
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            // An image: as large as the pane allows.
            Item {
              anchors.fill: parent
              anchors.leftMargin: root.contentMargin
              visible: root.folderPath === "" && root.previewIsImage

              Image {
                id: previewImage
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: previewCaption.top
                anchors.bottomMargin: Style.space(8)
                source: root.previewIsImage && root.previewRow ? Util.fileUrl(root.previewRow.path) : ""
                // Capped at the pane, not the file: a 24 MP photo has no
                // business being decoded at full size to fill 500 px.
                sourceSize.width: Math.max(1, root.previewWidth * 2)
                sourceSize.height: Math.max(1, root.cardHeight * 2)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
              }

              Text {
                id: previewCaption
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                text: root.previewRow ? root.previewRow.name + "  ·  " + root.formatSize(root.previewRow.size) : ""
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
              }
            }

            // Anything else: the facts, since there is nothing to show.
            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: root.contentMargin
              spacing: Style.space(10)
              visible: root.folderPath === "" && !root.previewIsImage

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.previewRow ? root.previewRow.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WrapAnywhere
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.previewRow ? root.tildePath(root.previewRow.path) : ""
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }

              Repeater {
                model: root.previewRow ? [
                  { label: "Type", value: root.typeLabel(root.previewRow) },
                  { label: "Size", value: root.formatSize(root.previewRow.size) },
                  { label: "Modified", value: root.formatMtime(root.previewRow.mtime) }
                ] : []

                Item {
                  required property var modelData
                  width: parent.width
                  height: Style.font.caption + Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    text: parent.modelData.label
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    text: parent.modelData.value
                    color: root.foreground
                    opacity: 0.8
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

        }

        // Footer: the actions, spelled out. A launcher whose extra keys are
        // invisible is a launcher with one key.
        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: hitCount.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            // The hints follow the focus: the folder pane has its own keys, and
            // listing both sets at once would just be noise.
            text: root.folderFocused
              ? "→ Enter    ← Up    ⇥ Back    ↵ Open    ⇧↵ Folder    ^C Path    ⌦ Trash"
              : "⇥ Preview    ↵ Open    ⇧↵ Folder    ^↵ Terminal    ^E Editor    ^C Path    ⌦ Trash    ⇧⌦ Permanent"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption + 1
            elide: Text.ElideRight
          }

          Text {
            id: hitCount
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.folderFocused ? true : resultsModel.count > 0
            text: root.folderFocused
              ? folderModel.count + (folderModel.count === 1 ? " item" : " items")
              : resultsModel.count + (resultsModel.count === 1 ? " hit" : " hits")
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption + 1
          }
        }
      }
    }
  }
}
