.pragma library

// Pure helpers for Jot.qml. Kept free of QML types so tests/run.js can load
// this file in node and check them directly.

var MAX_PREVIEW_CHARS = 20000
var MAX_NOTEBOOKS = 16
var MAX_NAME_CHARS = 40

function expandHome(path, home) {
  path = String(path || "")
  if (path === "~") return home
  if (path.indexOf("~/") === 0) return home + path.slice(1)
  return path
}

function baseName(path) {
  var parts = String(path || "").replace(/\/+$/, "").split("/")
  return parts[parts.length - 1] || path
}

// JSONC → JSON: drops // and /* */ comments and trailing commas, leaving
// string contents (paths, URLs) alone. Mirrors strip_jsonc in bin/jot.
function stripJsonc(text) {
  text = String(text || "")
  var out = ""
  var inString = false, escaped = false
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    if (inString) {
      out += c
      if (escaped) escaped = false
      else if (c === "\\") escaped = true
      else if (c === "\"") inString = false
      continue
    }
    if (c === "\"") { inString = true; out += c; continue }
    if (c === "/" && text.charAt(i + 1) === "/") {
      while (i < text.length && text.charAt(i) !== "\n") i++
      out += "\n"
      continue
    }
    if (c === "/" && text.charAt(i + 1) === "*") {
      var close = text.indexOf("*/", i + 2)
      if (close < 0) break
      i = close + 1
      continue
    }
    out += c
  }
  // Trailing commas, now that comments are gone (outside strings only).
  var result = ""
  inString = false; escaped = false
  for (var j = 0; j < out.length; j++) {
    var d = out.charAt(j)
    if (inString) {
      result += d
      if (escaped) escaped = false
      else if (d === "\\") escaped = true
      else if (d === "\"") inString = false
      continue
    }
    if (d === "\"") { inString = true; result += d; continue }
    if (d === ",") {
      var k = j + 1
      while (k < out.length && /\s/.test(out.charAt(k))) k++
      if (out.charAt(k) === "}" || out.charAt(k) === "]") continue
    }
    result += d
  }
  return result
}

// A folder name inside a notebook: relative, no "..", no leading slash.
function safeFolder(value, fallback) {
  if (typeof value !== "string") return fallback
  var v = value.trim().replace(/^\/+|\/+$/g, "")
  if (v.split("/").indexOf("..") >= 0) return fallback
  return v.slice(0, 120)
}

var DEFAULTS = { inboxFolder: "inbox", journalFolder: "journal", journalTimestamps: true, editor: "", defaultCapture: "note" }

// Reads ~/.config/jot/config.jsonc (see bin/jot for the commented template).
// Anything missing or malformed falls back to one ~/Notes notebook and the
// defaults above; ok is false when the file exists but does not parse.
function parseConfig(text, home) {
  var result = {
    notebooks: [{ name: "Notes", path: home + "/Notes" }],
    defaultIndex: 0,
    inboxFolder: DEFAULTS.inboxFolder,
    journalFolder: DEFAULTS.journalFolder,
    journalTimestamps: DEFAULTS.journalTimestamps,
    editor: DEFAULTS.editor,
    defaultCapture: DEFAULTS.defaultCapture,
    ok: true
  }
  if (!String(text || "").trim()) return result
  var config
  try { config = JSON.parse(stripJsonc(text)) } catch (e) { result.ok = false; return result }
  if (!config || typeof config !== "object" || Array.isArray(config)) { result.ok = false; return result }

  if (Array.isArray(config.notebooks)) {
    var notebooks = []
    var seen = {}
    for (var j = 0; j < config.notebooks.length && notebooks.length < MAX_NOTEBOOKS; j++) {
      var nb = config.notebooks[j]
      var rawPath = typeof nb === "string" ? nb : (nb && typeof nb.path === "string" ? nb.path : "")
      if (!rawPath) continue
      var path = expandHome(rawPath.trim(), home).replace(/\/+$/, "")
      if (path.charAt(0) !== "/" || seen[path]) continue
      var name = nb && typeof nb.name === "string" && nb.name.trim() ? nb.name.trim() : baseName(path)
      seen[path] = true
      notebooks.push({ name: name.slice(0, MAX_NAME_CHARS), path: path })
    }
    if (notebooks.length > 0) result.notebooks = notebooks
  }
  if (typeof config.defaultNotebook === "string") {
    for (var k = 0; k < result.notebooks.length; k++)
      if (result.notebooks[k].name === config.defaultNotebook) { result.defaultIndex = k; break }
  }
  result.inboxFolder = safeFolder(config.inboxFolder, DEFAULTS.inboxFolder)
  result.journalFolder = safeFolder(config.journalFolder, DEFAULTS.journalFolder) || DEFAULTS.journalFolder
  if (typeof config.journalTimestamps === "boolean") result.journalTimestamps = config.journalTimestamps
  if (typeof config.editor === "string") result.editor = config.editor.trim().slice(0, 200)
  if (config.defaultCapture === "journal") result.defaultCapture = "journal"
  return result
}

