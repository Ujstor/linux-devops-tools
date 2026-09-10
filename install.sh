#!/usr/bin/env bash
# install.sh — the linux-devops-tools bootstrapper.
#
# This is the ONLY file in the repository whose URL is a public contract:
#
#     curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash
#
# It must therefore stay small, stable and self-contained. It SOURCES NOTHING from
# lib/ — it runs before the checkout exists — and it does exactly four things:
#
#   1. work out where the checkout is (or should be),
#   2. put it there (git clone/fast-forward, or a tarball when git is absent),
#   3. reattach stdin to the terminal so prompts work under `curl … | bash`,
#   4. exec bin/devenv with every argument it did not consume itself.
#
# Everything else — profiles, modules, dry-run, doctor, uninstall — belongs to
# bin/devenv. Run `devenv --help` for that.
#
# The three invocations that must all work, and are all tested:
#     curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash
#     cat install.sh | bash -s -- --dry-run
#     ./install.sh --profile devops            # from a local checkout: no clone, no network
#
# MUST-FIX S1. Under `bash -s` the BASH_SOURCE array is EMPTY, so `${BASH_SOURCE[0]}`
# under `set -u` is a fatal "unbound variable" before the first useful line ever runs.
# Every reference below is written `${BASH_SOURCE[0]:-}`. stdin is reattached to the
# controlling terminal only in the same statement that execs bin/devenv, because a
# piped script is READ from stdin: redirecting fd 0 any earlier truncates this file
# mid-run.
#
# MUST-FIX S7. Nothing here ever `rm -rf`s or `mv`s over a directory that is not
# provably ours. A destination is only touched when it is an absolute path with at
# least two components, is not `/`, `$HOME` or a system root, is a real directory
# rather than a symlink, is owned by the invoking user, and either does not exist or
# carries this repository's marker files. Anything else is refused, loudly.
#
# Style: every fetch uses `curl -f --proto '=https' --tlsv1.2 --retry 3`. `-f` is
# mandatory — the repository this one replaces piped 404 HTML pages into bash.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (every value overridable from the environment)
# ---------------------------------------------------------------------------

