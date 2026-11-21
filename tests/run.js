// node tests/run.js — checks the pure helpers in Jot.js.
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "..", "Jot.js"), "utf8").replace(/^\.pragma library\s*/, "")
const Jot = new Function(src + "\nreturn { parseConfig, stripJsonc, sanitizeMarkdown, notebookArgs, displayTitle, cycle, expandHome, parseTypePrefix, validTypeName }")()

let failed = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message) }
}

const HOME = "/home/u"

test("config falls back to ~/Notes", () => {
  const s = Jot.parseConfig("", HOME)
  assert.deepStrictEqual(s.notebooks, [{ name: "Notes", path: "/home/u/Notes" }])
  assert.strictEqual(s.inboxFolder, "inbox"); assert.strictEqual(s.journalTimestamps, true); assert.ok(s.ok)
})

test("config reads JSONC with comments and trailing commas", () => {
  const text = `// top comment
  {
    /* block */ "notebooks": [
      { "name": "Work", "path": "~/work/notes/" }, // trailing
      "~/Notes",
      { "path": "relative/no" },
      "~/Notes",
    ],
    "defaultNotebook": "Notes",
    "inboxFolder": "",
    "journalFolder": "../escape",
    "journalTimestamps": false,
    "editor": "nvim", // comment with "quotes"
  }
  // after`
  const s = Jot.parseConfig(text, HOME)
  assert.ok(s.ok)
  assert.deepStrictEqual(s.notebooks, [{ name: "Work", path: "/home/u/work/notes" }, { name: "Notes", path: "/home/u/Notes" }])
  assert.strictEqual(s.defaultIndex, 1)
  assert.strictEqual(s.inboxFolder, "")
  assert.strictEqual(s.journalFolder, "journal")
  assert.strictEqual(s.journalTimestamps, false)
  assert.strictEqual(s.editor, "nvim")
})

test("comment markers inside strings survive", () => {
  const out = JSON.parse(Jot.stripJsonc('{"a": "http://x/*y*/", "b": "c,]"}'))
  assert.deepStrictEqual(out, { a: "http://x/*y*/", b: "c,]" })
})

test("broken config falls back and says so", () => {
  const s = Jot.parseConfig("{nope", HOME)
  assert.strictEqual(s.ok, false); assert.strictEqual(s.notebooks.length, 1)
})

test("raw HTML in a preview is escaped", () => {
  const out = Jot.sanitizeMarkdown('hi <img src="https://example.invalid/tracker"> there')
  assert.ok(!/(^|[^\\])<img/.test(out), out)
})

test("images become alt text", () => {
  const out = Jot.sanitizeMarkdown("![cat](https://example.invalid/cat.png) and ![](x.png)")
  assert.ok(!out.includes("!["), out)
  assert.ok(out.includes("▣ cat"), out)
})

test("reference image definitions are neutralized", () => {
  const out = Jot.sanitizeMarkdown("![a][r]\n\n[r]: https://example.invalid/t.png")
  assert.ok(!out.includes("example.invalid"), out)
})

test("code blocks are left literal", () => {
  const md = "```\n<div>&amp;</div>\n```\n`<b>` inline"
  const out = Jot.sanitizeMarkdown(md)
  assert.ok(out.includes("```\n<div>&amp;</div>\n```"), out)
  assert.ok(out.includes("`<b>`"), out)
})

test("unclosed backtick does not shield HTML", () => {
  const out = Jot.sanitizeMarkdown("a ` <img src=x>")
  assert.ok(out.includes("\\<img"), out)
})

test("front matter is hidden", () => {
  assert.strictEqual(Jot.sanitizeMarkdown("---\ntitle: x\n---\n# Hi"), "# Hi")
})

test("notebook args are argv pairs", () => {
  assert.deepStrictEqual(Jot.notebookArgs([{ name: "A", path: "/a" }]), ["--nb", "A", "/a"])
})

test("title falls back to filename", () => {
  assert.strictEqual(Jot.displayTitle({ title: null, filename: "abcd.md" }), "abcd")
})

test("cycle wraps both ways", () => {
  assert.strictEqual(Jot.cycle(0, -1, 3), 2)
  assert.strictEqual(Jot.cycle(2, 1, 3), 0)
})

const TYPES = [{ id: "meeting", label: "Встреча" }, { id: "book", label: "book" }]

test("slash alone suggests every type", () => {
  const r = Jot.parseTypePrefix("/", TYPES)
  assert.strictEqual(r.mode, "suggest"); assert.strictEqual(r.matches.length, 2)
})

test("suggestions match id or translated label", () => {
  assert.deepStrictEqual(Jot.parseTypePrefix("/вст", TYPES).matches.map(t => t.id), ["meeting"])
  assert.deepStrictEqual(Jot.parseTypePrefix("/MEE", TYPES).matches.map(t => t.id), ["meeting"])
  assert.strictEqual(Jot.parseTypePrefix("/zz", TYPES).matches.length, 0)
})

test("a known type and a space start a typed note", () => {
  const r = Jot.parseTypePrefix("/встреча Планёрка\nтекст", TYPES)
  assert.strictEqual(r.mode, "typed"); assert.strictEqual(r.typeId, "meeting"); assert.strictEqual(r.rest, "Планёрка\nтекст")
})

test("an unknown type is plain text", () => {
  const r = Jot.parseTypePrefix("/usr/bin is a path", TYPES)
  assert.strictEqual(r.mode, "none"); assert.strictEqual(r.rest, "/usr/bin is a path")
})

test("text without a slash is untouched", () => {
  assert.strictEqual(Jot.parseTypePrefix("hello /meeting", TYPES).mode, "none")
})

test("type names follow bin/jot's rule", () => {
  for (const ok of ["рецепт", "idea", "ok-name_1"]) assert.ok(Jot.validTypeName(ok), ok)
  for (const bad of ["", "a/b", "a.b", "two words", "journal", '"q', "x]", "a\\b", "it's", "a=b", "x".repeat(41)])
    assert.ok(!Jot.validTypeName(bad), bad)
})

test("defaultCapture accepts only journal or note", () => {
  assert.strictEqual(Jot.parseConfig('{"defaultCapture": "journal"}', HOME).defaultCapture, "journal")
  assert.strictEqual(Jot.parseConfig('{"defaultCapture": "weird"}', HOME).defaultCapture, "note")
})

process.exit(failed ? 1 : 0)
