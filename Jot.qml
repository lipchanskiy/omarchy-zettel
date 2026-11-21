import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Jot.js" as Jot

// Jot: one window to find and capture notes, backed by zk.
// Typing searches every notebook; Enter opens the selected note in the
// user's default editor, Ctrl+Enter saves what was typed as a new note,
// Alt+Enter appends it to today's journal.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("bin/jot")).replace(/^file:\/\//, ""))
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config")) + "/jot/config.jsonc"

  property bool opened: false
  // checking | noZk | ready
  property string phase: "checking"
  property var settings: Jot.parseConfig("", root.home)
  readonly property var notebooks: settings.notebooks
  readonly property bool multiNotebook: notebooks.length > 1
  property int captureIndex: 0
  readonly property var captureNotebook: notebooks[Math.min(captureIndex, notebooks.length - 1)]
  property var missingNotebooks: []

  // Note types of the capture notebook: the built-in journal first, then the
  // notebook's zk groups and templates: [{ id, label, dir, template, templatePath }].
  property var userTypes: []
  readonly property var noteTypes: [{ id: "journal", label: root.typeLabel("journal"), builtin: true,
                                      dir: root.settings.journalFolder, template: "", templatePath: "" }].concat(root.userTypes)
  property int suggestionIndex: 0
  readonly property var prefix: Jot.parseTypePrefix(root.query, root.noteTypes)
  readonly property bool suggesting: phase === "ready" && prefix.mode === "suggest"
  // The "/" list: matching types, plus "create type" for a new valid name.
  readonly property var suggestions: {
    if (!root.suggesting) return []
    var list = root.prefix.matches.slice()
    var word = root.query.slice(1).trim()
    var exists = false
    for (var i = 0; i < root.noteTypes.length; i++) {
      var t = root.noteTypes[i]
      if (t.id.toLowerCase() === word.toLowerCase() || t.label.toLowerCase() === word.toLowerCase()) exists = true
    }
    if (word && !exists && Jot.validTypeName(word)) list.push({ id: word, label: word, create: true, dir: "", template: "", templatePath: "" })
    return list
  }
  readonly property string defaultKind: settings.defaultCapture === "journal" ? "daily" : "new"
  readonly property string otherKind: defaultKind === "daily" ? "new" : "daily"
  property var initQueue: []
  property var initTried: ({})
  property var createdNotebooks: []
  readonly property string activeType: prefix.mode === "typed" ? prefix.typeId : ""
  // What is searched: the text after a "/type", nothing while picking a type.
  readonly property string searchText: prefix.mode === "typed" ? prefix.rest : (prefix.mode === "suggest" ? "" : root.query)
  property string requestedSearch: "\u0000"

  property string query: ""
  property string searchedQuery: ""
  property bool searchPending: false
  property bool searching: false
  property int selectedIndex: 0
  property bool cursorActive: false
  property string previewPath: ""
  property string previewContent: ""

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(980), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(54), Style.font.title + Style.font.caption + Style.spacing.rowPaddingX * 2)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    root.opened = true
    // Each open starts fresh; a stale query would hide the recent notes.
    input.text = ""
    root.query = ""
    root.captureIndex = root.settings.defaultIndex
    root.selectedIndex = 0
    root.cursorActive = false
    root.disarmPointer()
    // The settings file may have appeared since the last open; watching a
    // file that did not exist yet does not notice it.
    configFile.reload()
    root.checkStatus()
    Qt.callLater(root.focusForPhase)
  }

  function focusForPhase() {
    if (root.phase === "noZk") setupKeys.forceActiveFocus()
    else input.forceActiveFocus()
  }

  onPhaseChanged: if (root.opened) Qt.callLater(root.focusForPhase)

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function checkStatus() {
    if (statusProc.running) { statusProc.pending = true; return }
    statusProc.pending = false
    statusProc.command = [root.script, "status"].concat(Jot.notebookArgs(root.notebooks))
    statusProc.running = true
  }

  function applyStatus(text) {
    // Notebooks changed while this check ran; its answer is stale.
    if (statusProc.pending) { Qt.callLater(root.checkStatus); return }
    var status = Jot.parseJson(text)
    if (!status || status.error) { root.phase = "noZk"; return }
    if (!status.zk) { root.phase = "noZk"; return }
    var missing = []
    var toCreate = []
    for (var i = 0; i < status.notebooks.length; i++) {
      var nb = status.notebooks[i]
      if (nb.notebook) continue
      missing.push(nb.name)
      // A configured notebook that is not one yet is created on the spot,
      // once per session, so the first Super+N just works.
      if (!root.initTried[nb.path]) toCreate.push({ name: nb.name, path: nb.path })
    }
    if (toCreate.length > 0) {
      root.initQueue = toCreate
      root.runNextInit()
      return
    }
    root.missingNotebooks = missing
    root.phase = "ready"
    if (root.phase === "ready") {
      root.requestedSearch = "\u0000"
      root.requestSearch(true)
      root.fetchTypes()
    }
  }

  // ------------------------------------------------------------ search

  function setQuery(text) {
    if (text === root.query) return
    root.query = text
    root.suggestionIndex = 0
    root.requestSearch(false)
  }

  function requestSearch(immediate) {
    if (root.phase !== "ready") return
    if (root.searchText === root.requestedSearch) return
    if (immediate) root.runSearch()
    else searchDebounce.restart()
  }

  function runSearch() {
    if (searchProc.running) { root.searchPending = true; return }
    root.searchPending = false
    root.searching = true
    root.searchedQuery = root.searchText
    root.requestedSearch = root.searchText
    searchProc.command = [root.script, "search", "--limit", "60"]
      .concat(Jot.notebookArgs(root.notebooks)).concat(["--", root.searchText])
    searchProc.running = true
  }

  function runPendingSearch() {
    if (root.searchPending && !searchProc.running && root.searchText !== root.requestedSearch) root.runSearch()
    else root.searchPending = false
  }

  function applySearch(text) {
    root.searching = false
    var result = Jot.parseJson(text)
    var notes = result && Array.isArray(result.notes) ? result.notes : []
    var previousPath = root.cursorActive && root.selectedIndex < resultModel.count
      ? resultModel.get(root.selectedIndex).absPath : ""

    resultModel.clear()
    for (var i = 0; i < notes.length; i++) {
      var n = notes[i]
      if (!n || typeof n.absPath !== "string") continue
      resultModel.append({
        title: Jot.displayTitle(n).slice(0, 300),
        absPath: n.absPath,
        notebook: String(n.notebook || ""),
        relPath: String(n.path || ""),
        lead: String(n.lead || ""),
        tags: Array.isArray(n.tags) ? n.tags.slice(0, 6).map(function(t) { return "#" + String(t).slice(0, 40) }).join(" ") : "",
        modified: String(n.modified || "")
      })
    }

    // Keep the cursor on the same note across refreshes of the same query;
    // a new query starts from its best match.
    var keep = -1
    if (previousPath && root.searchedQuery === root.searchText) {
      for (var j = 0; j < resultModel.count; j++)
        if (resultModel.get(j).absPath === previousPath) { keep = j; break }
    }
    root.selectedIndex = keep >= 0 ? keep : 0
    root.cursorActive = resultModel.count > 0 && (keep >= 0 || root.searchText.length > 0)
    root.updatePreview()
    Qt.callLater(function() {
      if (resultModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
    Qt.callLater(root.runPendingSearch)
  }

  function updatePreview() {
    var row = root.selectedRow()
    root.previewPath = row ? row.absPath : ""
  }

  function selectedRow() {
    if (resultModel.count === 0) return null
    var i = Math.max(0, Math.min(root.selectedIndex, resultModel.count - 1))
    return resultModel.get(i)
  }

  // ------------------------------------------------------------ navigation

  function select(delta) {
    if (resultModel.count === 0) return
    root.disarmPointer()
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? resultModel.count - 1 : 0
    } else {
      root.selectedIndex = Math.max(0, Math.min(root.selectedIndex + delta, resultModel.count - 1))
    }
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    root.updatePreview()
  }

  function disarmPointer() { pointerGate.reset() }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
    root.updatePreview()
  }

  function cycleNotebook(delta) {
    if (!root.multiNotebook) return
    root.captureIndex = Jot.cycle(root.captureIndex, delta, root.notebooks.length)
  }

  // ------------------------------------------------------------ note types

  // A type's name in the shell's language: Jot's own types are translated,
  // the user's own zk groups and templates keep their names.
  function typeLabel(id) {
    var key = "type." + id
    var label = strings.t(key)
    return label && label !== key ? label : id
  }

  function fetchTypes() {
    if (root.phase !== "ready" || !root.captureNotebook) return
    if (typesProc.running) { typesProc.pending = true; return }
    typesProc.pending = false
    typesProc.command = [root.script, "types", "--nb", root.captureNotebook.name, root.captureNotebook.path]
    typesProc.running = true
  }

  function applyTypes(text) {
    var list = Jot.parseJson(text)
    var types = []
    if (Array.isArray(list)) {
      for (var i = 0; i < list.length && types.length < 50; i++) {
        var t = list[i]
        if (!t || typeof t.id !== "string" || !t.id || t.id === "journal") continue
        types.push({ id: t.id.slice(0, 60), label: root.typeLabel(t.id).slice(0, 60),
                     dir: String(t.dir || "").slice(0, 120), template: String(t.template || "").slice(0, 120),
                     templatePath: String(t.templatePath || "") })
      }
    }
    root.userTypes = types
    if (typesProc.pending) Qt.callLater(root.fetchTypes)
  }

  function moveSuggestion(delta) {
    var n = root.suggestions.length
    if (n === 0) return
    root.suggestionIndex = Math.max(0, Math.min(root.suggestionIndex + delta, n - 1))
    suggestionList.positionViewAtIndex(root.suggestionIndex, ListView.Contain)
  }

  // "/вс" + Tab → "/встреча ": the label is used when it is one word, so the
  // input reads in the user's language.
  function completeType(index) {
    var list = root.suggestions
    if (list.length === 0) return
    var t = list[Math.max(0, Math.min(index, list.length - 1))]
    if (t.create) { root.createType(t.id); return }
    var word = /\s/.test(t.label) ? t.id : t.label.toLowerCase()
    input.text = "/" + word + " "
    input.cursorPosition = input.text.length
  }

  function createType(name) {
    if (typeAddProc.running || !root.captureNotebook) return
    typeAddProc.name = name
    typeAddProc.command = [root.script, "types", "add", name, "--nb", root.captureNotebook.name, root.captureNotebook.path]
    typeAddProc.running = true
  }

  function finishCreateType(text) {
    var result = Jot.parseJson(text)
    if (!result || result.error || !result.id) {
      root.notify(strings.t("error.type"), result && result.error ? String(result.error) : typeAddProc.name)
      return
    }
    root.userTypes = root.userTypes.concat([{ id: result.id, label: root.typeLabel(result.id), dir: String(result.dir || ""),
                                              template: String(result.template || ""), templatePath: String(result.templatePath || "") }])
    input.text = "/" + result.id + " "
    input.cursorPosition = input.text.length
    root.fetchTypes()
  }

  // Ctrl+E: open the template of the type under the cursor, or of the type
  // being written.
  function editTemplate() {
    var t = null
    if (root.suggesting) t = root.suggestions[root.suggestionIndex]
    else if (root.activeType) {
      for (var i = 0; i < root.noteTypes.length; i++)
        if (root.noteTypes[i].id === root.activeType) t = root.noteTypes[i]
    }
    if (!t || !t.templatePath) return false
    root.close()
    root.openInEditor(t.templatePath)
    return true
  }

  // Dates for templates and the journal heading, in the shell's language.
  function dateArgs() {
    var loc = Qt.locale(Commons.I18n.formatLocale)
    var now = new Date()
    return ["--date", now.toLocaleDateString(loc, "d MMMM yyyy"),
            "--weekday", now.toLocaleDateString(loc, "dddd"),
            "--title-label", now.toLocaleDateString(loc, Locale.LongFormat)]
  }

  // ------------------------------------------------------------ actions

  function openRow(row) {
    if (!row) return
    root.close()
    root.openInEditor(row.absPath)
  }

  function captureText() {
    return input.text.replace(/\s+$/, "")
  }

  function runAction(kind, openAfter) {
    if (actionProc.running) return
    var type = kind === "new" && root.activeType !== "journal" ? root.activeType : ""
    var text = (root.activeType ? root.prefix.rest : input.text).replace(/\s+$/, "")
    if (!text.trim() && !type) return
    var nb = root.captureNotebook
    actionProc.kind = kind
    actionProc.openAfter = openAfter
    actionProc.notebookName = nb.name
    actionProc.command = [root.script, kind, "--nb", nb.name, nb.path]
      .concat(type ? ["--type", type] : [])
      .concat(root.folderArgs(kind))
      .concat(root.dateArgs())
      .concat(["--", text])
    actionProc.running = true
    input.text = ""
    root.close()
  }

  function finishAction(text) {
    var result = Jot.parseJson(text)
    if (!result || result.error || !result.path) {
      root.notify(strings.t("error.title"), result && result.error ? String(result.error) : strings.t("error.unknown"))
      return
    }
    if (actionProc.openAfter) {
      root.openInEditor(result.path)
    } else {
      root.notify(actionProc.kind === "daily" ? strings.t("saved.daily") : strings.t("saved.note"),
                  root.multiNotebook ? strings.t("saved.in").arg(actionProc.notebookName) : "")
    }
    // The next open shows the new note at the top.
    root.query = ""
  }

  // The editor from Jot's settings, or Omarchy's default editor. A terminal
  // editor gets a terminal window, the way omarchy-launch-editor does it.
  function openInEditor(path) {
    var editor = root.settings.editor
    if (!editor) {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-launch-editor", path])
      return
    }
    var argv = editor.split(/\s+/).filter(function(a) { return a.length > 0 })
    var tui = ["nvim", "vim", "vi", "nano", "micro", "hx", "helix", "kak", "emacs"]
    if (tui.indexOf(argv[0].replace(/^.*\//, "")) >= 0)
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-launch-tui"].concat(argv).concat(["--", path]))
    else
      Quickshell.execDetached(argv.concat([path]))
  }

  function openSettings() {
    if (configProc.running) return
    root.close()
    configProc.running = true
  }

  // Options every new/daily call needs from the settings.
  function folderArgs(kind) {
    var args = ["--inbox", root.settings.inboxFolder, "--journal", root.settings.journalFolder]
    if (kind === "daily" && !root.settings.journalTimestamps) args.push("--no-timestamps")
    return args
  }

  // Notification text is markup in some daemons; keep it inert.
  function notify(summary, body) {
    var clean = function(s) { return String(s || "").replace(/[<>&]/g, "").slice(0, 200) }
    var argv = [root.omarchyPath + "/bin/omarchy-notification-send", clean(summary)]
    if (body) argv.push(clean(body))
    Quickshell.execDetached(argv)
  }

  function runNextInit() {
    if (initProc.running) return
    if (root.initQueue.length === 0) {
      if (root.createdNotebooks.length > 0) {
        var paths = root.createdNotebooks.map(function(p) { return p.replace(root.home, "~") })
        root.notify(strings.t("notebook.created"), paths.join(", "))
        root.createdNotebooks = []
      }
      root.checkStatus()
      return
    }
    var next = root.initQueue[0]
    root.initQueue = root.initQueue.slice(1)
    var tried = {}
    for (var k in root.initTried) tried[k] = true
    tried[next.path] = true
    root.initTried = tried
    initProc.target = next.path
    initProc.command = [root.script, "init", next.path]
    initProc.running = true
  }

  function finishInit(text) {
    var result = Jot.parseJson(text)
    if (result && result.created) root.createdNotebooks = root.createdNotebooks.concat([initProc.target])
    else if (!result || result.error)
      root.notify(strings.t("error.notebook"), result && result.error ? String(result.error) : initProc.target)
    Qt.callLater(root.runNextInit)
  }

  function installZk() {
    root.close()
    Quickshell.execDetached(["xdg-terminal-exec", "bash", "-c",
      "omarchy-pkg-add zk && echo && echo 'zk is installed. Press Super+N again to start using Jot.' || echo 'Installing zk failed.'; read -rsn1 -p 'Press any key to close'"])
  }

  function handleKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var alt = event.modifiers & Qt.AltModifier
    var shift = event.modifiers & Qt.ShiftModifier
    var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter

    if (event.key === Qt.Key_Escape) {
      if (input.text) input.text = ""
      else root.close()
      return true
    }

    if (ctrl && event.key === Qt.Key_Comma) { root.openSettings(); return true }

    if (root.phase === "noZk") {
      if (enter) { root.installZk(); return true }
      return true
    }
    if (root.phase !== "ready") return enter || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab

    if (ctrl && event.key === Qt.Key_E) { root.editTemplate(); return true }

    if (root.suggesting) {
      if (enter || event.key === Qt.Key_Tab) {
        if (root.suggestions.length > 0) root.completeType(root.suggestionIndex)
        return true
      }
      if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_P)) { root.moveSuggestion(-1); return true }
      if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N)) { root.moveSuggestion(1); return true }
      return false
    }

    if (enter && shift && !ctrl && !alt) return false      // newline in the note

    if (enter && root.activeType) {
      if (root.activeType === "journal") root.runAction("daily", false)
      else root.runAction("new", ctrl && shift)          // Ctrl+Shift+Enter also opens it
      return true
    }

    if (enter) {
      if (alt) { root.runAction(root.otherKind, false); return true }
      if (ctrl) { root.runAction(shift ? "new" : root.defaultKind, shift); return true }
      if (root.cursorActive && resultModel.count > 0) root.openRow(root.selectedRow())
      else if (root.captureText().trim()) root.runAction(root.defaultKind, false)
      return true
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.cycleNotebook(event.key === Qt.Key_Backtab || shift ? -1 : 1)
      return true
    }
    if (event.key === Qt.Key_Up) { root.select(-1); return true }
    if (event.key === Qt.Key_Down) { root.select(1); return true }
    if (event.key === Qt.Key_PageUp) { root.select(-6); return true }
    if (event.key === Qt.Key_PageDown) { root.select(6); return true }
    if (ctrl && event.key === Qt.Key_P) { root.select(-1); return true }
    if (ctrl && event.key === Qt.Key_N) { root.select(1); return true }
    return false
  }

  // ------------------------------------------------------------ first run

  // Loaded with the shell, so this runs right after the plugin is installed:
  // `jot setup --first-run` binds a shortcut, links the `jot` command and
  // writes the settings file, once. Later loads only read its saved result.
  Component.onCompleted: setupProc.running = true

  function finishSetup(text) {
    var result = Jot.parseJson(text)
    if (!result || !result.firstRun) return
    if (result.shortcut) {
      var keys = String(result.shortcut).split("+").map(function(k) {
        k = k.trim().toLowerCase()
        return k.charAt(0).toUpperCase() + k.slice(1)
      }).join("+")
      root.notify(strings.t("setup.ready"), strings.t("setup.readyBody").arg(keys))
    } else {
      root.notify(strings.t("setup.ready"), strings.t("setup.noShortcut"))
    }
  }

  Process {
    id: setupProc
    command: [root.script, "setup", "--first-run"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishSetup(text)
    }
  }

  // ------------------------------------------------------------ processes

  ListModel { id: resultModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.settings = Jot.parseConfig(text(), root.home)
    onLoadFailed: root.settings = Jot.parseConfig("", root.home)
    onFileChanged: reload()
  }

  onCaptureIndexChanged: root.fetchTypes()

  onNotebooksChanged: {
    if (root.captureIndex >= root.notebooks.length) root.captureIndex = root.settings.defaultIndex
    if (root.opened) root.checkStatus()
  }

  Timer {
    id: searchDebounce
    interval: 70
    repeat: false
    onTriggered: root.runSearch()
  }

  Process {
    id: statusProc
    property bool pending: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySearch(text)
    }
    onExited: Qt.callLater(root.runPendingSearch)
  }

  Process {
    id: typeAddProc
    property string name: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishCreateType(text)
    }
  }

  Process {
    id: typesProc
    property bool pending: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyTypes(text)
    }
  }

  Process {
    id: actionProc
    property string kind: ""
    property bool openAfter: false
    property string notebookName: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishAction(text)
    }
  }

  Process {
    id: configProc
    command: [root.script, "config"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Jot.parseJson(text)
        if (result && result.path) root.openInEditor(result.path)
        else root.notify(strings.t("error.settings"), result && result.error ? String(result.error) : "")
      }
    }
  }

  Process {
    id: initProc
    property string target: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishInit(text)
    }
  }

  FileView {
    id: previewFile
    path: root.previewPath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.previewContent = text()
    onLoadFailed: root.previewContent = ""
  }

  onPreviewPathChanged: if (!root.previewPath) root.previewContent = ""

  // ------------------------------------------------------------ window

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-jot"

    Rectangle { anchors.fill: parent; color: root.scrim }

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

      MouseArea { anchors.fill: parent; onClicked: root.focusForPhase() }

      // Takes the keys while there is no input line (the zk install screen).
      Item {
        id: setupKeys
        Keys.onPressed: function(event) { if (root.handleKey(event)) event.accepted = true }
      }

      Column {
        id: layout
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ---- input line
        Item {
          id: header
          visible: root.phase === "ready"
          width: parent.width
          height: Math.max(Style.space(34), Math.min(input.contentHeight, input.font.pixelSize * 5.2)) + Style.spacing.controlPaddingY

          Flickable {
            id: inputFlick
            anchors.left: parent.left
            anchors.right: chips.width > 0 ? chips.left : parent.right
            anchors.rightMargin: chips.width > 0 ? Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            height: Math.min(input.contentHeight, input.font.pixelSize * 5.2)
            contentHeight: input.contentHeight
            contentWidth: width
            clip: true
            interactive: false

            function ensureVisible(r) {
              if (contentY >= r.y) contentY = r.y
              else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
            }

            TextEdit {
              id: input
              width: inputFlick.width
              textFormat: TextEdit.PlainText
              wrapMode: TextEdit.Wrap
              color: root.foreground
              selectionColor: Style.selectionFillFor(root.foreground, Commons.Color.accent)
              selectedTextColor: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              focus: true
              persistentSelection: false
              onTextChanged: root.setQuery(text)
              onCursorRectangleChanged: inputFlick.ensureVisible(cursorRectangle)
              Keys.onPressed: function(event) {
                if (root.handleKey(event)) event.accepted = true
              }

              Text {
                textFormat: Text.PlainText
                anchors.fill: parent
                visible: input.text.length === 0 && !input.preeditText
                text: root.phase === "ready" ? strings.t("input.placeholder") : ""
                color: root.foreground
                opacity: 0.5
                font: input.font
                elide: Text.ElideRight
              }
            }
          }

          // What Ctrl+Enter will create: the note type and, with several
          // notebooks, where it goes. Both are clickable.
          Row {
            id: chips
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Repeater {
              model: [
                { kind: "type", shown: root.phase === "ready" && root.activeType !== "",
                  text: "󰈙 " + (root.activeType ? root.typeLabel(root.activeType) : "") },
                { kind: "notebook", shown: root.phase === "ready" && root.multiNotebook,
                  text: "󰠮 " + (root.captureNotebook ? root.captureNotebook.name : "") }
              ]

              delegate: Rectangle {
                required property var modelData
                visible: modelData.shown
                height: chipText.implicitHeight + Style.space(8)
                width: visible ? chipText.implicitWidth + Style.space(20) : 0
                radius: height / 2
                color: modelData.kind === "type" ? Util.alpha(Commons.Color.accent, 0.22) : Util.alpha(root.foreground, 0.08)

                Text {
                  id: chipText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: parent.modelData.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (parent.modelData.kind === "notebook") root.cycleNotebook(1)
                    input.forceActiveFocus()
                  }
                }
              }
            }
          }
        }

        // ---- results + preview
        Item {
          id: body
          width: parent.width
          height: parent.height - (header.visible ? header.height + root.contentSpacing : 0) - footer.height - root.contentSpacing
          visible: root.phase === "ready"

          // "/" typed: pick a note type.
          Item {
            anchors.fill: parent
            visible: root.suggesting

            ListView {
              id: suggestionList
              anchors.fill: parent
              anchors.rightMargin: Math.round(parent.width * 0.42)
              visible: root.suggestions.length > 0
              model: root.suggestions
              clip: true
              spacing: Style.space(4)
              boundsBehavior: Flickable.StopAtBounds

              delegate: Rectangle {
                id: typeRow
                required property int index
                required property var modelData
                readonly property bool hasCursor: index === root.suggestionIndex
                readonly property color textColor: hasCursor ? root.selectedText : root.foreground
                width: ListView.view.width
                height: root.rowHeight
                radius: root.cornerRadius
                color: hasCursor ? root.selectedBackground : "transparent"

                Column {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  anchors.topMargin: Style.space(7)
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: typeRow.modelData.create ? strings.t("types.create").arg(typeRow.modelData.id) : "/" + typeRow.modelData.label
                    color: typeRow.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: typeRow.modelData.create ? strings.t("types.createHint")
                      : typeRow.modelData.builtin ? strings.t("types.journalHint").arg(typeRow.modelData.dir + "/")
                      : [typeRow.modelData.dir ? typeRow.modelData.dir + "/" : "", typeRow.modelData.template]
                          .filter(function(p) { return p }).join("  ·  ")
                    color: typeRow.textColor
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.completeType(typeRow.index); input.forceActiveFocus() }
                }
              }
            }

            Column {
              anchors.centerIn: parent
              width: parent.width - 2 * root.contentMargin
              spacing: Style.space(8)
              visible: root.suggestions.length === 0

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: strings.t("types.noMatch")
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: strings.t("types.help")
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            anchors.fill: parent
            visible: resultModel.count > 0 && !root.suggesting

            Item {
              width: Math.round(parent.width * 0.42)
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: resultModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string title
                  required property string notebook
                  required property string relPath
                  required property string tags
                  required property string modified
                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
                  readonly property color textColor: hasCursor ? root.selectedText : root.foreground

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  Column {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    anchors.topMargin: Style.space(7)
                    anchors.bottomMargin: Style.space(7)
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: row.title
                      color: row.textColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: {
                        var parts = []
                        if (root.multiNotebook) parts.push(row.notebook)
                        var when = Jot.relativeDate(row.modified, Qt.locale(Commons.I18n.formatLocale),
                                                    strings.t("date.today"), strings.t("date.yesterday"))
                        if (when) parts.push(when)
                        if (row.tags) parts.push(row.tags)
                        return parts.join("  ·  ")
                      }
                      color: row.textColor
                      opacity: 0.6
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: function(mouse) { root.selectFromPointer(row.index, row, mouse) }
                    onClicked: {
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      root.openRow(root.selectedRow())
                    }
                  }
                }
              }
            }

            Item {
              width: parent.width - Math.round(parent.width * 0.42)
              height: parent.height
              clip: true

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              Flickable {
                id: previewFlick
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                contentWidth: width
                contentHeight: previewText.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Connections {
                  target: root
                  function onPreviewPathChanged() { previewFlick.contentY = 0 }
                }

                // Markdown from disk, made inert by Jot.sanitizeMarkdown: no raw
                // HTML, no images, no remote resources. Links are not followed.
                Text {
                  id: previewText
                  width: previewFlick.width
                  textFormat: Text.MarkdownText
                  text: Jot.sanitizeMarkdown(root.previewContent)
                  color: root.foreground
                  linkColor: Commons.Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            width: parent.width - 2 * root.contentMargin
            spacing: Style.space(8)
            visible: resultModel.count === 0 && !root.searching && !root.suggesting

            Text {
              text: root.query ? "󰍉" : "󱞁"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.activeType === "journal" ? strings.t("empty.typedJournal")
                : root.activeType ? strings.t("empty.typed").arg(root.typeLabel(root.activeType))
                : root.searchText ? (root.defaultKind === "daily" ? strings.t("empty.noMatchesJournal") : strings.t("empty.noMatches"))
                : strings.t("empty.noNotes")
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }
          }
        }

        // ---- setup screens
        Item {
          width: parent.width
          height: parent.height - footer.height - root.contentSpacing
          visible: root.phase !== "ready"

          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 2 * root.contentMargin, Style.space(560))
            spacing: Style.space(12)

            Text {
              text: "󰏗"
              visible: root.phase === "noZk"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              text: root.phase === "noZk" ? strings.t("setup.noZk.title") : ""
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: root.phase === "noZk" ? strings.t("setup.noZk.body") : ""
            }

            Button {
              visible: root.phase === "noZk"
              anchors.horizontalCenter: parent.horizontalCenter
              bordered: true
              iconText: "󰏗"
              text: strings.t("setup.noZk.button")
              onClicked: root.installZk()
            }
          }
        }

        // ---- key hints
        Text {
          id: footer
          width: parent.width
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          text: {
            if (root.phase === "noZk") return strings.t("hint.install")
            if (root.phase !== "ready") return ""
            if (!root.settings.ok) return strings.t("hint.badSettings")
            if (root.suggesting) {
              var cur = root.suggestions[root.suggestionIndex]
              return cur && cur.create ? strings.t("hint.createType") : strings.t("hint.types")
            }
            if (root.activeType === "journal") return strings.t("hint.typedJournal")
            if (root.activeType) return strings.t("hint.typed").arg(root.typeLabel(root.activeType))
            var hint = root.defaultKind === "daily" ? strings.t("hint.readyJournal") : strings.t("hint.ready")
            if (root.multiNotebook) hint += "  ·  " + strings.t("hint.notebook")
            if (root.missingNotebooks.length > 0) hint += "  ·  " + strings.t("hint.missing").arg(root.missingNotebooks.join(", "))
            return hint
          }
        }
      }
    }
  }
}