DEVENV_REPO=${DEVENV_REPO:-Ujstor/linux-devops-tools}
DEVENV_REF=${DEVENV_REF:-main}
# Overridable so a fork, a mirror or an offline test can be used without patching
# this file. It must be a git URL git itself understands.
DEVENV_REPO_URL=${DEVENV_REPO_URL:-https://github.com/$DEVENV_REPO.git}
DEVENV_HOME_DEFAULT="${XDG_DATA_HOME:-$HOME/.local/share}/linux-devops-tools"

# Was DEVENV_HOME chosen by the caller, or are we falling back to the default?
# It decides whether being launched from inside some other checkout wins.
if [ -n "${DEVENV_HOME:-}" ]; then
  _home_explicit=1
else
  _home_explicit=0
  DEVENV_HOME=$DEVENV_HOME_DEFAULT
fi

_no_update=0
_force_update=0
_dry_run=0
_tmpdir=''

# ---------------------------------------------------------------------------
# Output — stderr only, so a caller may still pipe something useful on stdout
# ---------------------------------------------------------------------------

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${DEVENV_NO_COLOR:-0}" != 1 ]; then
  _c_reset=$'\033[0m' _c_blue=$'\033[34m' _c_yellow=$'\033[33m' _c_red=$'\033[31m'
else
  _c_reset='' _c_blue='' _c_yellow='' _c_red=''
fi

say() { printf '%s[ .. ]%s %s\n' "$_c_blue" "$_c_reset" "$*" >&2; }
warn() { printf '%s[ !! ]%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
err() { printf '%s[ xx ]%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die() {
  err "$@"
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  # Only ever removes the scratch directory this process created with mktemp.
  [ -n "$_tmpdir" ] || return 0
  [ -d "$_tmpdir" ] || return 0
  [ -L "$_tmpdir" ] && return 0
  case $_tmpdir in
    */.devenv-bootstrap.*) rm -rf -- "$_tmpdir" ;;
  esac
  return 0
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
linux-devops-tools bootstrapper

  curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash
  ./install.sh [BOOTSTRAP OPTIONS] [DEVENV OPTIONS] [COMMAND]

It clones (or fast-forwards) the repository into ~/.local/share/linux-devops-tools
and hands over to bin/devenv. Run from inside a checkout it clones nothing at all.

Bootstrap options (consumed here):
      --home DIR        where the checkout lives   (env DEVENV_HOME)
      --repo OWNER/NAME which repository to clone  (env DEVENV_REPO)
  -h, --help            this text; nothing is downloaded, nothing is changed

Bootstrap options (also passed on to devenv):
      --ref REF         branch, tag or commit to install   (env DEVENV_REF, default main)
      --no-update       do not fast-forward an existing checkout
      --force-update    fast-forward even when the checkout has local modifications
  -n, --dry-run         print what would happen and change nothing

Everything else is forwarded verbatim to bin/devenv, for example:

  ./install.sh                         # the default 'devops' profile
  ./install.sh --profile minimal       # a smaller set
  ./install.sh --dry-run               # a plan, no changes
  ./install.sh --only k9s-config       # one module
  ./install.sh list                    # every module and its gates
  ./install.sh doctor                  # audit an existing box

The full option and command list, once the checkout exists:

  ~/.local/share/linux-devops-tools/bin/devenv --help

Environment:
  DEVENV_HOME        checkout location      (default ~/.local/share/linux-devops-tools)
  DEVENV_REPO        owner/name to clone    (default Ujstor/linux-devops-tools)
  DEVENV_REPO_URL    full git URL to clone  (default https://github.com/$DEVENV_REPO.git)
  DEVENV_REF         git ref to install     (default main)
  DEVENV_ALLOW_ROOT  set to 1 to allow running as root
EOF
}

# ---------------------------------------------------------------------------
# Safety (MUST-FIX S7)
# ---------------------------------------------------------------------------

# is_checkout DIR
#   Returns 0 when DIR carries this repository's marker files. Three of them, all
#   certain to exist in every version of this repo and in no other: they are what
#   licenses the bootstrapper to write into DIR.
#   `modules/` is deliberately NOT part of the marker — a checkout with an empty
#   modules directory is a valid, if useless, checkout, and must still be updatable.
is_checkout() {
  local d=${1:-}
  [ -n "$d" ] || return 1
  [ -f "$d/lib/common.sh" ] && [ -f "$d/bin/devenv" ] && [ -f "$d/versions.env" ]
}

# assert_sane_path DIR WHAT
#   Refuses paths that must never be a destination: relative paths, `/`, `$HOME`
#   itself, a bare system directory, or anything with fewer than two components.
#   Dies on refusal; returns 0 otherwise.
assert_sane_path() {
  local d=${1:-} what=${2:-path} trimmed
  [ -n "$d" ] || die "$what is empty"
  case $d in
    /*) ;;
    *) die "$what must be an absolute path, got: $d" ;;
  esac
  trimmed=${d%/}
  case $trimmed in
    '' | / | "${HOME%/}") die "$what refuses to be '$d' — that is / or your home directory" ;;
    /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /libx32 | /media | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
      die "$what refuses to be the system directory '$d'"
      ;;
  esac
  case ${trimmed#/} in
    */*) ;;
    *) die "$what refuses '$d' — a top-level directory is too dangerous to manage" ;;
  esac
  return 0
}

# assert_writable_dest DIR
#   The gate in front of every mv into, or rm of, the checkout directory.
#   DIR must be sane, must not be a symlink, and — when it already exists — must be
#   a directory owned by the invoking user that carries the marker files.
assert_writable_dest() {
  local d=${1:-}
  assert_sane_path "$d" 'the checkout directory'
  if [ -L "$d" ]; then
    die "$d is a symlink; refusing to manage it. Remove it yourself or pass --home elsewhere."
  fi
  [ -e "$d" ] || return 0
  [ -d "$d" ] || die "$d exists and is not a directory. Move it aside or pass --home elsewhere."
  [ -O "$d" ] || die "$d is not owned by $(id -un). Refusing to touch it."
  is_checkout "$d" && return 0
  err "$d already exists but does not look like a linux-devops-tools checkout."
  err "It is missing one of lib/common.sh, bin/devenv, versions.env."
  err "Nothing was changed. Move that directory aside, or install elsewhere:"
  err "    ./install.sh --home \"\$HOME/.local/share/linux-devops-tools-new\""
  exit 1
}

# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

curl_get() {
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --max-time 300 "$@"
}

make_tmpdir() {
  local parent=$1
  mkdir -p -- "$parent" || die "cannot create $parent"
  _tmpdir=$(mktemp -d "$parent/.devenv-bootstrap.XXXXXXXX") \
    || die "cannot create a temporary directory in $parent"
}

# fetch_git DEST — a fresh shallow clone, staged in a temp dir and moved into place.
fetch_git() {
  local dest=$1 parent
  parent=$(dirname -- "$dest")
  make_tmpdir "$parent"
  say "cloning $DEVENV_REPO ($DEVENV_REF) into $dest"
  git clone --depth=1 --branch "$DEVENV_REF" --quiet \
    "$DEVENV_REPO_URL" "$_tmpdir/repo" \
    || die "git clone of $DEVENV_REPO_URL ($DEVENV_REF) failed"
  is_checkout "$_tmpdir/repo" || die "the clone of $DEVENV_REPO does not look like this repository"
  mv -- "$_tmpdir/repo" "$dest" || die "cannot move the clone into $dest"
  cleanup
}

