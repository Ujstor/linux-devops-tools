#!/usr/bin/env bash
# meta: name=doctor
# meta: desc=read-only audit of the shell, apt sources, kubernetes, sso and wsl setup
# meta: profiles=devops,full
# meta: os=any
# meta: root=no
#
# DOCTOR IS READ-ONLY. It looks, it reports, and it prints the exact command that
# repairs each finding — it never repairs anything itself, not even with --fix.
# That is deliberate:
#
#   * a report you can run on any box, at any time, with no privileges and no risk
#     is worth more than a repair tool you hesitate to run;
#   * the repairs belong to the modules that own those files —
#       shell drop-ins and ~/.bashrc  -> `devenv --only migrate --apply`
#       browser shim and sso files    -> `devenv --only auth-sso`
#       k9s config                    -> `devenv --only k9s-config`
#       apt sources and keyrings      -> the module that added them
#       desktop residue               -> `devenv --only purge-desktop`
#   * and MUST-FIX S9/S11/S12 forbid the tempting ones outright: no package is
#     removed here, nothing under ~/.kube is ever proposed for deletion, and
#     EXTERNALLY-MANAGED is never moved.
#
# `devenv doctor --fix` therefore prints the repair PLAN and exits. It is honest
# about doing nothing.
#
# Exit status is 0 even when there are findings, so `devenv --profile devops` stays
# green on a machine that merely has warnings. Set DEVENV_DOCTOR_STRICT=1 to make
# any FAIL exit non-zero (that is the form to use in CI).
#
# IN-PROCESS ARTEFACTS, and why some of what follows looks roundabout.
# As module 90 of a profile run, doctor is a CHILD PROCESS of bin/devenv and
# inherits ITS environment — the environment of the shell that started the
# install, which is older than everything the run just did. $PATH in particular
# predates ~/.bashrc.d/10-path.sh (written by module 10) and the ~/.local/bin that
# module 23 created, and a child cannot reach back and fix its parent. So a bare
#     case ":$PATH:" in *":$HOME/.local/bin:"*)
#     have uv
# asks about THIS PROCESS, not about the machine, and on a perfectly good install
# it reported "~/.local/bin is not on PATH", "/usr/bin precedes it" and "uv is not
# installed" seconds after ~/.local/bin/uv had been written.
#
# The rule those three findings taught: a check about something the run just
# installed reads the FILESYSTEM (does the drop-in exist, is the binary there) and
# treats $PATH as evidence about the observer, not the observed. When the two
# disagree, doctor says which is which — a doctor that cries wolf on a clean
# install is worse than one that stays quiet.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

DOC_OK=0
DOC_WARN=0
DOC_FAIL=0
DOC_PLAN=()

ok() {
  DOC_OK=$((DOC_OK + 1))
  log_success "$*"
}
warn() {
  DOC_WARN=$((DOC_WARN + 1))
  log_warn "$*"
}
fail() {
  DOC_FAIL=$((DOC_FAIL + 1))
  log_error "$*"
}
hint() { log_info "     -> $*"; }

# plan CMD…  — record the repair command for the --fix summary. Never runs it.
plan() {
  local c=$*
  local p
  for p in ${DOC_PLAN[@]+"${DOC_PLAN[@]}"}; do
    if [ "$p" = "$c" ]; then return 0; fi
  done
  DOC_PLAN+=("$c")
  hint "$c"
  return 0
}

section() { log_step "doctor: $*"; }
section_end() { log_step_end; }

# ---------------------------------------------------------------------------
# platform
# ---------------------------------------------------------------------------

check_platform() {
  section 'platform'
  os_summary
  if os_require_supported; then
    ok "supported platform: ${OS_PRETTY:-unknown} (${OS_ARCH_DPKG:-unknown})"
  else
    fail "unsupported platform: ${OS_PRETTY:-unknown}"
  fi
  if [ "${OS_ARCH_DPKG:-}" != amd64 ]; then
    warn "architecture ${OS_ARCH_DPKG:-unknown}: only amd64 is tested, arm64 is best-effort"
  fi
  section_end
}

# ---------------------------------------------------------------------------
# apt sources
# ---------------------------------------------------------------------------

# _apt_uris FILE — prints every http(s) URI configured in FILE, one per line.
_apt_uris() {
  local f=$1
  case $f in
    *.sources)
      sed -n 's/^[[:space:]]*URIs:[[:space:]]*//p' "$f" 2>/dev/null | tr ' ' '\n'
      ;;
    *)
      awk '$1 == "deb" || $1 == "deb-src" {
             for (i = 2; i <= NF; i++) if ($i ~ /^https?:/) { print $i; break }
           }' "$f" 2>/dev/null
      ;;
  esac | sed 's#/*$##' | sed '/^$/d'
}