function notebookArgs(notebooks) {
  var args = []
  for (var i = 0; i < notebooks.length; i++) args.push("--nb", notebooks[i].name, notebooks[i].path)
  return args
}

function parseJson(text) {
  try { return JSON.parse(String(text || "").trim() || "null") } catch (e) { return null }
}

function stripFrontmatter(text) {
  if (text.indexOf("---\n") !== 0) return text
  var end = text.indexOf("\n---", 4)
  if (end < 0) return text
  var after = text.indexOf("\n", end + 4)
  return after < 0 ? "" : text.slice(after + 1)
}

// Escapes what Qt's Markdown renderer would otherwise act on in a preview
// that must stay inert: raw HTML (an <img> would load a remote resource) and
// images (rendered as their alt text instead). Code is left alone, since the
// renderer shows it literally anyway.
function escapeInline(line) {
  var out = ""
  var parts = line.split("`")
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    // Odd segments sit between backticks (inline code) when the backtick closes.
    var isCode = i % 2 === 1 && i < parts.length - 1
    if (!isCode) {
      part = part.replace(/!\[([^\]]*)\]\([^)]*\)/g, function(m, alt) { return "▣ " + (alt || "image") })
      part = part.replace(/!\[([^\]]*)\]\[[^\]]*\]/g, function(m, alt) { return "▣ " + (alt || "image") })
      part = part.replace(/</g, "\\<").replace(/&/g, "\\&")
    }
    out += (i > 0 ? "`" : "") + part
  }
  return out
}

function sanitizeMarkdown(text) {
  text = String(text || "").replace(/\r\n?/g, "\n")
  if (text.length > MAX_PREVIEW_CHARS) text = text.slice(0, MAX_PREVIEW_CHARS) + "\n\n…"
  text = stripFrontmatter(text)

  var lines = text.split("\n")
  var fence = null
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var m = line.match(/^\s{0,3}(`{3,}|~{3,})/)
    if (m) {
      if (fence === null) fence = m[1].charAt(0)
      else if (m[1].charAt(0) === fence) fence = null
      continue
    }
    if (fence !== null) continue
    // Four-space indented code is literal too.
    if (/^(    |\t)/.test(line) && (i === 0 || lines[i - 1].trim() === "" || /^(    |\t)/.test(lines[i - 1]))) continue
    // Reference-style image definitions would still resolve; neutralize them.
    lines[i] = escapeInline(line).replace(/^(\s{0,3})\[([^\]]+)\]:\s*\S+/, "$1[$2]: …")
  }
  // [[wiki links]] read better as plain bracketed text than as nested links.
  return lines.join("\n")
}

function displayTitle(note) {
  if (note && note.title) return String(note.title)
  if (note && note.filename) return String(note.filename).replace(/\.md$/, "")
  return ""
}

// "Today 14:05", "Yesterday", or a short date, in the shell's language.
function relativeDate(iso, locale, todayLabel, yesterdayLabel) {
  var d = new Date(iso)
  if (isNaN(d.getTime())) return ""
  var now = new Date()
  var startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  var t = d.getTime()
  if (t >= startToday) return todayLabel.arg ? todayLabel.arg(d.toLocaleTimeString(locale, "HH:mm")) : todayLabel
  if (t >= startToday - 86400000) return yesterdayLabel
  var sameYear = d.getFullYear() === now.getFullYear()
  return d.toLocaleDateString(locale, sameYear ? "d MMM" : "d MMM yyyy")
}

function cycle(index, delta, count) {
  if (count <= 0) return 0
  return ((index + delta) % count + count) % count
}

// Reads a leading "/type" from the input. types is [{ id, label }].
//   "/"            → suggest, every type
//   "/вст"         → suggest, types whose id or label starts with "вст"
//   "/meeting Foo" → typed, typeId "meeting", rest "Foo"
//   "/nope Foo"    → none (plain text, it is not a type)
function parseTypePrefix(text, types) {
  var none = { mode: "none", typeId: "", rest: text, matches: [] }
  text = String(text || "")
  if (text.charAt(0) !== "/") return none
  var m = text.match(/^\/(\S*)(\s+([\s\S]*))?$/)
  if (!m) return none
  var word = m[1].toLowerCase()
  if (m[2] === undefined) {
    var matches = []
    for (var i = 0; i < types.length; i++) {
      var t = types[i]
      if (String(t.id).toLowerCase().indexOf(word) === 0 || String(t.label).toLowerCase().indexOf(word) === 0)
        matches.push(t)
    }
    return { mode: "suggest", typeId: "", rest: "", matches: matches }
  }
  for (var j = 0; j < types.length; j++) {
    if (String(types[j].id).toLowerCase() === word || String(types[j].label).toLowerCase() === word)
      return { mode: "typed", typeId: types[j].id, rest: m[3] || "", matches: [] }
  }
  return none
}

// Same rule as add_type in bin/jot: one word, at most 40 characters, none of
// the characters that would break a TOML key, a folder or a file name.
function validTypeName(name) {
  name = String(name || "")
  if (!name || name.length > 40 || name === "journal") return false
  return !/[\s"\\\/.#\[\]'=\u0000-\u001f]/.test(name)
}