# fetch_tarball DEST — the no-git path. codeload accepts a branch, tag or commit.
fetch_tarball() {
  local dest=$1 parent url
  parent=$(dirname -- "$dest")
  url="https://codeload.github.com/$DEVENV_REPO/tar.gz/$DEVENV_REF"
  make_tmpdir "$parent"
  mkdir -p -- "$_tmpdir/repo"
  say "git is not installed — fetching a tarball of $DEVENV_REPO ($DEVENV_REF)"
  have curl || die "neither git nor curl is available; install one of them and re-run"
  have tar || die "tar is not available; install it and re-run"
  curl_get -- "$url" | tar -xz --strip-components=1 -C "$_tmpdir/repo" \
    || die "could not download $url"
  is_checkout "$_tmpdir/repo" || die "the tarball of $DEVENV_REPO does not look like this repository"
  # Marks the checkout as having no git history, so `devenv update` re-downloads
  # instead of trying to fast-forward a repository that is not there.
  : >"$_tmpdir/repo/.tarball-install"
  mv -- "$_tmpdir/repo" "$dest" || die "cannot move the download into $dest"
  cleanup
}

# update_git DEST — fast-forward an existing clone to $DEVENV_REF.
#   A dirty worktree is NEVER reset: it is reported and left alone unless
#   --force-update was given, and even then only tracked files are restored.
update_git() {
  local dest=$1 before after
  if [ "$_no_update" = 1 ]; then
    say "--no-update: keeping the checkout in $dest as it is"
    return 0
  fi
  if [ "$_dry_run" = 1 ]; then
    say "--dry-run: not updating the checkout in $dest"
    return 0
  fi
  if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
    if [ "$_force_update" != 1 ]; then
      warn "$dest has local modifications — running them as they are."
      warn "Pass --force-update to overwrite them with $DEVENV_REF."
      return 0
    fi
    warn "--force-update: discarding local modifications to tracked files in $dest"
  fi
  before=$(git -C "$dest" rev-parse HEAD 2>/dev/null || printf 'unknown')
  if ! git -C "$dest" fetch --depth=1 --quiet origin "$DEVENV_REF" 2>/dev/null; then
    warn "could not reach the remote — running the checkout you already have"
    return 0
  fi
  if [ "$_force_update" = 1 ]; then
    git -C "$dest" checkout --quiet --force --detach FETCH_HEAD || {
      warn "could not check out $DEVENV_REF — running the checkout you already have"
      return 0
    }
  else
    git -C "$dest" checkout --quiet --detach FETCH_HEAD || {
      warn "could not check out $DEVENV_REF — running the checkout you already have"
      return 0
    }
  fi
  after=$(git -C "$dest" rev-parse HEAD 2>/dev/null || printf 'unknown')
  if [ "$before" != "$after" ]; then
    say "updated $dest: ${before:0:12} -> ${after:0:12}"
  fi
  return 0
}