check_apt() {
  section 'apt sources'
  local dir=/etc/apt/sources.list.d f uri
  if [ ! -d "$dir" ]; then
    ok "no $dir on this box"
    section_end
    return 0
  fi

  # The same URI in both a .list and a .sources: apt fetches it twice and warns
  # on every update.
  local listuris='' srcuris='' dupes=0
  for f in "$dir"/*.list; do
    [ -f "$f" ] || continue
    listuris="$listuris$(_apt_uris "$f")"$'\n'
  done
  for f in "$dir"/*.sources; do
    [ -f "$f" ] || continue
    srcuris="$srcuris$(_apt_uris "$f")"$'\n'
  done
  while IFS= read -r uri; do
    [ -n "$uri" ] || continue
    if printf '%s' "$srcuris" | grep -Fxq -- "$uri"; then
      warn "apt: $uri is configured in BOTH a .list and a .sources file"
      plan "remove the legacy .list:  grep -rl '$uri' $dir/*.list"
      dupes=$((dupes + 1))
    fi
  done < <(printf '%s' "$listuris" | sort -u)
  if [ "$dupes" = 0 ]; then ok 'apt: no URI configured twice'; fi

  # add-apt-repository's legacy artefact.
  local legacy=()
  for f in "$dir"/archive_uri-*.list; do
    if [ -f "$f" ]; then legacy+=("$f"); fi
  done
  if [ ${#legacy[@]} -gt 0 ]; then
    warn "apt: legacy archive_uri-*.list left by add-apt-repository: ${legacy[*]}"
    plan "sudo rm ${legacy[*]}"
  else
    ok 'apt: no archive_uri-*.list residue'
  fi

  # The exact bug the old fix-repos.sh patched by hand, generalised: a vendor path
  # that names the other distro.
  local other=debian
  [ "${OS_FLAVOR:-}" = debian ] && other=ubuntu
  local bad=0
  for f in "$dir"/docker.list "$dir"/docker.sources; do
    [ -f "$f" ] || continue
    if grep -q "download.docker.com/linux/$other" "$f" 2>/dev/null; then
      fail "apt: $f points at download.docker.com/linux/$other on a ${OS_FLAVOR:-?} box"
      plan 'devenv --only containers        # rewrites the docker source correctly'
      bad=1
    fi
  done
  if [ "$bad" = 0 ]; then ok 'apt: docker source (if any) matches this distro'; fi

  # A Signed-By keyring that is missing or empty makes the whole suite unusable.
  local keyrings n_missing=0 key
  # `|| keyrings=''` for the same reason as `pinned` below: under `set -o pipefail`
  # a grep that matches nothing fails the assignment and the ERR trap turns "this
  # box pins no keyring" into a doctor crash.
  keyrings=$(grep -rhoE '^[[:space:]]*(Signed-By:[[:space:]]*|.*signed-by=)([^]# ]+)' \
    "$dir" 2>/dev/null | sed -E 's/.*(Signed-By:[[:space:]]*|signed-by=)//' | sort -u) \
    || keyrings=''
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case $key in /*) ;; *) continue ;; esac
    if [ ! -s "$key" ]; then
      fail "apt: keyring $key is missing or empty — that suite cannot be verified"
      plan "devenv --only preflight         # repairs a corrupt keyring in place"
      n_missing=$((n_missing + 1))
    fi
  done <<<"$keyrings"
  if [ "$n_missing" = 0 ]; then ok 'apt: every referenced keyring exists and is non-empty'; fi

  # Kubernetes pinned to a minor that upstream no longer publishes.
  # `|| true` is load-bearing: with `set -o pipefail` a grep that matches nothing
  # fails the whole pipeline, the assignment fails, and the ERR trap turns "this
  # box has no kubernetes apt source" into `doctor failed (exit 1)`. The container
  # matrix caught exactly that on all four images — a fresh box has no such source.
  local pinned
  pinned=$(grep -rhoE 'pkgs\.k8s\.io/core:/stable:/v[0-9]+\.[0-9]+' "$dir" 2>/dev/null \
    | grep -oE 'v[0-9]+\.[0-9]+' | sort -u | head -n1) || pinned=''
  if [ -n "$pinned" ]; then
    if [ "$pinned" = "${K8S_MINOR:-}" ]; then
      ok "apt: kubernetes repo is on $pinned"
    else
      warn "apt: kubernetes repo is pinned to $pinned, this repo targets ${K8S_MINOR:-unset}"
      plan 'devenv --only kubernetes        # rewrites the suite, never downgrades silently'
    fi
  fi
  section_end
}

# ---------------------------------------------------------------------------
# shell
# ---------------------------------------------------------------------------

# _count_matches FILE REGEX — how many lines of FILE match REGEX.
_count_matches() {
  [ -f "$1" ] || {
    printf '0\n'
    return 0
  }
  grep -cE -- "$2" "$1" 2>/dev/null || true
}

check_shell() {
  section 'shell'
  local rc="$HOME/.bashrc" n

  if [ ! -f "$rc" ]; then
    warn "no ~/.bashrc on this box"
    section_end
    return 0
  fi

  # Our own managed block: exactly one, or something went wrong. The count includes
  # a block left under the pre-rename tag — it still sources the same loader, so
  # reporting "no block" for it would send you to re-run a step that then appends a
  # second one.
  n=$(count_blocks_in_file "$rc" '')
  case $n in
    0) warn "shell: ~/.bashrc has no linux-devops-tools block — run: devenv --only shell" ;;
    1) ok 'shell: ~/.bashrc has exactly one linux-devops-tools block' ;;
    *)
      fail "shell: ~/.bashrc has $n linux-devops-tools blocks — the loader runs $n times"
      plan 'edit ~/.bashrc by hand and delete the extra block (never automated)'
      ;;
  esac

  # The severed symlink: mybash owns ~/.bashrc, and a plain file next to a live
  # mybash checkout means an update there will never reach this shell again.
  if [ ! -L "$rc" ] && [ -f "$HOME/linuxtoolbox/mybash/.bashrc" ]; then
    warn "shell: ~/.bashrc is a real file while ~/linuxtoolbox/mybash/.bashrc exists"
    hint 'mybash normally symlinks it; yours was replaced by a copy at some point'
    plan 'devenv --adopt-bashrc            # keeps the hook when mybash re-links it'
  fi

  # Duplicate legacy lines the old repo appended with >>.
  local dup=0
  n=$(_count_matches "$rc" '(^|[[:space:]])[.]?[[:space:]]*"?[$]HOME/[.]cargo/env"?')
  if [ "${n:-0}" -gt 1 ]; then
    warn "shell: ~/.bashrc sources ~/.cargo/env $n times"
    dup=1
  fi
  n=$(_count_matches "$rc" 'PATH=.*[$]HOME/[.]local/bin')
  if [ "${n:-0}" -gt 1 ]; then
    warn "shell: ~/.bashrc prepends ~/.local/bin to PATH $n times"
    dup=1
  fi
  n=$(_count_matches "$rc" '[$]NVM_DIR/nvm[.]sh|NVM_DIR=')
  if [ "${n:-0}" -gt 3 ]; then
    warn "shell: ~/.bashrc has $n nvm lines"
    dup=1
  fi
  if grep -qE '^# Go environment variables' "$rc" 2>/dev/null; then
    warn 'shell: ~/.bashrc still carries the legacy "# Go environment variables" block'
    dup=1
  fi
  if grep -qE "^[[:space:]]*(alias (pbcopy|pbpaste|winclip)=|# export BROWSER=chrome|winpaste\(\))" "$rc" 2>/dev/null; then
    warn 'shell: ~/.bashrc still carries the legacy WSL clipboard block (clip.exe / powershell.exe)'
    hint 'those names do not resolve on this box — the aliases are already dead'
    hint "the replacements are real executables: $HOME/.local/bin/{clip,clip-paste,pbcopy,pbpaste}"
    dup=1
  fi
  if [ -f "$HOME/.use-nala" ] && grep -q 'use-nala' "$rc" 2>/dev/null; then
    warn 'shell: ~/.bashrc sources ~/.use-nala, which redefines sudo() and apt() as SHELL FUNCTIONS'
    hint 'that shim turns every interactive "sudo apt ..." into "sudo nala ..."'
    dup=1
  fi
  if [ "$dup" = 1 ]; then
    plan 'devenv --only migrate             # reports; --apply comments them out with a backup'
  else
    ok 'shell: ~/.bashrc has no known duplicate or legacy lines'
  fi

  # Drop-ins.
  local d="${DEVENV_DROPIN_DIR:-$HOME/.bashrc.d}"
  if [ -d "$d" ]; then
    n=$(find "$d" -maxdepth 1 -name '[0-9][0-9]-*.sh' 2>/dev/null | wc -l)
    ok "shell: ~/.bashrc.d holds $n fragment(s)"
  else
    warn 'no ~/.bashrc.d — run: devenv --only shell'
  fi
  section_end
}

# ---------------------------------------------------------------------------
# PATH and duplicate binaries
# ---------------------------------------------------------------------------

# _path_precedence PATHSTR BIN
#   Prints `local` when BIN appears in PATHSTR before /usr/bin and /bin, `system`
#   when one of those comes first, and nothing when BIN is not in PATHSTR at all.
#   Read-only.
_path_precedence() {
  local pathstr=$1 bin=$2 p first='' parts=()
  IFS=: read -r -a parts <<<"$pathstr"
  for p in "${parts[@]}"; do
    if [ -n "$first" ]; then continue; fi
    case $p in
      "$bin") first=local ;;
      /usr/bin | /bin) first=system ;;
    esac
  done
  printf '%s' "$first"
}

# _next_shell_path
#   Prints the PATH a NEW interactive shell would compute, or nothing when that
#   cannot be established. Returns 1 in the latter case.
#
#   It SOURCES the installed ~/.bashrc.d/10-path.sh in a subshell, starting from
#   this process's PATH — which is what a new shell does too, from the login PATH.
#   Sourcing rather than reading: that fragment is [ -d ]-guarded and de-duplicating,
#   so what it does to a PATH depends on which directories exist and on what is
#   already in the list; grepping it for `.local/bin` would answer a different,
#   easier question. It is the file this repository wrote and every interactive
#   shell already runs; here it runs with its output discarded and only $PATH is
#   read back. `set +eu` because a hand-edited copy must not take doctor with it.
#
#   The answer is only meaningful when ~/.bashrc actually loads the drop-ins, so
#   the caller checks that too — check_shell reports a missing block separately.
_next_shell_path() {
  local f="${DEVENV_DROPIN_DIR:-$HOME/.bashrc.d}/10-path.sh" out=''
  [ -r "$f" ] || return 1
  out=$(
    set +eu
    # shellcheck source=/dev/null
    . "$f" >/dev/null 2>&1
    printf '%s' "$PATH"
  ) || out=''
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# _dropins_are_loaded — true when ~/.bashrc carries the managed block that sources
# ~/.bashrc.d, i.e. when a new interactive shell really will read the fragments.
# One block or several is check_shell's business; here any of them means "loaded".
_dropins_are_loaded() {
  local rc="${DEVENV_BASHRC:-$HOME/.bashrc}"
  [ -f "$rc" ] || return 1
  [ "$(count_blocks_in_file "$rc" '')" -ge 1 ]
}

check_path() {
  section 'PATH'
  local bin="${DEVENV_BIN_DIR:-$HOME/.local/bin}"

  # THIS PROCESS's PATH, and the PATH a new shell would get. They differ during an
  # install run, and the difference is the whole point — see the header.
  local future='' stale=0
  if _dropins_are_loaded; then
    future=$(_next_shell_path) || future=''
  fi

  local live_has=0 future_has=0
  case ":$PATH:" in *":$bin:"*) live_has=1 ;; esac
  case ":$future:" in *":$bin:"*) future_has=1 ;; esac

  if [ "$live_has" = 1 ]; then
    ok "$bin is on PATH"
  elif [ "$future_has" = 1 ]; then
    stale=1
    ok "$bin is on the PATH a new shell gets (~/.bashrc.d/10-path.sh prepends it)"
    hint "not on THIS process's PATH — it predates the drop-in, or never loads it"
    hint 'nothing to repair here — open a new shell, or:  exec bash -l'
  else
    fail "$bin is not on PATH, and no drop-in would put it there"
    plan 'devenv --only shell             # 10-path.sh prepends it'
  fi

  # ~/.local/bin must come BEFORE /usr/bin, or the browser shims never win. Judge
  # the PATH that will actually be used: this process's when it has $bin, the next
  # shell's when only that one does.
  local first=''
  if [ "$live_has" = 1 ]; then
    first=$(_path_precedence "$PATH" "$bin")
  elif [ "$future_has" = 1 ]; then
    first=$(_path_precedence "$future" "$bin")
  fi
  if [ "$first" = system ]; then
    if [ "$stale" = 1 ]; then
      fail "/usr/bin precedes $bin in a new shell too — the xdg-open shim will never be reached"
    else
      fail "/usr/bin precedes $bin on PATH — the xdg-open shim will never be reached"
    fi
    plan 'devenv --only shell               # fixes the order deterministically'
  fi

  # The same command from two package managers is the classic "why is my version
  # old" bug. Report both paths; never remove anything.
  local cmd dupes=0
  local -a paths
  for cmd in golangci-lint fzf jq rg fd bat nvim tree-sitter yq helm kubectl k9s starship opencode; do
    # readlink -f first: /bin is a symlink to /usr/bin on every target, and two
    # names for one inode are not a duplicate installation.
    mapfile -t paths < <(
      { type -aP "$cmd" || true; } 2>/dev/null \
        | while IFS= read -r p; do readlink -f -- "$p" 2>/dev/null || printf '%s\n' "$p"; done \
        | awk 'NF && !seen[$0]++'
    )
    if [ "${#paths[@]}" -gt 1 ]; then
      warn "$cmd resolves to several binaries: ${paths[*]}"
      dupes=$((dupes + 1))
    fi
  done
  if [ "$dupes" = 0 ]; then ok 'no command on PATH is shadowed by a second copy'; fi

  if have picom || have compton; then
    warn 'picom/compton are on PATH on a terminal-only box'
    plan 'devenv --only purge-desktop       # reports first, removes only on confirm'
  fi

  # apt `yq` is kislyuk's python wrapper; mikefarah's is the one every script here
  # assumes. Report, never remove (MUST-FIX S9).
  if have yq && ! yq --version 2>&1 | grep -q mikefarah; then
    if pkg_installed yq; then
      warn 'the apt yq package is installed; this repo assumes mikefarah/yq v4'
      hint 'both can coexist - check "yq --version" before trusting a script'
    fi
  fi
  section_end
}

# ---------------------------------------------------------------------------
# /usr/local ownership
# ---------------------------------------------------------------------------

# check_usr_local
#   /usr/local and the directories every PATH searches must belong to root. tar
#   run as root restores each entry's owner from the archive: every entry of the
#   upstream neovim tarball is uid 1001 (GitHub's `runner`), so until
#   modules/50-editors.sh passed --no-same-owner an install chowned
#   /usr/local/bin, lib and share to uid 1001 — and whoever holds that uid (often
#   the second account made on a box) can replace any binary root runs. A box
#   installed before the fix still has it; this finds it.
#   Reported with the exact repair, never repaired here. A /usr/local owned by YOU
#   is only a warning: some people chown it to themselves on purpose.
check_usr_local() {
  section '/usr/local'
  local d uid me name bad=0 uids=' '
  me=$(id -u)
  for d in /usr/local /usr/local/bin /usr/local/sbin /usr/local/lib /usr/local/share /usr/local/etc; do
    [ -d "$d" ] || continue
    uid=$(stat -c %u -- "$d" 2>/dev/null) || continue
    [ "$uid" != 0 ] || continue
    bad=$((bad + 1))
    case $uids in *" $uid "*) ;; *) uids="$uids$uid " ;; esac
    if [ "$uid" = "$me" ]; then
      warn "$d is owned by you, not root"
    else
      name=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1) || name=''
      fail "$d is owned by uid $uid (${name:-no such user}), not root"
    fi
  done
  if [ "$bad" = 0 ]; then
    ok '/usr/local and the directories under it on PATH belong to root'
  else
    hint 'whoever owns them can replace binaries that root and every other user run'
    for uid in $uids; do
      plan "sudo find /usr/local -xdev -uid $uid -exec chown -h root:root {} +"
    done
  fi
  section_end
}

# ---------------------------------------------------------------------------
# python / node
# ---------------------------------------------------------------------------

check_python() {
  section 'python'
  local m found=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found=1
    fail "PEP 668 marker was renamed: $f"
    hint 'the old installer did this to force pip --user; it disables the distro guard'
    plan "sudo mv '$f' '${f%.old}'         # devenv --only migrate --apply does it for you"
  done < <(find /usr/lib/python3* -maxdepth 1 -name 'EXTERNALLY-MANAGED.old' 2>/dev/null)
  if [ "$found" = 0 ]; then ok 'PEP 668 marker is intact (never moved by this repo)'; fi

  # uv lives in ~/.local/bin, which is exactly the directory a mid-install PATH
  # does not have yet (see the header). `have uv` alone reported "uv is not
  # installed" in the same run that had just installed it, so the filesystem is
  # asked as well before anything is claimed.
  local uvbin="${DEVENV_BIN_DIR:-$HOME/.local/bin}/uv"
  if have uv; then
    ok "uv $(uv --version 2>/dev/null | awk '{print $2}') is installed"
  elif [ -x "$uvbin" ]; then
    ok "uv $("$uvbin" --version 2>/dev/null | awk '{print $2}') is installed at $uvbin"
    hint "it is not on THIS process's PATH — a new shell picks it up (see the PATH section)"
  else
    warn 'uv is not installed - python CLIs belong in "uv tool", never in pip --user'
    plan 'devenv --only lang-python'
  fi
  for m in ansible ansible-lint checkov yamllint detect-secrets; do
    have "$m" || continue
    if [ -x "$HOME/.local/bin/$m" ] && [ ! -L "$HOME/.local/bin/$m" ] \
      && [ ! -d "$HOME/.local/share/uv/tools/${m%%-*}" ]; then
      warn "$m looks like a pip --user install rather than a uv tool"
    fi
  done
  section_end
}

check_node() {
  section 'node'
  if [ -d "$HOME/.nvm" ] && [ -d "$HOME/.config/nvm" ]; then
    warn 'both ~/.nvm and ~/.config/nvm exist — one of them is dead weight'
    hint "your ~/.bashrc sets NVM_DIR; whichever it does not name is unused"
    plan 'move the versions you want to keep by hand, then delete the other directory'
  fi
  if have node; then
    ok "node $(node --version 2>/dev/null)"
  fi
  section_end
}

# ---------------------------------------------------------------------------
# kubernetes
# ---------------------------------------------------------------------------

check_kube_files() {
  section 'kube files (read-only — nothing here is ever deleted)'
  local kd="$HOME/.kube" n mode
  if [ ! -d "$kd" ]; then
    ok 'no ~/.kube on this box'
    section_end
    return 0
  fi
  n=$(find "$kd" -maxdepth 1 -type f 2>/dev/null | wc -l)
  ok "kube: ~/.kube holds $n file(s)"
  n=$(find "$kd" -maxdepth 1 -type f -name '*-base64*' 2>/dev/null | wc -l)
  if [ "$n" -gt 0 ]; then
    warn "kube: ~/.kube holds $n *-base64 file(s) — probably decoded copies of cluster secrets"
    hint 'this repo will never delete them, and offers no command that does'
    hint 'if they are yours to remove, do it by hand after checking each one'
  fi
  if [ -f "$kd/config" ]; then
    mode=$(stat -c '%a' -- "$kd/config" 2>/dev/null || printf '?')
    if [ "$mode" = 600 ] || [ "$mode" = 400 ]; then
      ok "kube: ~/.kube/config is mode $mode"
    else
      warn "kube: ~/.kube/config is mode $mode — it holds cluster credentials"
      plan 'chmod 600 ~/.kube/config'
    fi
  fi
  if [ -n "${KUBECONFIG:-}" ]; then
    case "$KUBECONFIG" in
      *:*) warn "KUBECONFIG lists several files; kubectl writes only to the first one" ;;
      *) ok "KUBECONFIG=$KUBECONFIG" ;;
    esac
  fi
  section_end
}

check_kube_exec() {
  section 'kubeconfig exec / oidc'
  have kubectl || {
    log_skip 'kubectl is not installed'
    section_end
    return 0
  }

  local rows name api mode args bad=0 seen=0
  while IFS=$'\t' read -r name api mode args; do
    [ -n "${name:-}" ] || continue
    [ -n "${api:-}" ] || continue
    seen=$((seen + 1))
    case "$api" in
      *client.authentication.k8s.io/v1)
        if [ -z "${mode:-}" ]; then
          fail "kubeconfig user '$name': exec apiVersion v1 with no interactiveMode"
          hint 'interactiveMode is REQUIRED at v1 — this is silent until it bites'
          plan 'sso-kubeconfig-add --user '"$name"'   # rewrites it as IfAvailable'
          bad=1
        fi
        ;;
    esac
    case "${mode:-}" in
      Never)
        case "$args" in
          *authcode-keyboard* | *--grant-type=password*)
            fail "kubeconfig user '$name': interactiveMode Never with a flow that needs stdin"
            plan 'sso-kubeconfig-add --user '"$name"' --headless'
            bad=1
            ;;
        esac
        ;;
    esac
    case "$args" in
      *--oidc-use-pkce*)
        fail "kubeconfig user '$name': --oidc-use-pkce does not exist any more"
        hint 'the current flag is --oidc-pkce-method (auto|no|S256), default auto'
        plan 'sso-kubeconfig-add --user '"$name"
        bad=1
        ;;
    esac
    case "$args" in
      *--oidc-client-secret*)
        warn "kubeconfig user '$name': a client secret sits in plaintext in the kubeconfig"
        hint 'it is also visible in "ps" on every kubectl call - ask for a public client + PKCE'
        bad=1
        ;;
    esac
    case "$args" in
      *--insecure-skip-tls-verify*)
        warn "kubeconfig user '$name': TLS verification is disabled for the IdP"
        hint 'install the IdP CA and use --certificate-authority=~/.kube/idp-ca.pem instead'
        bad=1
        ;;
    esac
    case "$args" in
      *oidc-login*)
        case "$args" in
          *--listen-address* | *authcode-keyboard*) ;;
          *)
            warn "kubeconfig user '$name': oidc-login with no --listen-address"
            hint 'the port then drifts between 8000 and 18000, and the redirect URL is'
            hint 'part of the token-cache key — you will be asked to log in twice'
            bad=1
            ;;
        esac
        ;;
    esac
  done < <(kubectl config view -o \
    'jsonpath={range .users[*]}{.name}{"\t"}{.user.exec.apiVersion}{"\t"}{.user.exec.interactiveMode}{"\t"}{.user.exec.args}{"\n"}{end}' \
    2>/dev/null)
  rows=$seen
  if [ "$rows" = 0 ]; then
    log_skip 'no kubeconfig users with an exec credential plugin'
  elif [ "$bad" = 0 ]; then
    ok "all $rows exec credential plugin(s) look sane"
  fi

  # Presence is checked on disk, NOT by running `kubectl oidc-login version`:
  # invoking the plugin creates ~/.kube/cache/oidc-login and a lock file, and a
  # read-only audit must leave the filesystem exactly as it found it.
  local krew_bin="${KREW_ROOT:-$HOME/.krew}/bin/kubectl-oidc_login"
  if [ -x "$krew_bin" ] || have kubectl-oidc_login; then
    ok 'kubectl oidc-login (krew) is installed'
  else
    warn 'kubectl oidc-login (krew "oidc-login") is not installed — Keycloak logins need it'
    plan 'devenv --only k8s-plugins'
  fi

  if have kubelogin && ! kubelogin convert-kubeconfig --help >/dev/null 2>&1; then
    fail 'the kubelogin on PATH is int128/kubelogin, not Azure/kubelogin'
    hint 'AKS conversion fails with: unknown command "convert-kubeconfig"'
    plan 'go install github.com/Azure/kubelogin/cmd/kubelogin@latest'
  fi
  section_end
}

check_kube_tools() {
  section 'kubernetes tooling'
  local a b krew_virt="${KREW_ROOT:-$HOME/.krew}/bin/kubectl-virt"
  # --client on BOTH, and the krew binary by path: a version call without --client
  # contacts the cluster, which runs the kubeconfig's exec credential plugin and
  # writes a token-cache lock. Doctor never causes a write.
  if have virtctl && [ -x "$krew_virt" ]; then
    a=$(virtctl version --client 2>/dev/null | head -n1)
    b=$("$krew_virt" version --client 2>/dev/null | head -n1)
    if [ -n "$a" ] && [ "$a" != "$b" ]; then
      warn 'virtctl and the krew virt plugin are different versions'
      hint "virtctl:    $a"
      hint "krew virt:  $b"
      hint 'both are wanted — the k9s plugins call one of them; just keep them in step'
    fi
  fi
  local sg=0
  if have helm && helm plugin list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx schema-gen; then
    warn 'the helm plugin schema-gen is installed; upstream archived it in 2021'
    plan 'helm plugin uninstall schema-gen'
    sg=1
  fi
  if [ "$sg" = 0 ]; then ok 'no archived or skewed kubernetes plugin found'; fi
  section_end
}

check_k9s() {
  section 'k9s config'
  local cfg="${K9S_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/k9s}"
  local shipped="$DEVENV_HOME/config/k9s"
  if ! have k9s; then
    log_skip 'k9s is not installed'
    section_end
    return 0
  fi
  if [ ! -d "$shipped" ]; then
    log_skip 'this checkout ships no k9s payloads'
    section_end
    return 0
  fi
  if [ ! -d "$cfg" ]; then
    warn "no $cfg — the shipped plugins, hotkeys and skins are not installed"
    plan 'devenv --only k9s-config'
    section_end
    return 0
  fi

  # Only plugins/ and skins/ are compared byte for byte: those are the files the
  # k9s-config module owns outright (write_managed). config.yaml is create-once —
  # k9s rewrites it itself — and aliases.yaml/hotkeys.yaml are key-merged, so a
  # difference in any of the three is expected and is NOT a finding.
  local f rel dest n_missing=0 stale=0 local_edit=0
  while IFS= read -r f; do
    rel=${f#"$shipped"/}
    dest="$cfg/$rel"
    if [ ! -f "$dest" ]; then
      n_missing=$((n_missing + 1))
      continue
    fi
    cmp -s -- "$f" "$dest" && continue
    if manifest_owns "$dest"; then
      stale=$((stale + 1))
    else
      local_edit=$((local_edit + 1))
    fi
  done < <(find "$shipped/plugins" "$shipped/skins" -type f -name '*.yaml' 2>/dev/null | sort)

  local m
  for m in config.yaml aliases.yaml hotkeys.yaml; do
    [ -f "$shipped/$m" ] || continue
    if [ ! -f "$cfg/$m" ]; then
      warn "k9s: $cfg/$m is missing"
      plan 'devenv --only k9s-config'
    fi
  done

  if [ "$n_missing" -gt 0 ]; then
    warn "k9s: $n_missing shipped file(s) are not installed"
    plan 'devenv --only k9s-config'
  fi
  if [ "$stale" -gt 0 ]; then
    warn "k9s: $stale installed file(s) are older than the ones this checkout ships"
    plan 'devenv --only k9s-config'
  fi
  if [ "$local_edit" -gt 0 ]; then
    log_info "k9s: $local_edit file(s) differ and were edited outside this repo — left alone"
    hint 'set DEVENV_KEEP_LOCAL=1 to keep them across a k9s-config run'
  fi
  if [ "$n_missing" = 0 ] && [ "$stale" = 0 ]; then
    ok 'k9s: every shipped plugin, hotkey and skin is current'
  fi

  if [ -f "$cfg/config.yaml" ]; then
    if grep -qE '^[[:space:]]{2,}skin:' "$cfg/config.yaml"; then
      ok "k9s: a skin is selected in $cfg/config.yaml"
    else
      warn "k9s: no skin selected in $cfg/config.yaml (k9s rewrites this file itself)"
      plan 'k9s-skin --auto'
    fi
  else
    warn "k9s: no $cfg/config.yaml"
    plan 'devenv --only k9s-config'
  fi
  section_end
}

# ---------------------------------------------------------------------------
# browser shim / sso
# ---------------------------------------------------------------------------

check_sso() {
  section 'browser shim and sso'
  local bin="${DEVENV_BIN_DIR:-$HOME/.local/bin}"
  local lib="${DEVENV_SHIM_LIB_DIR:-$HOME/.local/lib/devops-env}"
  local n n_missing=0 total=0

  for n in open-url clip clip-paste sso-login sso-kubeconfig-add web \
    xdg-open x-www-browser www-browser sensible-browser pbcopy pbpaste; do
    total=$((total + 1))
    if [ ! -x "$bin/$n" ]; then
      n_missing=$((n_missing + 1))
      fail "missing or not executable: $bin/$n"
    fi
  done
  if [ "$n_missing" -gt 0 ]; then
    plan 'devenv --only auth-sso'
  else
    ok 'all browser and clipboard shims are installed'
  fi

  if [ -r "$lib/detect.sh" ]; then
    ok "$lib/detect.sh is present"
  elif [ "$n_missing" -lt "$total" ]; then
    fail "$lib/detect.sh is missing while the shims exist — they degrade to print-only"
    plan 'devenv --only auth-sso'
  fi

  local resolved
  for n in xdg-open x-www-browser www-browser; do
    resolved=$(command -v "$n" 2>/dev/null || true)
    [ -n "$resolved" ] || continue
    case "$resolved" in
      "$bin"/*) ;;
      *)
        warn "$n resolves to $resolved, not $bin/$n"
        hint 'update-alternatives is system-wide; ours is per-user and should win on PATH'
        hint 'on this box the alternative is lynx, which seizes the TTY mid-kubectl'
        ;;
    esac
  done

  if [ -x "$bin/open-url" ]; then
    ok "browser mode here: $("$bin/open-url" --mode 2>/dev/null || printf 'unknown')"
  fi

  # sso.env: present, 0600, and never tracked by a dotfiles repo.
  local envf="$DEVENV_CONFIG/sso.env" mode
  if [ ! -f "$envf" ]; then
    warn "no $envf — the login helpers have nothing to work with"
    plan 'devenv --only auth-sso            # seeds it from the example, once'
  else
    mode=$(stat -c '%a' -- "$envf" 2>/dev/null || printf '?')
    if [ "$mode" = 600 ] || [ "$mode" = 400 ]; then
      ok "$envf is mode $mode"
    else
      fail "$envf is mode $mode — it holds your issuer URL and realm"
      plan "chmod 600 $envf"
    fi
    if have git && git -C "$DEVENV_CONFIG" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      && git -C "$DEVENV_CONFIG" ls-files --error-unmatch sso.env >/dev/null 2>&1; then
      fail "$envf is TRACKED BY GIT — a real issuer URL is about to be published"
      plan "git -C $DEVENV_CONFIG rm --cached sso.env && echo sso.env >> .gitignore"
    fi
  fi

  # File modes on every credential store the login flows write.
  local f
  for f in "$HOME/.docker/config.json" "$HOME/.config/gh/hosts.yml" \
    "$HOME/.config/glab-cli/config.yml" "$HOME/.vault-token" "$HOME/.argocd/config"; do
    [ -f "$f" ] || continue
    mode=$(stat -c '%a' -- "$f" 2>/dev/null || printf '?')
    case $mode in
      600 | 400) ;;
      *)
        warn "$f is mode $mode and holds a credential"
        plan "chmod 600 $f"
        ;;
    esac
  done
  if [ -d "$HOME/.kube/cache/oidc-login" ]; then
    n=$(find "$HOME/.kube/cache/oidc-login" -type f ! -perm 600 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
      warn "$n cached OIDC token file(s) are not mode 600"
      plan 'chmod 600 ~/.kube/cache/oidc-login/*'
    fi
  fi
  section_end
}

# ---------------------------------------------------------------------------
# tmux
# ---------------------------------------------------------------------------

check_tmux() {
  section 'tmux'
  local f="$HOME/.tmux.conf"
  if [ ! -f "$f" ]; then
    log_skip 'no ~/.tmux.conf'
    section_end
    return 0
  fi
  log_info 'this repo never edits ~/.tmux.conf — the findings below are yours to apply'

  if grep -qE '^[[:space:]]*set-environment[[:space:]]+-g[[:space:]]+DISPLAY' "$f"; then
    warn "$f sets DISPLAY unconditionally"
    hint 'inside tmux that makes a headless box look graphical to every tool that'
    hint 'opens a browser; open-url probes for a real socket, but nothing else does'
    plan "delete the 'set-environment -g DISPLAY' line from ~/.tmux.conf"
  else
    ok 'tmux does not fake a DISPLAY'
  fi

  # A BARE `clip.exe` / `powershell.exe` is the bug this looks for: those names do
  # not resolve inside WSL (the Windows PATH is not on the shell's PATH) and cannot
  # exist on a Debian VM at all, so a binding that calls them is already dead.
  #
  # An ABSOLUTE path to one, reached only after probing for it, is the CORRECT
  # portable spelling and must not be reported — Ujstor/tmux-config resolves a
  # Windows root and then calls "$w/Windows/System32/clip.exe", which is right.
  # Hence `[^/]`: a slash immediately before the name disqualifies the match.
  # Comments are stripped first, because that config explains in prose that it
  # contains no bare clip.exe — and the naive pattern matched the explanation.
  if grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[^/])(clip|powershell)\.exe'; then
    warn "$f calls clip.exe / powershell.exe by name"
    hint 'neither name resolves on this box, and neither exists on a Debian VM'
    plan "replace them with 'clip' and 'clip-paste' in ~/.tmux.conf"
  fi

  # The snippet exists for a config that has no clipboard handling of its own.
  # One that already resolves a backend at copy time needs nothing from us, and
  # telling it to source a second, competing binding is worse than saying nothing.
  if grep -Fq 'devops-env/tmux/devenv-clipboard.conf' "$f"; then
    ok 'tmux sources the shipped clipboard snippet'
  elif grep -qE '@clip_copy_command|@override_copy_command|\.local/bin/clip' "$f"; then
    ok 'tmux resolves the clipboard backend itself — the shipped snippet is not needed'
  else
    log_info 'to get portable copy/paste, add this line to ~/.tmux.conf:'
    hint 'source-file ~/.config/devops-env/tmux/devenv-clipboard.conf'
  fi
  section_end
}

# ---------------------------------------------------------------------------
# wsl / docker / git / clock
# ---------------------------------------------------------------------------

check_wsl() {
  os_is_wsl || return 0
  section 'wsl'
  local v
  v=$(wslconf_get interop appendWindowsPath 2>/dev/null || printf '')
  case "$v" in
    false | False | FALSE)
      log_info "/etc/wsl.conf sets [interop] appendWindowsPath = $v"
      hint 'that only removes the Windows PATH; interop itself still works'
      hint 'every Windows call in this repo uses an absolute path, so nothing breaks'
      hint 'this repo will NEVER change that key for you'
      ;;
    *) ok '/etc/wsl.conf does not disable appendWindowsPath' ;;
  esac
  if [ "${HAS_WSL_INTEROP:-0}" = 1 ]; then
    ok 'WSL interop is enabled'
  else
    warn 'WSL interop is disabled — the Windows browser and clipboard are unreachable'
    hint 'open-url falls back to printing the URL, which still works'
  fi
  if ! have wslview; then
    log_info 'wslu (wslview) is not installed; the shim uses absolute-path PowerShell instead'
  fi
  section_end
}

check_docker() {
  have docker || return 0
  section 'docker'
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    ok 'you are in the docker group'
  else
    warn 'you are not in the docker group — every docker call needs sudo'
    hint 'membership is root-equivalent; devenv asks before granting it'
    plan 'devenv --only containers --allow-docker-group'
  fi
  if have ufw && ufw status 2>/dev/null | head -n1 | grep -qi active; then
    warn 'UFW is active while docker is installed'
    hint 'docker publishes ports straight into iptables and bypasses UFW rules'
  fi
  section_end
}

check_git() {
  have git || return 0
  section 'git'
  local v
  v=$(git config --global --get http.sslVerify 2>/dev/null || printf '')
  case "$v" in
    false | 0 | off)
      warn 'git http.sslVerify is FALSE globally — TLS is unverified for github.com too'
      hint 'REPORT ONLY: this repo never changes it, because it is your decision'
      hint 'the scoped replacement is:'
      hint '  git config --global --unset http.sslVerify'
      hint '  git config --global http."https://<your-host>/".sslCAInfo /path/to/ca.crt'
      hint 'install the CA once with: sudo cp ca.crt /usr/local/share/ca-certificates/ &&'
      hint '  sudo update-ca-certificates'
      ;;
    *) ok 'git verifies TLS certificates' ;;
  esac

  if [ "$(git config --global --get commit.gpgsign 2>/dev/null || printf '')" = true ]; then
    local wf
    wf=$({ git config --global --get-regexp '^includeif\.' || true; } 2>/dev/null \
      | awk '{print $2}' | head -n1)
    if [ -n "$wf" ] && [ -f "${wf/#\~/$HOME}" ]; then
      if ! grep -qi 'signingkey' "${wf/#\~/$HOME}" 2>/dev/null; then
        warn "commit.gpgsign is on globally, but $wf sets no signingkey of its own"
        hint 'every commit made under that identity is signed with your PERSONAL key'
        hint 'REPORT ONLY. The fix is yours: set user.useConfigOnly=true and give each'
        hint 'identity file its own [user] signingkey and [commit] gpgsign'
      else
        ok 'the work identity has its own signing key'
      fi
    fi
  fi

  local sd
  while IFS= read -r sd; do
    [ -n "$sd" ] || continue
    [ -d "$sd" ] || warn "git safe.directory points at a path that no longer exists: $sd"
  done < <(git config --global --get-all safe.directory 2>/dev/null || true)
  section_end
}

check_clock() {
  section 'clock'
  # A skewed clock fails every OIDC login with an opaque "token used before issued".
  if have timedatectl && os_has_systemd; then
    local sync
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf '')
    case "$sync" in
      yes) ok "clock is NTP-synchronised ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))" ;;
      no)
        warn 'the clock is not NTP-synchronised — OIDC tokens fail on >30 s of skew'
        plan 'sudo timedatectl set-ntp true          # or: sudo hwclock -s   (WSL, after resume)'
        ;;
      *) log_skip 'timedatectl cannot report NTP state here' ;;
    esac
  else
    log_info "local time is $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
    hint 'compare it against a server yourself (doctor makes no network calls):'
    hint "  curl -sSI https://github.com | grep -i '^date:'"
  fi
  if os_is_wsl; then
    log_info 'WSL clocks drift after the Windows host sleeps; "sudo hwclock -s" fixes it'
  fi
  section_end
}

check_desktop_residue() {
  section 'desktop residue'
  local found=() f p
  for f in /usr/local/bin/picom /usr/local/bin/picom-trans \
    /usr/local/bin/compton /usr/local/bin/compton-trans "$HOME/build/picom"; do
    if [ -e "$f" ]; then found+=("$f"); fi
  done
  for p in brave-browser brave-keyring mpv tigervnc-viewer xtightvncviewer autocutsel; do
    if pkg_installed "$p"; then found+=("$p"); fi
  done
  if [ ${#found[@]} -gt 0 ]; then
    warn "this box still carries the old desktop layer: ${found[*]}"
    hint 'terminal-only is the target; none of it has a consumer here'
    plan 'devenv --only purge-desktop       # reports first, and asks before every removal'
  else
    ok 'no desktop or compositor residue'
  fi
  section_end
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

print_summary() {
  log_step 'doctor: summary'
  log_info "checks: $DOC_OK ok, $DOC_WARN warning(s), $DOC_FAIL failure(s)"
  if [ ${#DOC_PLAN[@]} -gt 0 ]; then
    log_info ''
    log_info "repair plan — ${#DOC_PLAN[@]} command(s). DOCTOR RUNS NONE OF THEM:"
    local c
    for c in "${DOC_PLAN[@]}"; do
      log_info "  $c"
    done
  fi
  if [ "${DEVENV_DOCTOR_FIX:-0}" = 1 ]; then
    log_info ''
    log_warn 'doctor is read-only by design: --fix printed the plan above and changed nothing.'
    log_warn 'Run the commands you agree with. The ones that start with "devenv" are'
    log_warn 'idempotent, take backups, and honour --dry-run.'
  fi
  log_step_end
}

module_main() {
  check_platform
  check_apt
  check_shell
  check_path
  check_usr_local
  check_python
  check_node
  check_kube_files
  check_kube_exec
  check_kube_tools
  check_k9s
  check_sso
  check_tmux
  check_wsl
  check_docker
  check_git
  check_clock
  check_desktop_residue
  print_summary

  if [ "${DEVENV_DOCTOR_STRICT:-0}" = 1 ] && [ "$DOC_FAIL" -gt 0 ]; then
    return 1
  fi
  return 0
}

module_main "$@"
