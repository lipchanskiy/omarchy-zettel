# Jot

Find and capture notes from anywhere on your [Omarchy](https://omarchy.org) desktop.

Press **Super+N**, start typing. Jot searches every note as you type and shows the best match on the right. Press **Enter** to open it, or **Ctrl+Enter** to save what you typed as a new note. **Alt+Enter** adds it to today's journal instead. Esc, and you are back where you were.

Notes are plain Markdown files in a folder you own, managed by [zk](https://github.com/zk-org/zk). Jot is only the window: your notes work the same in any editor, in git, in Syncthing, or with zk on the command line.

- **One shortcut** for searching and writing, so a note you already have shows up before you write a duplicate.
- **A daily journal**: one file per day, each entry stamped with the time.
- **Note types**: type `/` to pick one, or name a new one and Jot creates it with its own folder and template.
- **Several notebooks**, searched together; Tab picks where a new note goes.
- **Forgiving search**: matches the start of words, ignores case, and when nothing matches tries again without word endings and with е/ё treated alike.
- **Follows Omarchy**: its theme, its language, and your default editor.

## Requirements

- Omarchy 4 (the Quickshell shell with plugin support)
- [zk](https://github.com/zk-org/zk) and jq. Jot offers to install zk if it is missing; jq ships with Omarchy.

## Install

```bash
omarchy plugin add https://github.com/lipchanskiy/omarchy-jot --enable
```

The first time the shell loads Jot, it sets itself up and tells you so in a notification:

- binds **Super+N** in `~/.config/hypr/bindings.lua`. If Super+N is taken, it tries Super+Alt+N, then Super+Shift+Alt+N; the notification names the one it used;
- links the `jot` command into `~/.local/bin`;
- writes the settings file, `~/.config/jot/config.jsonc`, with every option explained;
- creates your notebook in `~/Notes` the first time you open the window.

Nothing else on your system changes. `jot setup --remove` takes the shortcut and the command back out.

## Using Jot

| Key | What it does |
|---|---|
| **Super+N** | Open or close Jot |
| typing | Search all notebooks; the selected note is previewed on the right |
| **Enter** | Open the selected note in your editor. With no match, save the text (as Ctrl+Enter) |
| **Ctrl+Enter** | Save as a new note (first line is the title) |
| **Alt+Enter** | Add to today's journal |
| **Ctrl+Shift+Enter** | Save as a new note and open it |
| **Shift+Enter** | New line |
| **↑ ↓**, **Ctrl+P/N**, **PgUp/PgDn** | Move through results |
| **Tab** | Choose the notebook new notes go to (with several notebooks) |
| **/** | Note types, see below |
| **Ctrl+E** | Edit the template of the selected note type |
| **Ctrl+,** | Open the settings |
| **Esc** | Clear the text, then close |

Ctrl+Enter and Alt+Enter swap if you set `"defaultCapture": "journal"`.

**Tags.** `#word` anywhere in a search filters by tag (`#wor` finds `#work`). In a new note, hashtags on the first line move out of the title into the text, where zk sees them as tags.

### The journal

Alt+Enter appends what you typed to today's journal, `journal/2026-11-21.md`, as `- 14:05 what you typed`. Several lines stay together under one entry. The first entry of the day writes the heading, the date in your language. `journalFolder` and `journalTimestamps` in the settings change the folder and the time stamps.

### Note types

Type `/` to see them. The journal is always first; after it come the zk groups and templates of the notebook. Pick one with Tab or Enter, then type a title:

```
/recipe Borscht
```

and Enter creates the note in the type's folder, from its template.

**Make your own.** Type `/` and a name that does not exist yet, such as `/recipe`. The list offers *Create type "recipe"*; Enter adds a `recipe/` folder and a `.zk/templates/recipe.md` template to the notebook. **Ctrl+E** on a type opens its template, so you can give it the sections you want. A name is one word, without spaces, quotes, slashes, dots or brackets.

A type is an ordinary zk [group](https://zk-org.github.io/zk/config/config-group.html), so you can also write one by hand in `NOTEBOOK/.zk/config.toml`:

```toml
[group."recipe"]
paths = ["recipe"]

[group."recipe".note]
template = "recipe.md"
```

Templates are [Handlebars](https://zk-org.github.io/zk/notes/template.html). Besides zk's own variables, Jot passes the date in your language as `{{extra.date}}` and the weekday as `{{extra.weekday}}`, and puts what you typed after the title into `{{content}}`. If a template has no `{{content}}`, Jot adds the text at the end of the note so nothing is lost.

## Notebooks

A notebook is a folder of Markdown files with a `.zk` folder inside. Jot starts with one, `~/Notes`. To add another, and create it if needed:

```bash
jot notebook add Work ~/Work/notes
```

or add it to `notebooks` in the settings. With more than one notebook, every search covers all of them, each result shows its notebook, and Tab picks the notebook a new note goes to. A notebook listed in the settings that does not exist yet is created the next time Jot opens.

Pointing Jot at a folder that already has Markdown notes is fine: it adds a `.zk` folder and leaves your files alone.

## Settings

**Ctrl+,** in the Jot window opens `~/.config/jot/config.jsonc`. Changes apply when you save.

```jsonc
{
  "notebooks": [
    { "name": "Notes", "path": "~/Notes" },
    { "name": "Work", "path": "~/Work/notes" }
  ],
  "defaultNotebook": "Notes",     // where new notes and journal entries go
  "defaultCapture": "note",       // Ctrl+Enter: "note" or "journal"; Alt+Enter does the other
  "inboxFolder": "inbox",         // folder for new notes; "" for the top of the notebook
  "journalFolder": "journal",
  "journalTimestamps": true,      // "- 14:05 ..." or "- ..."
  "editor": ""                    // empty: Omarchy's default editor (omarchy default editor)
}
```

`editor` takes a command such as `code` or `nvim`. Terminal editors (nvim, vim, helix, nano, micro, kakoune, emacs) open in a terminal window. If the file has a syntax error, Jot says so at the bottom of the window and uses the defaults until it is fixed.

To change the shortcut, edit the line Jot added to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + N", "Notes", { panel = "lipchanskiy.jot" })
```

## The `jot` command

The window runs everything through `jot`, and it works on its own too. Every command prints JSON.

```bash
jot notebook list                     # notebooks and the default one
jot notebook add NAME PATH            # add a notebook, creating it if needed
jot notebook remove NAME
jot notebook default NAME
jot config                            # create the settings file if missing, print its path
jot setup                             # bind the shortcut and link the command again
jot setup --remove                    # undo both
jot init PATH                         # create a notebook with Jot's defaults
jot types --nb NAME PATH              # note types of a notebook
jot types add TYPE --nb NAME PATH     # add a note type
jot search --nb NAME PATH -- QUERY    # search (repeat --nb for several notebooks)
jot new --nb NAME PATH -- TEXT        # new note; also --type TYPE, --inbox DIR
jot daily --nb NAME PATH -- TEXT      # journal entry; also --journal DIR, --no-timestamps
```

For anything beyond this, use [zk](https://zk-org.github.io/zk/) itself: `zk list`, `zk edit --interactive`, its LSP in your editor, and so on.

## Where things live

| What | Where |
|---|---|
| Your notes | `~/Notes` and any other notebook folder |
| zk's index and templates | `NOTEBOOK/.zk/` |
| Jot's settings | `~/.config/jot/config.jsonc` |
| The shortcut | `~/.config/hypr/bindings.lua` |
| The `jot` command | `~/.local/bin/jot`, a link into the plugin |
| First-run record | `~/.local/state/jot/setup.json` |
| The plugin | `~/.config/omarchy/plugins/lipchanskiy.jot/` |

## Update and uninstall

```bash
omarchy plugin update lipchanskiy.jot
omarchy-restart-shell
```

The shell does not always pick up a plugin's new code on its own; restarting it does.

To uninstall, remove the shortcut and the command first, then the plugin:

```bash
jot setup --remove
omarchy plugin remove lipchanskiy.jot
```

Your notes and `~/.config/jot` stay where they are.

## Troubleshooting

- **Super+N does nothing.** Check that the line above is in `~/.config/hypr/bindings.lua`, and that `omarchy plugin list` shows `lipchanskiy.jot` enabled. Run `jot setup` to add the shortcut again.
- **A change to the plugin does not show up.** Run `omarchy-restart-shell`.
- **Search finds nothing in a notebook.** Run `zk list --notebook-dir PATH`. A syntax error in that notebook's `.zk/config.toml` stops zk from reading it.

## Development

```
manifest.json     plugin manifest (an overlay kept loaded with the shell)
Jot.qml           the window
Jot.js            pure helpers: settings, "/" parsing, safe Markdown preview
bin/jot           everything that touches disk or zk, as a JSON command line
i18n/             interface strings, one file per Omarchy language
tests/run.js      node tests for Jot.js
tests/jot.sh      tests for bin/jot against throwaway notebooks
```

```bash
node tests/run.js
bash tests/jot.sh
omarchy plugin validate .
```

Notes, settings and command output are treated as untrusted text: the preview renders Markdown with raw HTML and images neutralized, notifications are stripped of markup, and user text only reaches commands as arguments, never through a shell.

Translations are welcome: copy `i18n/en.json` to the Omarchy language code (`de.json`, `pt-BR.json`, …) and translate the values.

## License

MIT
