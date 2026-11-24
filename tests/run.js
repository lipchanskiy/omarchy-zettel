// node tests/run.js — checks the pure helpers in Zettel.js.
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "..", "Zettel.js"), "utf8").replace(/^\.pragma library\s*/, "")
const Zettel = new Function(src + "\nreturn { parseConfig, stripJsonc, sanitizeMarkdown, notebookArgs, displayTitle, cycle, expandHome, parseTypePrefix, validTypeName }")()

let failed = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message) }
}

const HOME = "/home/u"

test("config falls back to ~/Notes", () => {
  const s = Zettel.parseConfig("", HOME)
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
  const s = Zettel.parseConfig(text, HOME)
  assert.ok(s.ok)
  assert.deepStrictEqual(s.notebooks, [{ name: "Work", path: "/home/u/work/notes" }, { name: "Notes", path: "/home/u/Notes" }])
  assert.strictEqual(s.defaultIndex, 1)
  assert.strictEqual(s.inboxFolder, "")
  assert.strictEqual(s.journalFolder, "journal")
  assert.strictEqual(s.journalTimestamps, false)
  assert.strictEqual(s.editor, "nvim")
})

test("comment markers inside strings survive", () => {
  const out = JSON.parse(Zettel.stripJsonc('{"a": "http://x/*y*/", "b": "c,]"}'))
  assert.deepStrictEqual(out, { a: "http://x/*y*/", b: "c,]" })
})

test("broken config falls back and says so", () => {
  const s = Zettel.parseConfig("{nope", HOME)
  assert.strictEqual(s.ok, false); assert.strictEqual(s.notebooks.length, 1)
})

// No "<" may be followed by a tag or autolink start, and no "![" may survive.
function inert(out) {
  return !/<[A-Za-z!/?]/.test(out) && !out.includes("![")
}

const ATTACKS = {
  "raw html": 'hi <img src="https://example.invalid/tracker"> there',
  "image": "![cat](https://example.invalid/cat.png)",
  "nested brackets": "![a [b] c](http://example.invalid/x.png)",
  "url on the next line": "![a](\nhttp://example.invalid/x.png)",
  "reference on the next line": "![r]\n\n[r]:\n  http://example.invalid/x.png",
  "reference in a blockquote": "![r]\n\n> [r]: http://example.invalid/x.png",
  "html in a list item": "- item\n\n    <img src=http://example.invalid/x>",
  "backtick in info string": "``` x`\n<img src=http://example.invalid/x>\n```",
  "fence closed by a list": "- a\n  ```\n<img src=http://example.invalid/x>",
  "autolink": "<http://example.invalid/x>",
  "html comment": "<!-- x --><iframe src=http://example.invalid>",
}
for (const [name, md] of Object.entries(ATTACKS)) {
  test("preview is inert: " + name, () => {
    const out = Zettel.sanitizeMarkdown(md)
    assert.ok(inert(out), JSON.stringify(out))
  })
}

test("the preview reads the same once the invisible spaces are ignored", () => {
  const md = "```\n<div>&amp;</div>\n```\n`<b>` and a < b, wow!\n[link](http://x)"
  assert.strictEqual(Zettel.sanitizeMarkdown(md).replace(/​/g, ""), md)
})

test("front matter is hidden", () => {
  assert.strictEqual(Zettel.sanitizeMarkdown("---\ntitle: x\n---\n# Hi"), "# Hi")
})

test("notebook args are argv pairs", () => {
  assert.deepStrictEqual(Zettel.notebookArgs([{ name: "A", path: "/a" }]), ["--nb", "A", "/a"])
})

test("title falls back to filename", () => {
  assert.strictEqual(Zettel.displayTitle({ title: null, filename: "abcd.md" }), "abcd")
})

test("cycle wraps both ways", () => {
  assert.strictEqual(Zettel.cycle(0, -1, 3), 2)
  assert.strictEqual(Zettel.cycle(2, 1, 3), 0)
})

const TYPES = [{ id: "meeting", label: "Встреча" }, { id: "book", label: "book" }]

test("slash alone suggests every type", () => {
  const r = Zettel.parseTypePrefix("/", TYPES)
  assert.strictEqual(r.mode, "suggest"); assert.strictEqual(r.matches.length, 2)
})

test("suggestions match id or translated label", () => {
  assert.deepStrictEqual(Zettel.parseTypePrefix("/вст", TYPES).matches.map(t => t.id), ["meeting"])
  assert.deepStrictEqual(Zettel.parseTypePrefix("/MEE", TYPES).matches.map(t => t.id), ["meeting"])
  assert.strictEqual(Zettel.parseTypePrefix("/zz", TYPES).matches.length, 0)
})

test("a known type and a space start a typed note", () => {
  const r = Zettel.parseTypePrefix("/встреча Планёрка\nтекст", TYPES)
  assert.strictEqual(r.mode, "typed"); assert.strictEqual(r.typeId, "meeting"); assert.strictEqual(r.rest, "Планёрка\nтекст")
})

test("an unknown type is plain text", () => {
  const r = Zettel.parseTypePrefix("/usr/bin is a path", TYPES)
  assert.strictEqual(r.mode, "none"); assert.strictEqual(r.rest, "/usr/bin is a path")
})

test("text without a slash is untouched", () => {
  assert.strictEqual(Zettel.parseTypePrefix("hello /meeting", TYPES).mode, "none")
})

test("type names follow bin/zettel's rule", () => {
  for (const ok of ["рецепт", "idea", "ok-name_1"]) assert.ok(Zettel.validTypeName(ok), ok)
  for (const bad of ["", "a/b", "a.b", "two words", "journal", '"q', "x]", "a\\b", "it's", "a=b", "a:b", "a*", "a?", "a<b", "a>b", "a|b", "-x", "x".repeat(41)])
    assert.ok(!Zettel.validTypeName(bad), bad)
})

test("defaultCapture accepts only journal or note", () => {
  assert.strictEqual(Zettel.parseConfig('{"defaultCapture": "journal"}', HOME).defaultCapture, "journal")
  assert.strictEqual(Zettel.parseConfig('{"defaultCapture": "weird"}', HOME).defaultCapture, "note")
})

process.exit(failed ? 1 : 0)
