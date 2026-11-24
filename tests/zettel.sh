#!/bin/bash
# bash tests/zettel.sh — runs bin/zettel against throwaway notebooks. Needs zk and jq.
# Nothing outside a temporary directory is touched: every path Zettel writes to
# is redirected with its ZETTEL_* variables, and a fake hyprctl reports no bindings.

set -uo pipefail
export LC_ALL=C.UTF-8

ZETTEL=$(cd "$(dirname "$0")/.." && pwd)/bin/zettel
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ZETTEL_CONFIG=$TMP/config/config.jsonc
export ZETTEL_STATE_DIR=$TMP/state
export ZETTEL_BINDINGS=$TMP/bindings.lua
export ZETTEL_BIN_LINK=$TMP/bin/zettel
mkdir -p "$TMP/path"
printf '#!/bin/sh\necho "[]"\n' >"$TMP/path/hyprctl"
chmod +x "$TMP/path/hyprctl"
export PATH=$TMP/path:$PATH   # every shortcut counts as free

failed=0
ok() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n     %s\n' "$1" "$2"; failed=$((failed + 1)); }
check() { # name, actual, expected
  if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1" "expected [$3], got [$2]"; fi
}

NB=$TMP/notes
zettel() { "$ZETTEL" "$@"; }

# --- init
check "init creates a notebook" "$(zettel init "$NB" | jq -r .created)" "true"
check "init leaves an existing notebook alone" "$(zettel init "$NB" | jq -r .created)" "false"
check "new notebooks have no types" "$(zettel types --nb N "$NB" | jq -c '[.[].id]')" "[]"

# --- new
path=$(zettel new --nb N "$NB" -- $'Встреча с командой #работа\nобсудили релиз' | jq -r .path)
check "new note lands in the inbox" "$(basename "$(dirname "$path")")" "inbox"
check "title loses its hashtags" "$(head -1 "$path")" "# Встреча с командой"
check "hashtags move to the body" "$(grep -c '^#работа$' "$path")" "1"
zettel new --nb N "$NB" -- 'Meeting notes about release' >/dev/null
zettel new --nb N "$NB" -- 'Заметка с "кавычками" и * звёздочкой OR NOT' >/dev/null
long=$(zettel new --nb N "$NB" -- "$(printf 'очень%.0s ' {1..40})" | jq -r .path)
check "long titles make short file names" "$((${#long} - ${#NB} < 90))" "1"
dash=$(zettel new --nb N "$NB" -- '- shopping list' | jq -r '.path // .error')
check "a title starting with a dash is saved" "$(head -1 "$dash" 2>/dev/null)" "# - shopping list"
touch "$TMP/SECRETFILE"
globbed=$(cd "$TMP" && zettel new --nb N "$NB" --inbox scratch -- 'Buy milk #* #it'"'"'s #a\b' | jq -r .path)
check "tags are not glob-expanded" "$(grep -c SECRETFILE "$globbed")" "0"
check "odd tags survive" "$(tail -1 "$globbed")" '#* #it'"'"'s #a\b'
check "empty notes are refused" "$(zettel new --nb N "$NB" -- '   ' | jq -r .error)" "empty note"
check "--inbox \"\" saves at the top" "$(dirname "$(zettel new --nb N "$NB" --inbox '' -- 'top' | jq -r .path)")" "$NB"
check "--inbox cannot escape the notebook" "$(zettel new --nb N "$NB" --inbox ../x -- y | jq -r .error)" "--inbox must be a folder inside the notebook"

# --- search
titles() { zettel search --nb N "$NB" -- "$1" | jq -c '[.notes[].title] | sort'; }
check "prefix search" "$(titles 'встреч')" '["Встреча с командой"]'
check "search ignores case" "$(titles 'ВСТРЕЧА')" '["Встреча с командой"]'
check "endings are forgiven" "$(titles 'встречи')" '["Встреча с командой"]'
check "е matches ё" "$(titles 'звездочкой')" '["Заметка с \"кавычками\" и * звёздочкой OR NOT"]'
check "tags filter by prefix" "$(titles '#раб')" '["Встреча с командой"]'
check "query syntax is inert" "$(titles '* AND (')" '[]'
check "an empty query lists recent notes" "$(zettel search --nb N "$NB" -- '' | jq '.notes | length')" "7"
check "a missing notebook is reported, not fatal" \
  "$(zettel search --nb N "$NB" --nb Gone "$TMP/gone" -- 'meet' | jq -c '[(.notes | length), .errors]')" '[1,["Gone"]]'

