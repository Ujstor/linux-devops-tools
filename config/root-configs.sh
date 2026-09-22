#!/usr/bin/env bash
# config/root-configs.sh — give root the same config repos the invoking user has.
#
# Run BY modules/12-root-configs.sh, as root, with HOME already pointing at root's
# home (`sudo -H`). It is a standalone script on purpose: it runs in root's
# environment, not the user's, and sourcing lib/common.sh there would drag
# DEVENV_STATE, the manifest and the whole dry-run machinery into a different
# HOME. Nothing in here needs any of that.
#
# It reads the entries to mirror on stdin, one per line, separated by the ASCII
# UNIT SEPARATOR (0x1f):
#
#     name <US> url <US> ref <US> link <US> link_src <US> post
#
# Not a tab, and that is not a style choice. A tab is IFS *whitespace*, so bash
# collapses a run of them into one delimiter and strips them at the ends — which
# silently shifts every field after an empty one. mybash declares no link= and no
# link_src=, so with tabs its post= command landed in `link` and this script tried
# to create a symlink called './setup.sh'. 0x1f is not whitespace, so empty fields
# survive; it also cannot occur in a path, a URL or a shell command.
#
# The list is generated from lib/extrepo.sh by the module, so there is still
# exactly ONE place that knows which repositories these are and where their
# symlinks go: config/external-repos.sh. This script knows none of that.
#
# WHY ROOT AT ALL. `sudo -i`, `sudo su -` and a root login shell all read root's
# dotfiles, not yours. On a box configured only for the user, root gets a bare
# bash prompt, a tmux with no prefix and no plugins, and a vi that is not neovim —
# which is exactly when you are doing something delicate and want your own tools.
#
# WHAT IT WILL NOT DO. dest is always under root's own HOME: this never points
# root's dotfiles at a path in the user's home, which would break the moment that
# home is unmounted, re-created or has its permissions tightened, and would let a
# non-root user edit what root's login shell sources. That last one is the reason
# it is a rule and not a preference.
#
# Idempotent. Re-running fast-forwards each checkout, refuses to touch a dirty
# one, and re-points a symlink only when it is wrong.

set -uo pipefail

# Defence in depth, and it has teeth. Whoever calls this is almost certainly
# sitting in tmux, so their environment carries TMUX and, once TPM has ever run,
# TMUX_PLUGIN_MANAGER_PATH. If either survives into here, the tmux client that
# tmux-config's install.sh starts talks to the CALLER's server and TPM installs
# into the caller's ~/.tmux/plugins instead of root's — it then cheerfully reports
# "Already installed" for every plugin and root is left with TPM and nothing else.
# modules/52-root-configs.sh already strips them; this covers a direct run.
unset TMUX TMUX_PLUGIN_MANAGER_PATH TMUX_TMPDIR

ROOT_HOME=${HOME:-/root}
REPO_ROOT="$ROOT_HOME/.local/share/devops-env/repos"
DRY=${DEVENV_DRY_RUN:-0}
RUN_POST=${DEVENV_EXTREPO_POST:-1}

say() { printf '[ .. ] root: %s\n' "$*" >&2; }
warn() { printf '[ !! ] root: %s\n' "$*" >&2; }
skip() { printf '[ -- ] root: %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || {
  warn "not running as root — nothing done"
  exit 0
}

case $ROOT_HOME in
  /*) ;;
  *)
    warn "HOME is not an absolute path ('$ROOT_HOME') — refusing to guess"
    exit 0
    ;;
esac

# sync_repo URL DIR REF — clone or fast-forward. Never resets a dirty worktree.
sync_repo() {
  local url=$1 dir=$2 ref=$3
  if [ -d "$dir/.git" ]; then
    # GIT_OPTIONAL_LOCKS=0: see lib/fs.sh devenv_sync_repo — status must not rewrite the index.
    if [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      warn "$dir has local modifications — left as it is"
      return 0
    fi
    git -C "$dir" fetch --quiet --depth=1 origin "${ref:-HEAD}" 2>/dev/null || {
      warn "could not reach $url — keeping the checkout at $dir"
      return 0
    }
    git -C "$dir" checkout --quiet --detach FETCH_HEAD 2>/dev/null \
      || warn "could not check out ${ref:-HEAD} in $dir"
    return 0
  fi
  if [ -e "$dir" ]; then
    warn "$dir exists and is not a git checkout — left alone"
    return 1
  fi
  mkdir -p -- "$(dirname -- "$dir")" || return 1
  if [ -n "$ref" ]; then
    git clone --quiet --depth=1 --branch "$ref" "$url" "$dir" 2>/dev/null \
      || git clone --quiet "$url" "$dir" 2>/dev/null \
      || {
        warn "could not clone $url into $dir"
        return 1
      }
  else
    git clone --quiet --depth=1 "$url" "$dir" 2>/dev/null \
      || {
        warn "could not clone $url into $dir"
        return 1
      }
  fi
  return 0
}

# place_link SRC DST — same four cases as lib/extrepo.sh's extrepo_place_link:
# nothing -> link · symlink -> re-point · EMPTY dir -> replace · anything else ->
# leave it and say so. root's own ~/.bashrc counts as "anything else" and is never
# silently replaced here; the post script is what backs it up and adopts it.
place_link() {
  local src=$1 dst=$2
  [ -e "$src" ] || {
    warn "$src is not in the checkout — $dst not linked"
    return 0
  }
  if [ -L "$dst" ]; then
    [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ] && return 0
    ln -sfn -- "$src" "$dst" && say "re-pointed $dst -> $src"
    return 0
  fi
  if [ -d "$dst" ]; then
    if [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
      warn "$dst is a non-empty directory — left alone"
      return 0
    fi
    rmdir -- "$dst" 2>/dev/null || {
      warn "could not remove the empty $dst"
      return 0
    }
  elif [ -e "$dst" ]; then
    warn "$dst is a regular file — left alone, not overwritten"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$dst")" 2>/dev/null
  ln -sfn -- "$src" "$dst" && say "linked $dst -> $src"
  return 0
}

command -v git >/dev/null 2>&1 || {
  warn "git is not installed — nothing done"
  exit 0
}

count=0
while IFS=$'\037' read -r name url ref link link_src post; do
  [ -n "${name:-}" ] || continue
  [ -n "${url:-}" ] || continue
  count=$((count + 1))
  dest="$REPO_ROOT/$name"

  if [ "$DRY" = 1 ]; then
    skip "--dry-run: would sync $name into $dest${link:+ and link $link}"
    continue
  fi

  say "syncing $name"
  sync_repo "$url" "$dest" "${ref:-}" || continue

  if [ -n "${link:-}" ]; then
    # Absolute only. A relative link= would be created against whatever directory
    # this script happens to be run from — which is how an earlier version of the
    # caller, mis-parsing its input, left a symlink called './setup.sh' sitting in
    # the repository checkout. Refuse it here, where the message can name the entry.
    case $link in
      /*)
        src=$dest
        [ -n "${link_src:-}" ] && src="$dest/${link_src#/}"
        place_link "$src" "$link"
        ;;
      *) warn "$name: link '$link' is not an absolute path — not linked" ;;
    esac
  fi

  if [ -n "${post:-}" ] && [ "$RUN_POST" != 0 ]; then
    say "$name: running its own installer ($post)"
    (cd "$dest" && bash -c "$post") \
      || warn "$name: '$post' failed — the checkout and its symlinks are still in place"
  fi
done

[ "$count" -gt 0 ] || skip "no entries were given — nothing to mirror"
exit 0
