#!/usr/bin/env bash
# tests/k9s-keys.sh — prove the shipped k9s key map is sane.
#
# Runs against config/k9s/** with nothing but bash and awk: no yq, no python, no
# k9s. It is the regression gate for four MUST-FIX items:
#
#   C1  no duplicate shortCut inside a scope, and no shortCut that k9s core has
#       already taken (k9s SKIPS a plugin or hotkey whose key is bound — it does
#       not warn on screen, the key just silently does nothing).
#   C2  no Shift-<digit>: k9s maps those to US-layout runes (KeyShift1 = '!',
#       KeyShift7 = '&'), so on a German keyboard they misfire — Shift-7 there
#       types '/', which is k9s's own filter key.
#   C9  an `all`-scoped plugin also binds in k9s's pseudo-views (containers,
#       helm history, ...), so a destructive one must resolve the object first.
#   S8  no plugin may pipe a decoded secret into a clipboard executable, none may
#       put a kubeconfig or secret material in /tmp, and anything that decodes a
#       secret must be `dangerous: true` so k9s drops it on a readOnly context.
#       A plugin that decodes something which is public by construction says so
#       in a `# s8-ok: <why>` comment, and the reason is reviewed here, not in
#       the test.
#
# It also proves what k9s itself would only tell you at runtime: every shortCut
# is a name tcell can resolve (k9s's asKey() walks tcell.KeyNames), every plugin
# has the four fields k9s's JSON schema requires, and no two plugins share a
# name — k9s loads every file in plugins/ into ONE map, so a repeated name means
# one of them is silently dropped.
#
# Exit 0 = clean. Exit 1 = at least one finding, each printed with its file.
set -euo pipefail

DEVENV_HOME=${DEVENV_HOME:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)}
export DEVENV_HOME
# shellcheck source=lib/common.sh
source "${DEVENV_HOME:?}/lib/common.sh"

k9s_dir=${K9S_SRC_DIR:-$DEVENV_HOME/config/k9s}
plugin_dir=$k9s_dir/plugins
hotkeys=$k9s_dir/hotkeys.yaml

[ -d "$plugin_dir" ] || die "no such directory: $plugin_dir"

findings=0
report() {
  findings=$((findings + 1))
  printf 'FAIL  %s\n' "$*"
}
ok() { printf 'ok    %s\n' "$*"; }

tsv=$(devenv_tmpfile)
parse_err=$(devenv_tmpfile)