# --- daily
d=$(zettel daily --nb N "$NB" --title-label 'Saturday, 21' -- $'first\nsecond line' | jq -r .path)
zettel daily --nb N "$NB" --no-timestamps -- 'third' >/dev/null
check "journal file per day" "$(basename "$d")" "$(date +%F).md"
check "journal heading comes from Zettel" "$(head -1 "$d")" "# Saturday, 21"
check "journal entries carry the time" "$(grep -cE '^- [0-9]{2}:[0-9]{2} first$' "$d")" "1"
check "continuation lines are indented" "$(grep -c '^  second line$' "$d")" "1"
check "--no-timestamps" "$(grep -c '^- third$' "$d")" "1"
check "custom journal folder" "$(basename "$(dirname "$(zettel daily --nb N "$NB" --journal days -- x | jq -r .path)")")" "days"
check "no stray notes in a custom journal folder" "$(ls "$NB/days" | wc -l)" "1"

# --- types
check "add a type" "$(zettel types add рецепт --nb N "$NB" | jq -r .dir)" "рецепт"
check "duplicate types are refused" "$(zettel types add рецепт --nb N "$NB" | jq -r .error)" "type рецепт already exists"
check "journal is reserved" "$(zettel types add journal --nb N "$NB" | jq -r .error)" "journal is built in"
for bad in 'a/b' 'a.b' 'two words' '"q' 'x]' 'a\b' "it's" 'a=b' 'a:b' 'a*' 'a?' 'a<b' 'a>b' 'a|b'; do
  check "bad type name: $bad" "$(zettel types add "$bad" --nb N "$NB" | jq -r 'has("error")')" "true"
done
check "zk still reads the config" "$(zk list --notebook-dir "$NB" -q -P --format '{{title}}' >/dev/null 2>&1 && echo yes)" "yes"
typed=$(zettel new --nb N "$NB" --type рецепт -- $'Борщ\nсвёкла' | jq -r .path)
check "typed notes go to their folder" "$(basename "$(dirname "$typed")")" "рецепт"
printf '# 💡 {{title}}\n' >"$NB/.zk/templates/idea.md"
idea=$(zettel new --nb N "$NB" --type idea -- $'Идея\nтекст' | jq -r .path)
check "text survives a template without {{content}}" "$(grep -c '^текст$' "$idea")" "1"
check "unknown types are refused" "$(zettel new --nb N "$NB" --type nope -- x | jq -r .error)" "unknown note type: nope"

# --- config and notebooks
check "config is created on demand" "$(zettel config | jq -r .path)" "$ZETTEL_CONFIG"
zettel notebook add Work "$TMP/work" >/dev/null
check "notebook add creates the notebook" "$([[ -d $TMP/work/.zk ]] && echo yes)" "yes"
check "notebook default" "$(zettel notebook default Work | jq -r .defaultNotebook)" "Work"
check "duplicate names are refused" "$(zettel notebook add Work "$TMP/x" | jq -r .error)" "a notebook named Work already exists"
sed -i 's/"journalTimestamps": true,/"journalTimestamps": false, \/\/ edited by hand/' "$ZETTEL_CONFIG"
cp "$ZETTEL_CONFIG" "$TMP/config.bak"
printf '// only a comment\n' >"$ZETTEL_CONFIG"
check "a comment-only config means defaults" "$(zettel notebook list | jq -r .defaultNotebook)" "Notes"
zettel notebook add Spare "$TMP/spare" >/dev/null
check "and can be added to" "$(zettel notebook list | jq -r '[.notebooks[].name] | join(",")')" "Notes,Spare"
cp "$TMP/config.bak" "$ZETTEL_CONFIG"
check "hand edits with comments still parse" "$(zettel notebook list | jq -r '.notebooks | length')" "2"
zettel notebook remove Notes >/dev/null
check "the last notebook stays" "$(zettel notebook remove Work | jq -r .error)" "cannot remove the last notebook"

