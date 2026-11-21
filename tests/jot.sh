#!/bin/bash
# bash tests/jot.sh — runs bin/jot against throwaway notebooks. Needs zk and jq.
# Nothing outside a temporary directory is touched: every path Jot writes to
# is redirected with its JOT_* variables, and a fake hyprctl reports no bindings.

set -uo pipefail
export LC_ALL=C.UTF-8

JOT=$(cd "$(dirname "$0")/.." && pwd)/bin/jot
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export JOT_CONFIG=$TMP/config/config.jsonc
export JOT_STATE_DIR=$TMP/state
export JOT_BINDINGS=$TMP/bindings.lua
export JOT_BIN_LINK=$TMP/bin/jot
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
jot() { "$JOT" "$@"; }

# --- init
check "init creates a notebook" "$(jot init "$NB" | jq -r .created)" "true"
check "init leaves an existing notebook alone" "$(jot init "$NB" | jq -r .created)" "false"
check "new notebooks have no types" "$(jot types --nb N "$NB" | jq -c '[.[].id]')" "[]"

# --- new
path=$(jot new --nb N "$NB" -- $'Встреча с командой #работа\nобсудили релиз' | jq -r .path)
check "new note lands in the inbox" "$(basename "$(dirname "$path")")" "inbox"
check "title loses its hashtags" "$(head -1 "$path")" "# Встреча с командой"
check "hashtags move to the body" "$(grep -c '^#работа$' "$path")" "1"
jot new --nb N "$NB" -- 'Meeting notes about release' >/dev/null
jot new --nb N "$NB" -- 'Заметка с "кавычками" и * звёздочкой OR NOT' >/dev/null
long=$(jot new --nb N "$NB" -- "$(printf 'очень%.0s ' {1..40})" | jq -r .path)
check "long titles make short file names" "$((${#long} - ${#NB} < 90))" "1"
check "empty notes are refused" "$(jot new --nb N "$NB" -- '   ' | jq -r .error)" "empty note"
check "--inbox \"\" saves at the top" "$(dirname "$(jot new --nb N "$NB" --inbox '' -- 'top' | jq -r .path)")" "$NB"
check "--inbox cannot escape the notebook" "$(jot new --nb N "$NB" --inbox ../x -- y | jq -r .error)" "--inbox must be a folder inside the notebook"

# --- search
titles() { jot search --nb N "$NB" -- "$1" | jq -c '[.notes[].title] | sort'; }
check "prefix search" "$(titles 'встреч')" '["Встреча с командой"]'
check "search ignores case" "$(titles 'ВСТРЕЧА')" '["Встреча с командой"]'
check "endings are forgiven" "$(titles 'встречи')" '["Встреча с командой"]'
check "е matches ё" "$(titles 'звездочкой')" '["Заметка с \"кавычками\" и * звёздочкой OR NOT"]'
check "tags filter by prefix" "$(titles '#раб')" '["Встреча с командой"]'
check "query syntax is inert" "$(titles '* AND (')" '[]'
check "an empty query lists recent notes" "$(jot search --nb N "$NB" -- '' | jq '.notes | length')" "5"
check "a missing notebook is reported, not fatal" \
  "$(jot search --nb N "$NB" --nb Gone "$TMP/gone" -- 'meet' | jq -c '[(.notes | length), .errors]')" '[1,["Gone"]]'

# --- daily
d=$(jot daily --nb N "$NB" --title-label 'Saturday, 21' -- $'first\nsecond line' | jq -r .path)
jot daily --nb N "$NB" --no-timestamps -- 'third' >/dev/null
check "journal file per day" "$(basename "$d")" "$(date +%F).md"
check "journal heading comes from Jot" "$(head -1 "$d")" "# Saturday, 21"
check "journal entries carry the time" "$(grep -cE '^- [0-9]{2}:[0-9]{2} first$' "$d")" "1"
check "continuation lines are indented" "$(grep -c '^  second line$' "$d")" "1"
check "--no-timestamps" "$(grep -c '^- third$' "$d")" "1"
check "custom journal folder" "$(basename "$(dirname "$(jot daily --nb N "$NB" --journal days -- x | jq -r .path)")")" "days"
check "no stray notes in a custom journal folder" "$(ls "$NB/days" | wc -l)" "1"

# --- types
check "add a type" "$(jot types add рецепт --nb N "$NB" | jq -r .dir)" "рецепт"
check "duplicate types are refused" "$(jot types add рецепт --nb N "$NB" | jq -r .error)" "type рецепт already exists"
check "journal is reserved" "$(jot types add journal --nb N "$NB" | jq -r .error)" "journal is built in"
for bad in 'a/b' 'a.b' 'two words' '"q' 'x]' 'a\b' "it's" 'a=b'; do
  check "bad type name: $bad" "$(jot types add "$bad" --nb N "$NB" | jq -r 'has("error")')" "true"
done
check "zk still reads the config" "$(zk list --notebook-dir "$NB" -q -P --format '{{title}}' >/dev/null 2>&1 && echo yes)" "yes"
typed=$(jot new --nb N "$NB" --type рецепт -- $'Борщ\nсвёкла' | jq -r .path)
check "typed notes go to their folder" "$(basename "$(dirname "$typed")")" "рецепт"
printf '# 💡 {{title}}\n' >"$NB/.zk/templates/idea.md"
idea=$(jot new --nb N "$NB" --type idea -- $'Идея\nтекст' | jq -r .path)
check "text survives a template without {{content}}" "$(grep -c '^текст$' "$idea")" "1"
check "unknown types are refused" "$(jot new --nb N "$NB" --type nope -- x | jq -r .error)" "unknown note type: nope"

# --- config and notebooks
check "config is created on demand" "$(jot config | jq -r .path)" "$JOT_CONFIG"
jot notebook add Work "$TMP/work" >/dev/null
check "notebook add creates the notebook" "$([[ -d $TMP/work/.zk ]] && echo yes)" "yes"
check "notebook default" "$(jot notebook default Work | jq -r .defaultNotebook)" "Work"
check "duplicate names are refused" "$(jot notebook add Work "$TMP/x" | jq -r .error)" "a notebook named Work already exists"
sed -i 's/"journalTimestamps": true,/"journalTimestamps": false, \/\/ edited by hand/' "$JOT_CONFIG"
check "hand edits with comments still parse" "$(jot notebook list | jq -r '.notebooks | length')" "2"
jot notebook remove Notes >/dev/null
check "the last notebook stays" "$(jot notebook remove Work | jq -r .error)" "cannot remove the last notebook"

# --- setup
printf -- '-- mine\no.bind("SUPER + X", "x", "x")\n' >"$JOT_BINDINGS"
first=$(jot setup --first-run)
check "first run binds Super+N" "$(jq -r .shortcut <<<"$first")" "SUPER + N"
check "first run links the command" "$(readlink -f "$JOT_BIN_LINK")" "$(readlink -f "$JOT")"
check "first run happens once" "$(jot setup --first-run | jq -r .firstRun)" "false"
check "setup does not bind twice" "$(jot setup >/dev/null; grep -c lipchanskiy.jot "$JOT_BINDINGS")" "2"
jot setup --remove >/dev/null
check "remove keeps the user's bindings" "$(cat "$JOT_BINDINGS")" $'-- mine\no.bind("SUPER + X", "x", "x")'
check "remove drops the link" "$([[ -e $JOT_BIN_LINK ]] && echo yes || echo no)" "no"

echo
if ((failed)); then echo "$failed failed"; exit 1; fi
echo "all passed"