# ensure_checkout — leaves a usable checkout at $DEVENV_HOME, or dies trying.
ensure_checkout() {
  assert_writable_dest "$DEVENV_HOME"
  if is_checkout "$DEVENV_HOME"; then
    if [ -d "$DEVENV_HOME/.git" ] && have git; then
      update_git "$DEVENV_HOME"
    elif [ -f "$DEVENV_HOME/.tarball-install" ]; then
      say "$DEVENV_HOME came from a tarball; refresh it with: devenv update"
    else
      say "using the checkout already in $DEVENV_HOME"
    fi
    return 0
  fi
  if [ "$_dry_run" = 1 ]; then
    warn "--dry-run still needs the repository itself: fetching it into $DEVENV_HOME."
    warn "Nothing outside that directory will be changed."
  fi
  if have git; then
    fetch_git "$DEVENV_HOME"
  else
    fetch_tarball "$DEVENV_HOME"
  fi
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
#
# Three classes:
#   consumed  --home, --repo, -h/--help        (bin/devenv does not know them)
#   peeked    --ref, --no-update, --force-update, --dry-run/-n
#             (this script needs their values AND bin/devenv understands them,
#              so they stay in "$@")
#   forwarded everything else, verbatim, including the command word.
parse_args() {
  local -a keep=()
  local want_home=0 want_repo=0 want_ref=0 a

  for a in "$@"; do
    if [ "$want_home" = 1 ]; then
      DEVENV_HOME=$a
      _home_explicit=1
      want_home=0
      continue
    fi
    if [ "$want_repo" = 1 ]; then
      DEVENV_REPO=$a
      want_repo=0
      continue
    fi
    if [ "$want_ref" = 1 ]; then
      DEVENV_REF=$a
      want_ref=0
      keep+=("$a")
      continue
    fi
    case $a in
      -h | --help)
        usage
        exit 0
        ;;
      --home)
        want_home=1
        ;;
      --home=*)
        DEVENV_HOME=${a#--home=}
        _home_explicit=1
        ;;
      --repo)
        want_repo=1
        ;;
      --repo=*)
        DEVENV_REPO=${a#--repo=}
        ;;
      --ref)
        want_ref=1
        keep+=("$a")
        ;;
      --ref=*)
        DEVENV_REF=${a#--ref=}
        keep+=("$a")
        ;;
      --no-update)
        _no_update=1
        keep+=("$a")
        ;;
      --force-update)
        _force_update=1
        keep+=("$a")
        ;;
      -n | --dry-run)
        _dry_run=1
        keep+=("$a")
        ;;
      *)
        keep+=("$a")
        ;;
    esac
  done

  [ "$want_home" = 0 ] || die "--home needs a directory"
  [ "$want_repo" = 0 ] || die "--repo needs an OWNER/NAME"
  [ "$want_ref" = 0 ] || die "--ref needs a git ref"

  DEVENV_ARGS=()
  [ ${#keep[@]} -gt 0 ] && DEVENV_ARGS=("${keep[@]}")
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
#
# Everything above is a function, so bash has this whole file parsed before any of
# it runs. That matters twice: a piped script must not be re-read after stdin is
# redirected, and a git checkout may replace this very file while it executes.
main() {
  local self here

  if [ "${DEVENV_BOOTSTRAPPED:-0}" = 1 ]; then
    err "install.sh was re-entered, which means $DEVENV_HOME/bin/devenv did not start."
    err "Check that it exists and is executable, then run it directly."
    exit 1
  fi

  parse_args "$@"

  if [ "$(id -u)" -eq 0 ] && [ "${DEVENV_ALLOW_ROOT:-0}" != 1 ]; then
    err "run this as a regular user, not root — the whole point is your dotfiles."
    err "Modules that need root ask for it themselves, once, when they run."
    err "If this box genuinely has no non-root user, re-run with DEVENV_ALLOW_ROOT=1."
    exit 1
  fi

  # Launched from inside a checkout? Then there is nothing to fetch: run it.
  # `${BASH_SOURCE[0]:-}` — under `curl … | bash` the array is EMPTY and a bare
  # subscript would be a fatal `set -u` error (MUST-FIX S1).
  self=${BASH_SOURCE[0]:-}
  if [ -n "$self" ] && [ -f "$self" ]; then
    here=$(CDPATH='' cd -- "$(dirname -- "$self")" && pwd -P) || here=''
    if [ -n "$here" ] && is_checkout "$here"; then
      if [ "$_home_explicit" = 0 ] || [ "${DEVENV_HOME%/}" = "$here" ]; then
        DEVENV_HOME=$here
        say "running from the checkout in $here"
      else
        say "ignoring the checkout in $here — DEVENV_HOME says $DEVENV_HOME"
        ensure_checkout
      fi
    else
      ensure_checkout
    fi
  else
    ensure_checkout
  fi

  export DEVENV_HOME DEVENV_REPO DEVENV_REF DEVENV_REPO_URL
  export DEVENV_BOOTSTRAPPED=1

  [ -f "$DEVENV_HOME/bin/devenv" ] || die "$DEVENV_HOME/bin/devenv is missing"
  if [ ! -x "$DEVENV_HOME/bin/devenv" ]; then
    chmod +x "$DEVENV_HOME/bin/devenv" 2>/dev/null || true
  fi

  # Hand over. stdin is repaired IN THE SAME STATEMENT as the exec, never before:
  # this script may be the pipe that bash is still reading from, and redirecting
  # fd 0 any earlier would truncate it. `[ -t 0 ]` already true means the caller
  # gave us a terminal; otherwise borrow /dev/tty when one exists (so `curl … |
  # bash` can still prompt), and fall back to /dev/null when it does not (cron,
  # CI, a container without a tty) so no prompt can ever block forever.
  if [ -t 0 ]; then
    exec "$DEVENV_HOME/bin/devenv" ${DEVENV_ARGS+"${DEVENV_ARGS[@]}"}
  elif { : >/dev/tty; } 2>/dev/null && { [ -t 1 ] || [ -t 2 ]; }; then
    exec 0</dev/tty "$DEVENV_HOME/bin/devenv" ${DEVENV_ARGS+"${DEVENV_ARGS[@]}"}
  else
    exec 0</dev/null "$DEVENV_HOME/bin/devenv" ${DEVENV_ARGS+"${DEVENV_ARGS[@]}"}
  fi
}

main "$@"