# --- symlinked dotfiles
mkdir -p "$TMP/dotfiles"
cp "$ZETTEL_CONFIG" "$TMP/dotfiles/config.jsonc"
chmod 640 "$TMP/dotfiles/config.jsonc"
ln -sf "$TMP/dotfiles/config.jsonc" "$ZETTEL_CONFIG"
zettel notebook default Work >/dev/null
check "a symlinked config stays a symlink" "$([[ -L $ZETTEL_CONFIG ]] && echo yes)" "yes"
check "its target is updated" "$(grep -c '"defaultNotebook": "Work"' "$TMP/dotfiles/config.jsonc")" "1"
check "and keeps its permissions" "$(stat -c %a "$TMP/dotfiles/config.jsonc")" "640"

# --- type names from hand-written configs
printf '\n[group."my notes"]\npaths = ["my notes"]\n' >>"$NB/.zk/config.toml"
check "group names keep their spaces" "$(zettel types --nb N "$NB" | jq -r '[.[].id] | index("my notes") != null')" "true"
check "type names cannot look like options" "$(zettel types add -- --nb --nb N "$NB" | jq -r 'has("error")')" "true"

# --- sync
check "new notebooks keep the index out of git" "$(grep -cxF '.zk/notebook.db*' "$NB/.gitignore")" "1"
check "and out of Syncthing" "$(grep -cxF '/.zk/notebook.db*' "$NB/.stignore")" "1"
mkdir -p "$TMP/old/.zk"; printf 'node_modules\n' >"$TMP/old/.gitignore"
check "init on an existing notebook adds only the sync files" "$(zettel init "$TMP/old" | jq -c .updated)" '[".gitattributes",".gitignore",".stignore"]'
check "and keeps what was there" "$(head -1 "$TMP/old/.gitignore")" "node_modules"
check "running it again changes nothing" "$(zettel init "$TMP/old" | jq -c .updated)" "[]"
touch "$NB/inbox/a.sync-conflict-20261121-1234-ABC.md" "$NB/inbox/b (x's conflicted copy 2026-11-21).md"
check "sync conflicts are reported" "$(zettel status --nb N "$NB" | jq '.notebooks[0].conflicts | length')" "2"
check "each copy names its original" "$(zettel status --nb N "$NB" | jq -c '[.notebooks[0].conflicts[].original]')" '["inbox/a.md","inbox/b.md"]'
touch "$NB/inbox/c.md.conflict2" "$NB/inbox/d-safeBackup-0001.md" "$NB/inbox/e_conflict-20261121-1.md"
check "other tools' copies too" "$(zettel status --nb N "$NB" | jq -c '[.notebooks[0].conflicts[].original] | sort')" '["inbox/a.md","inbox/b.md","inbox/c.md","inbox/d.md","inbox/e.md"]'
rm -f "$NB/inbox/c.md.conflict2" "$NB/inbox/d-safeBackup-0001.md" "$NB/inbox/e_conflict-20261121-1.md"
rm -f "$NB/inbox/"*.sync-conflict-* "$NB/inbox/"*conflicted*
if command -v git >/dev/null 2>&1; then
  G=$TMP/gitsync
  zettel init "$G/a" >/dev/null
  git -C "$G/a" init -q && git -C "$G/a" add -A && git -C "$G/a" -c user.name=t -c user.email=t@t commit -qm init
  git clone -q "$G/a" "$G/b"
  zettel daily --nb A "$G/a" -- 'from machine a' >/dev/null
  zettel daily --nb B "$G/b" -- 'from machine b' >/dev/null
  git -C "$G/a" add -A && git -C "$G/a" -c user.name=t -c user.email=t@t commit -qm a
  git -C "$G/b" add -A && git -C "$G/b" -c user.name=t -c user.email=t@t commit -qm b
  git -C "$G/b" -c user.name=t -c user.email=t@t pull -q --no-rebase --no-edit 2>/dev/null
  day=$G/b/journal/$(date +%F).md
  check "git merges one day's journal from two machines" \
    "$(grep -c 'from machine' "$day")$(grep -c '^<<<<<<<' "$day")" "20"
  check "the index is not committed" "$(git -C "$G/b" ls-files .zk | grep -c notebook.db)" "0"
fi

# --- zk outside Zettel
check "zk daily is defined" "$(grep -c '^daily = ' "$NB/.zk/config.toml")" "1"
check "zk daily opens the day Zettel writes to" \
  "$(cd "$NB" && zk new --no-input --print-path "$NB/journal" 2>/dev/null)" "$NB/journal/$(date +%F).md"