# ---------------------------------------------------------------------------
# 1. parse — config/k9s/plugins/*.yaml and hotkeys.yaml into
#    kind \t file \t name \t shortCut \t scope \t dangerous \t guarded
#
# The files have a fixed shape (2-space plugin names, 4-space fields, script
# bodies at 8+), so the parser is deliberately strict about indentation: a file
# that does not match the house shape is a finding, not something to guess at.
# ---------------------------------------------------------------------------
parse() {
  awk '
    function emit(   i) {
      if (name == "") return
      if (sc == "")   { err(name ": no shortCut") }
      if (desc == "") { err(name ": no description") }
      if (cmd == "" && kind == "plugin")  { err(name ": no command") }
      if (nsc == 0 && kind == "plugin")   { err(name ": no scopes") }
      if (kind == "hotkey") { nsc = 1; scope[1] = "*" }
      for (i = 1; i <= nsc; i++)
        printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\n", kind, fname, name, sc, scope[i], dang, guard
      name = ""
    }
    function err(m) { print FILENAME ": " m > "/dev/stderr"; rc = 1 }
    function reset() {
      name = ""; sc = ""; desc = ""; cmd = ""; dang = 0; guard = 0; nsc = 0
      delete scope
    }
    BEGIN { rc = 0; reset() }
    FNR == 1 {
      emit(); reset()
      fname = FILENAME; sub(/.*\//, "", fname)
      kind = (fname == "hotkeys.yaml") ? "hotkey" : "plugin"
      seenroot = 0
    }
    /^(plugins|hotKeys):[ \t]*$/ { seenroot = 1; next }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    # a new plugin / hotkey: exactly two spaces, nothing after the colon
    /^  [A-Za-z0-9][A-Za-z0-9_.-]*:[ \t]*$/ {
      emit()
      if (!seenroot) err("keys before the root " (kind == "hotkey" ? "hotKeys:" : "plugins:") " map")
      name = $0
      sub(/^  /, "", name); sub(/:[ \t]*$/, "", name)
      sc = ""; desc = ""; cmd = ""; dang = 0; guard = 0; nsc = 0
      delete scope
      next
    }
    # a field of the current plugin: exactly four spaces
    /^    [A-Za-z]+:/ {
      if (name == "") { err("field outside any plugin: " $0); next }
      key = $0; sub(/^    /, "", key); sub(/:.*$/, "", key)
      val = $0; sub(/^    [A-Za-z]+:[ \t]*/, "", val)
      sub(/[ \t]+$/, "", val)
      if (key == "shortCut")    { sc = val }
      else if (key == "description") { desc = val }
      else if (key == "command")     { cmd = val }
      else if (key == "dangerous")   { dang = (val == "true") }
      else if (key == "scopes") {
        if (val ~ /^\[.*\]$/) {
          gsub(/^\[|\]$/, "", val); gsub(/[ \t]/, "", val)
          nsc = split(val, sarr, ",")
          for (i = 1; i <= nsc; i++) scope[i] = sarr[i]
        } else if (val != "") {
          err(name ": scopes must be a flow list, got: " val)
        }
        inscopes = (val == "")
        next
      }
      else if (key !~ /^(args|override|confirm|background|overwriteOutput|pipes|inputs|keepHistory)$/) {
        err(name ": unknown field " key)
      }
      inscopes = 0
      next
    }
    # block-form scopes:   scopes:\n      - pods
    inscopes && /^      - / {
      val = $0; sub(/^      - /, "", val); sub(/[ \t]+$/, "", val)
      scope[++nsc] = val
      next
    }
    {
      inscopes = 0
      # script body: remember whether a destructive plugin resolves its object
      line = $0
      if (line ~ /^[ \t]*#/) next
      if (line ~ /-o name >\/dev\/null/) guard = 1
    }
    END { emit(); exit rc }
  ' "$@"
}

if ! parse "$plugin_dir"/*.yaml "$hotkeys" >"$tsv" 2>"$parse_err"; then
  while IFS= read -r l; do report "malformed: $l"; done <"$parse_err"
else
  ok "$(awk -F'\t' '$1=="plugin"' "$tsv" | cut -f3 | sort -u | wc -l) plugins /" \
    "$(awk -F'\t' '$1=="plugin"' "$tsv" | cut -f5 | sort -u | wc -l) scopes /" \
    "$(awk -F'\t' '$1=="hotkey"' "$tsv" | wc -l) hotkeys parsed"
fi
[ -s "$tsv" ] || die "parsed nothing out of $plugin_dir"

# ---------------------------------------------------------------------------
# 2. every shortCut must be a name k9s can resolve, and must not be reserved
#
# k9s resolves a shortCut by walking tcell.KeyNames (internal/view/helpers.go,
# asKey), so anything not in that table is dead on arrival. The reserved table
# below is transcribed from the k9s sources with the binding site named; the
# lowercase letters and the bare digits are core's across the board (browser.go
# binds 0-9 to the favourite namespaces).
# ---------------------------------------------------------------------------
check_keys=$(
  awk -F'\t' '
    BEGIN {
      # An entry that names a k9s source file was read there. The handful that
      # do not (app-level Ctrl-A and Ctrl-C, the tview paging keys, Shift-J)
      # come from the documented k9s key map. Being wrong about one of those
      # costs only a key we were not going to use: the table errs at reserving.
      # NB: no apostrophes below - this whole program is a single-quoted string.
      #
      # bound in EVERY table view
      R["Shift-A"] = "Sort Age (view_table.go)"
      R["Shift-N"] = "Sort Name (view_table.go)"
      R["Shift-S"] = "Sort Status (view_table.go)"
      R["Shift-O"] = "Sort Selected Column (view_table.go)"
      R["Shift-P"] = "Sort Namespace, added to every all-namespace view (ui_table.go doUpdate)"
      R["Ctrl-A"]  = "Aliases view"
      R["Ctrl-C"]  = "Quit"
      R["Ctrl-D"]  = "Delete (browser.go)"
      R["Ctrl-R"]  = "Refresh (browser.go)"
      R["Ctrl-S"]  = "Save (view_table.go)"
      R["Ctrl-W"]  = "Toggle Wide (view_table.go)"
      R["Ctrl-Z"]  = "Toggle Faults (view_table.go)"
      R["Ctrl-B"]  = "page up (tview table)"
      R["Ctrl-F"]  = "page down (tview table)"
      R["Enter"]   = "View (browser.go)"
      R["Esc"]     = "back"
      R["space"]   = "Mark (view_table.go)"
      R["?"]       = "Help (view_table.go)"
      R["/"]       = "Filter (view_table.go)"
      # bound only in some views — an `all`-scoped plugin hits them too
      S["containers" SUBSEP "Shift-F"] = "PortForward (container.go)"
      S["pods" SUBSEP "Ctrl-K"]        = "Kill (pod.go)"
      S["pods" SUBSEP "Shift-J"]       = "Jump To Owner"
      S["deployments" SUBSEP "Shift-J"]  = "Jump To Owner"
      S["statefulsets" SUBSEP "Shift-J"] = "Jump To Owner"
      S["daemonsets" SUBSEP "Shift-J"]   = "Jump To Owner"
    }
    {
      kind = $1; file = $2; name = $3; key = $4; scope = $5
      what = kind " " name " (" file ", scope " scope ")"
      if (key ~ /^Shift-[0-9]$/) {
        print "C2 " what ": Shift-<digit> is a US-layout rune (k9s KeyShift" \
              substr(key, 7) "), it misfires on a German keyboard"
        next
      }
      if (key !~ /^(Shift-)?[A-Za-z]$/ && key !~ /^Ctrl-[A-Za-z]$/ &&
          key !~ /^F([1-9]|1[0-9]|2[0-4])$/ &&
          key !~ /^(Enter|Esc|Tab|Backspace|Backspace2|Delete|Insert|Home|End|PgUp|PgDn|Up|Down|Left|Right|space|\?|\/)$/) {
        print "KEY " what ": \"" key "\" is not a tcell key name — k9s asKey() will refuse it"
        next
      }
      if (key ~ /^[a-z0-9]$/) {
        print "C1 " what ": bare \"" key "\" belongs to k9s core (lowercase keys and 0-9 are taken in every view)"
        next
      }
      if (key in R) print "C1 " what ": " key " is k9s core — " R[key]
      if ((scope SUBSEP key) in S) print "C1 " what ": " key " is k9s core in " scope " — " S[scope SUBSEP key]
      if (scope == "all" || scope == "*") {
        for (k in S) {
          split(k, a, SUBSEP)
          if (a[2] == key)
            print "C1 " what ": " key " is k9s core in the " a[1] " view — " S[k] \
                  " (this binding covers every view)"
        }
      }
    }
  ' "$tsv"
)
if [ -n "$check_keys" ]; then
  while IFS= read -r l; do report "$l"; done <<<"$check_keys"
else
  ok "no shortCut collides with a k9s built-in, and none is Shift-<digit>"
fi

# ---------------------------------------------------------------------------
# 3. collisions between our own bindings
#
# Two bindings clash when they share a scope, when either is `all` (every view),
# or when either is a hotkey (hotkeys are global). k9s adds plugins first, then
# hotkeys, and skips whichever comes second unless `override: true` — so a clash
# is a silently dead key either way.
# ---------------------------------------------------------------------------
check_dupes=$(
  awk -F'\t' '
    { kind[NR] = $1; file[NR] = $2; name[NR] = $3; key[NR] = $4; scope[NR] = $5; n = NR }
    END {
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++) {
          if (key[i] != key[j]) continue
          if (name[i] == name[j] && kind[i] == kind[j]) continue   # same entry, two scopes
          global_i = (scope[i] == "all" || scope[i] == "*")
          global_j = (scope[j] == "all" || scope[j] == "*")
          if (scope[i] != scope[j] && !global_i && !global_j) continue
          where = (scope[i] == scope[j]) ? ("scope " scope[i]) : \
                  ("scopes " scope[i] " + " scope[j])
          k = key[i] SUBSEP name[i] SUBSEP name[j]
          if (k in seen) continue
          seen[k] = 1
          print "C1 " key[i] " is bound twice in " where ": " \
                kind[i] " " name[i] " (" file[i] ") and " kind[j] " " name[j] " (" file[j] ")"
        }
    }
  ' "$tsv"
)
if [ -n "$check_dupes" ]; then
  while IFS= read -r l; do report "$l"; done <<<"$check_dupes"
else
  ok "no shortCut is bound twice in a scope, and no hotkey shadows a plugin"
fi

# every plugin name must be unique: k9s merges all files into one map
dupe_names=$(awk -F'\t' '$1=="plugin"{print $3"\t"$2}' "$tsv" | sort -u | cut -f1 | sort | uniq -d)
if [ -n "$dupe_names" ]; then
  while IFS= read -r l; do
    report "C1 plugin name \"$l\" is used in more than one file — k9s keeps only one of them"
  done <<<"$dupe_names"
else
  ok "every plugin name is unique across config/k9s/plugins/"
fi

# ---------------------------------------------------------------------------
# 4. C9 — a destructive `all`-scoped plugin must resolve its object first
# ---------------------------------------------------------------------------
unguarded=$(awk -F'\t' '$1=="plugin" && $5=="all" && $6==1 && $7==0 {print $3" ("$2")"}' "$tsv" | sort -u)
if [ -n "$unguarded" ]; then
  while IFS= read -r l; do
    report "C9 $l is dangerous and scoped \`all\`, but never resolves the object" \
      "(it would fire in pseudo-views like containers or helm history) — probe with \`kubectl get … -o name >/dev/null\` first"
  done <<<"$unguarded"
else
  ok "every dangerous \`all\`-scoped plugin resolves its object before acting"
fi

# ---------------------------------------------------------------------------
# 5. S8 — secrets never reach a clipboard or /tmp
#
# Comment lines are skipped: the plugins explain in comments why they do NOT
# call clip.exe, and that must not read as a violation.
# ---------------------------------------------------------------------------
leaks=$(
  awk '
    FNR == 1 { fname = FILENAME; sub(/.*\//, "", fname) }
    /^[ \t]*#/ { next }
    /clip\.exe/            { print fname ":" FNR ": pipes to clip.exe" }
    /mktemp[^\n]*-t /      { print fname ":" FNR ": mktemp -t writes into /tmp" }
    /(^|[^A-Za-z0-9_.-])\/tmp\// { print fname ":" FNR ": writes into /tmp" }
  ' "$plugin_dir"/*.yaml
)
if [ -n "$leaks" ]; then
  while IFS= read -r l; do
    report "S8 $l — decoded secrets and kubeconfigs stay in the pager or in a 0700 runtime dir"
  done <<<"$leaks"
else
  ok "no plugin writes to /tmp and none pipes to a clipboard executable"
fi

# a plugin that decodes a secret must be dangerous:true, so that k9s drops it on
# a readOnly (prod) context
#
# The pending plugin is flushed through ONE function, called from all three
# places a plugin can end: the next plugin header, the first line of the NEXT
# FILE, and end of input. The middle one is the one that was missing. awk's
# FNR == 1 rule reset `name` without judging it, so the LAST plugin of every file
# but the last was thrown away unexamined — 11 of the 57 shipped plugins,
# `secret-show-value` among them, which is a Shift-C that decodes a secret key
# into a pager. Deleting its `dangerous: true` still printed "ok". The same
# violation one plugin higher in the same file fired correctly, which is what a
# blind spot looks like from the outside: the rule works, on the inputs it sees.
undecl=$(
  awk '
    function flush() { if (name != "" && dec && !dang) print name " (" fname ")" }
    FNR == 1 {
      flush()
      fname = FILENAME; sub(/.*\//, "", fname); name = ""; dang = 0; dec = 0; allow = 0
    }
    /^  [A-Za-z0-9][A-Za-z0-9_.-]*:[ \t]*$/ {
      flush()
      name = $0; sub(/^  /, "", name); sub(/:[ \t]*$/, "", name); dang = 0; dec = 0; allow = 0
      next
    }
    /^    dangerous:[ \t]*true[ \t]*$/ { dang = 1 }
    /[sS]8-ok:/ { dec = 0; allow = 1; next }
    /^[ \t]*#/ { next }
    /@base64d|base64 -d|base64 --decode|modify-secret/ { if (!allow) dec = 1 }
    END { flush() }
  ' "$plugin_dir"/*.yaml
)
if [ -n "$undecl" ]; then
  while IFS= read -r l; do
    report "S8 $l decodes secret material but is not \`dangerous: true\` — it would stay bound on a readOnly prod context"
  done <<<"$undecl"
else
  ok "every secret-decoding plugin is dangerous:true (hidden on readOnly contexts)"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$findings" -gt 0 ]; then
  log_error "$findings finding(s) in $k9s_dir"
  # a finding is a result, not a crash: drop the ERR trap so the run ends on the
  # line above instead of on a stack trace. The EXIT trap still cleans up.
  trap - ERR
  exit 1
fi
printf 'k9s key map is clean.\n'