check "markdown keeps LF line endings in git" "$(grep -cxF '*.md text eol=lf' "$NB/.gitattributes")" "1"
mkdir -p "$TMP/older/.zk/templates"
printf '# {{title}}\n' >"$TMP/older/.zk/templates/journal.md"
printf '[note]\ntemplate = "default.md"\n' >"$TMP/older/.zk/config.toml"
check "an older Zettel notebook is brought up to date" "$(zettel init "$TMP/older" | jq -c '.updated | sort')" \
  '[".gitattributes",".gitignore",".stignore","config.toml","journal.md"]'
check "its journal template gets a date" "$(cat "$TMP/older/.zk/templates/journal.md")" "# {{format-date now '%Y-%m-%d'}}"
check "zk still reads its config" "$(zk list --notebook-dir "$TMP/older" -q -P >/dev/null 2>&1 && echo yes)" "yes"
printf '[alias]\nmine = "zk list"\n' >"$TMP/older2.toml"
mkdir -p "$TMP/older2/.zk"; mv "$TMP/older2.toml" "$TMP/older2/.zk/config.toml"
zettel init "$TMP/older2" >/dev/null
check "an existing [alias] table is left alone" "$(grep -c '^\[alias\]' "$TMP/older2/.zk/config.toml")" "1"
check "a journal template the user changed is left alone" \
  "$(printf '# My day\n' >"$TMP/older/.zk/templates/journal.md"; zettel init "$TMP/older" >/dev/null; cat "$TMP/older/.zk/templates/journal.md")" "# My day"

# --- setup
printf -- '-- mine\no.bind("SUPER + X", "x", "x")\n' >"$ZETTEL_BINDINGS"
before=$(cat "$ZETTEL_BINDINGS")
check "check offers Super+N" "$(zettel setup --check | jq -r '[.asked, .offer] | join(" ")')" "false SUPER + N"
check "check changes nothing" "$(cat "$ZETTEL_BINDINGS"; [[ -e $ZETTEL_BIN_LINK || -e $ZETTEL_STATE_DIR/setup.json ]] && echo touched)" "$before"
check "declining binds nothing" "$(zettel setup --no-shortcut | jq -r .shortcutAdded; cat "$ZETTEL_BINDINGS")" "false"$'\n'"$before"
check "and is remembered" "$(zettel setup --check | jq -r .asked)" "true"
rm -rf "$ZETTEL_STATE_DIR"; rm -f "$ZETTEL_BIN_LINK"
first=$(zettel setup)
check "agreeing binds Super+N" "$(jq -r .shortcut <<<"$first")" "SUPER + N"
check "and links the command" "$(readlink -f "$ZETTEL_BIN_LINK")" "$(readlink -f "$ZETTEL")"
check "the question is asked once" "$(zettel setup --check | jq -r .asked)" "true"
check "setup does not bind twice" "$(zettel setup >/dev/null; grep -c lipchanskiy.zettel "$ZETTEL_BINDINGS")" "2"
zettel setup --remove >/dev/null
check "remove keeps the user's bindings, without leftovers" "$(cat "$ZETTEL_BINDINGS")" $'-- mine\no.bind("SUPER + X", "x", "x")'
check "remove drops the link" "$([[ -e $ZETTEL_BIN_LINK ]] && echo yes || echo no)" "no"
check "remove leaves no trailing blank line" "$(tail -c1 "$ZETTEL_BINDINGS" | od -An -c | tr -d ' ')" '\n'
printf -- '-- mine\no.bind("SUPER + N", "my-notes", { panel = "lipchanskiy.zettel" })\n' >"$ZETTEL_BINDINGS"
rm -rf "$ZETTEL_STATE_DIR"
check "an existing binding is found even with a dash in it" "$(zettel setup | jq -r '[.shortcut, .shortcutAdded] | join(" ")')" "SUPER + N false"
rm -f "$ZETTEL_BINDINGS"; rm -rf "$ZETTEL_STATE_DIR"
check "no bindings.lua is reported as such" "$(zettel setup | jq -r '[.shortcut, .bindingsFound] | join(" ")')" " false"

echo
if ((failed)); then echo "$failed failed"; exit 1; fi
echo "all passed"
