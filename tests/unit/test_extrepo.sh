#!/usr/bin/env bash
#
# tests/unit/test_extrepo.sh — lib/extrepo.sh: the external config repo list.
#
# The list is the one place that decides WHICH external checkouts exist, so the
# properties worth pinning down are the ones a module used to hardcode:
#
#   * a bad entry costs that entry and nothing else — never the run,
#   * an entry the user re-declares REPLACES the shipped one, in place,
#   * the DEVENV_EXTREPO_<NAME> switch wins over `enabled=`, in both directions,
#   * a symlink is never placed over a real file or a non-empty directory,
#   * the shipped list really does declare nvim-config, tmux-config and mybash,
#     with mybash off.
#
# No network: nothing here calls devenv_sync_repo. The clone/update half is
# lib/fs.sh's and is covered by tests/unit/test_fs.sh and the container matrix.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

sandbox=$T_SANDBOX

t_section 'the shipped list'

extrepo_reset
DEVENV_CONFIG="$sandbox/.config/devops-env"
export DEVENV_CONFIG
extrepo_load

assert_ok 'nvim-config is declared' extrepo_known nvim-config
assert_ok 'tmux-config is declared' extrepo_known tmux-config
assert_ok 'mybash is declared' extrepo_known mybash

assert_eq 'https://github.com/Ujstor/nvim-config.git' "$(extrepo_get nvim-config url)" \
  'nvim-config points at the right repository'
assert_eq 'editors' "$(extrepo_get nvim-config module)" 'and is owned by the editors module'
assert_eq '' "$(extrepo_get nvim-config link_src)" \
  'nvim-config links the CHECKOUT (init.lua is at the repository root)'
assert_eq "$sandbox/.config/nvim" "$(extrepo_get nvim-config link)" \
  'to ~/.config/nvim'

assert_eq '.tmux.conf' "$(extrepo_get tmux-config link_src)" \
  'tmux-config links the FILE inside the checkout'
assert_eq "$sandbox/.tmux.conf" "$(extrepo_get tmux-config link)" 'to ~/.tmux.conf'

assert_eq 'shell' "$(extrepo_get mybash module)" 'mybash is owned by the shell module'
assert_eq '' "$(extrepo_get mybash link)" \
  'and declares NO symlink — its own setup.sh links all three of its dotfiles'
# Reversed on 2026-09-15 together with the entry: mybash's link_file() backs a real
# ~/.bashrc up before it links, so the data-loss premise behind enabled=0 is gone
# and all three config repos now come from the one curl | bash.
assert_ok 'mybash is ON by default' extrepo_enabled mybash
assert_ok 'as is nvim-config' extrepo_enabled nvim-config
assert_ok 'as is tmux-config' extrepo_enabled tmux-config

# post= — the checkout's own installer, for the part a symlink cannot do.
assert_eq './install.sh' "$(extrepo_get tmux-config post)" \
  'tmux-config finishes its install itself: TPM, the plugins and ~/tmux.sh'
assert_eq './setup.sh --config-only' "$(extrepo_get mybash post)" \
  'and mybash links its own dotfiles — and installs no tool: this repository installs them, pinned'
assert_eq '' "$(extrepo_get nvim-config post)" \
  'nvim-config has none — the symlink really is the whole install'

# The default checkout root, applied to any entry that does not set dest=. Compared
# against $EXTREPO_ROOT and not a literal: XDG_DATA_HOME is honoured, and it is set
# on plenty of real boxes (including this one), so a hardcoded ~/.local/share here
# would be asserting the wrong thing.
assert_eq "$EXTREPO_ROOT/nvim-config" "$(extrepo_get nvim-config dest)" \
  'dest= defaults to the shared checkout root plus the entry name'
assert_contains "$EXTREPO_ROOT" 'devops-env/repos' \
  'and that root is EXTREPO_ROOT, under the XDG data directory'
assert_eq "$HOME/linuxtoolbox/mybash" "$(extrepo_get mybash dest)" \
  'mybash keeps the path mybash itself uses, not the shared root'

t_section 'the switches'

assert_eq 'DEVENV_EXTREPO_NVIM_CONFIG' "$(extrepo_switch nvim-config)" \
  'a dash in the name becomes an underscore in the switch'

# Each switch is read by NAME, through ${!var}, so shellcheck cannot see the use.
# shellcheck disable=SC2034  # read indirectly by extrepo_enabled
DEVENV_EXTREPO_MYBASH=0
assert_fail 'DEVENV_EXTREPO_MYBASH=0 turns a shipped-on entry off' extrepo_enabled mybash
# shellcheck disable=SC2034  # ditto
DEVENV_EXTREPO_MYBASH=1
assert_ok 'and =1 turns it on again' extrepo_enabled mybash
unset DEVENV_EXTREPO_MYBASH

# shellcheck disable=SC2034  # ditto
DEVENV_EXTREPO_NVIM_CONFIG=0
assert_fail 'the switch also turns a shipped-ON entry off' extrepo_enabled nvim-config
unset DEVENV_EXTREPO_NVIM_CONFIG

# The older spelling still has to work: it is what docs/configuration.md has
# documented, and it is now nothing but the default of mybash's enabled= field.
extrepo_reset
DEVENV_INSTALL_MYBASH=1 extrepo_load
assert_ok 'DEVENV_INSTALL_MYBASH=1 still enables mybash' extrepo_enabled mybash
unset DEVENV_INSTALL_MYBASH

t_section 'the user list extends and replaces'

extrepo_reset
mkdir -p "$DEVENV_CONFIG"
cat >"$DEVENV_CONFIG/external-repos.sh" <<EOF
extrepo nvim-config url=https://github.com/someone-else/nvim.git ref=main
extrepo my-thing url=https://github.com/someone-else/thing.git dest=$sandbox/thing
EOF
extrepo_load

assert_eq 'https://github.com/someone-else/nvim.git' "$(extrepo_get nvim-config url)" \
  'a user entry with a shipped name replaces it'
assert_eq 'editors' "$(extrepo_get nvim-config module)" \
  'and a field it did not restate falls back to the default, not to the shipped value'
assert_ok 'a brand new user entry is added' extrepo_known my-thing
assert_eq "$sandbox/thing" "$(extrepo_get my-thing dest)" 'with its own dest'
# Replacing must not move an entry: declaration order is sync order.
assert_eq 'nvim-config' "$(extrepo_names | head -n1)" \
  'a replaced entry keeps its position in the list'
assert_eq 'my-thing' "$(extrepo_names | tail -n1)" 'and a new one lands at the end'
assert_eq 'mybash' "$(extrepo_names shell)" 'extrepo_names filters by module'

t_section 'a bad entry costs that entry and nothing else'

extrepo_reset
cat >"$DEVENV_CONFIG/external-repos.sh" <<'EOF'
extrepo no-url-here desc='has no url at all'
extrepo bad-url url=github.com/Ujstor/nvim-config.git
extrepo 'has a space' url=https://github.com/Ujstor/x.git
extrepo relative-dest url=https://github.com/Ujstor/x.git dest=some/where
extrepo relative-link url=https://github.com/Ujstor/x.git link=.tmux.conf
extrepo fine url=https://github.com/Ujstor/fine.git
EOF
extrepo_load 2>/dev/null

assert_fail 'an entry with no url is refused' extrepo_known no-url-here
assert_fail 'an entry whose url has no scheme is refused' extrepo_known bad-url
# Relative paths would resolve against whatever directory the run started in —
# which for a `curl | bash` install is wherever the user happened to be standing.
assert_fail 'a relative dest= is refused' extrepo_known relative-dest
assert_fail 'a relative link= is refused' extrepo_known relative-link
assert_ok 'and the valid entry after them is still declared' extrepo_known fine

# A file that does not parse must not take the run with it.
extrepo_reset
printf 'extrepo broken url=https://example.com/x.git\nif then fi(\n' \
  >"$DEVENV_CONFIG/external-repos.sh"
assert_ok 'a user list with a syntax error does not abort' extrepo_load
rm -f "$DEVENV_CONFIG/external-repos.sh"

t_section 'extrepo_place_link'

extrepo_reset
checkout="$sandbox/checkout"
mkdir -p "$checkout"
printf 'set -g mouse on\n' >"$checkout/.tmux.conf"

# 1. nothing at the destination -> the link is made.
extrepo linked url=https://example.com/x.git dest="$checkout" \
  link="$sandbox/linked.conf" link_src=.tmux.conf
extrepo_place_link linked
assert_symlink "$sandbox/linked.conf" 'a symlink is created where nothing was'
assert_eq "$checkout/.tmux.conf" "$(readlink -f "$sandbox/linked.conf")" \
  'pointing at link_src inside the checkout'

# 2. an existing symlink -> re-pointed, not duplicated.
ln -sfn "$sandbox/somewhere-else" "$sandbox/relink.conf"
extrepo relink url=https://example.com/x.git dest="$checkout" \
  link="$sandbox/relink.conf" link_src=.tmux.conf
extrepo_place_link relink
assert_eq "$checkout/.tmux.conf" "$(readlink -f "$sandbox/relink.conf")" \
  'an existing symlink is re-pointed'

# 3. a real file of the user's -> LEFT ALONE. This is the ~/.tmux.conf case that
#    the hand-patched file on the live box proved has to hold.
printf 'MINE, hand-patched\n' >"$sandbox/mine.conf"
extrepo keepfile url=https://example.com/x.git dest="$checkout" \
  link="$sandbox/mine.conf" link_src=.tmux.conf
extrepo_place_link keepfile
assert_eq 'MINE, hand-patched' "$(cat "$sandbox/mine.conf")" \
  'a regular file of yours is not replaced by the symlink'
if [ -L "$sandbox/mine.conf" ]; then
  t_not_ok 'a regular file of yours must not become a symlink'
else
  t_ok 'and is still a regular file'
fi

# 4. a non-empty directory -> left alone; an empty one -> replaced. Both are the
#    ~/.config/nvim case, which is a DIRECTORY and which symlink_file alone
#    cannot back up.
mkdir -p "$sandbox/full-dir"
printf 'my own config\n' >"$sandbox/full-dir/init.lua"
extrepo keepdir url=https://example.com/x.git dest="$checkout" link="$sandbox/full-dir"
extrepo_place_link keepdir
assert_file "$sandbox/full-dir/init.lua" 'a non-empty directory of yours is left alone'

mkdir -p "$sandbox/empty-dir"
extrepo takedir url=https://example.com/x.git dest="$checkout" link="$sandbox/empty-dir"
extrepo_place_link takedir
assert_symlink "$sandbox/empty-dir" 'an EMPTY directory is removed and linked'

# 5. no checkout, or a link_src that is not in it -> warn, change nothing.
extrepo nocheckout url=https://example.com/x.git dest="$sandbox/not-cloned" \
  link="$sandbox/nocheckout.conf"
extrepo_place_link nocheckout
assert_no_file "$sandbox/nocheckout.conf" 'no checkout means no symlink'

extrepo nosrc url=https://example.com/x.git dest="$checkout" \
  link="$sandbox/nosrc.conf" link_src=absent-from-the-repo
extrepo_place_link nosrc
assert_no_file "$sandbox/nosrc.conf" 'a link_src that is not in the checkout means no symlink'

t_section '--dry-run changes nothing'

extrepo_reset
mkdir -p "$sandbox/dry-empty"
extrepo dry url=https://example.com/x.git dest="$checkout" link="$sandbox/dry-empty"
DEVENV_DRY_RUN=1 extrepo_place_link dry
DEVENV_DRY_RUN=0
if [ -L "$sandbox/dry-empty" ]; then
  t_not_ok 'a dry run must not create the symlink'
else
  t_ok 'a dry run leaves the empty directory alone'
fi

t_section 'a disabled entry is skipped, not synced'

extrepo_reset
extrepo off url=https://example.com/never-reached.git dest="$sandbox/never" enabled=0
extrepo_sync off
assert_no_file "$sandbox/never" 'extrepo_sync does nothing for a disabled entry'
assert_ok 'and syncing a name that does not exist is not an error' extrepo_sync no-such-entry

t_section 'post= runs each checkout own installer'

# The post command is run with `bash -c` FROM the checkout, so a relative
# `./install.sh` means the one in the checkout. Proved by having it write a file
# into $PWD and checking where that file landed.
extrepo_reset
printf '#!/bin/sh\nprintf ran > ./post-ran\n' >"$checkout/installer.sh"
chmod +x "$checkout/installer.sh"

extrepo withpost url=https://example.com/x.git dest="$checkout" post='./installer.sh'
extrepo_run_post withpost
assert_file "$checkout/post-ran" 'post= runs, with the checkout as the working directory'
rm -f "$checkout/post-ran"

# Never fatal. A post script that fails must warn and let the run carry on, the
# same as an unreachable repository — the checkout and its symlinks are already
# in place and are still worth having.
extrepo failpost url=https://example.com/x.git dest="$checkout" post='exit 3'
assert_ok 'a post= that exits non-zero is a warning, not a failure' extrepo_run_post failpost

# Skipped under --dry-run: a post command is somebody else's script and this
# repository cannot promise what it would write.
DEVENV_DRY_RUN=1 extrepo_run_post withpost
DEVENV_DRY_RUN=0
assert_no_file "$checkout/post-ran" '--dry-run does not run it'

# ... and turned off wholesale by the switch.
DEVENV_EXTREPO_POST=0 extrepo_run_post withpost
assert_no_file "$checkout/post-ran" 'DEVENV_EXTREPO_POST=0 does not run it'

# No checkout means no post: a GitHub outage earlier in the sync must not leave a
# stale installer running against a directory that was never updated.
extrepo nodest url=https://example.com/x.git dest="$sandbox/not-there" post='./installer.sh'
assert_ok 'a missing checkout skips its post=' extrepo_run_post nodest

# An entry with no post= at all is a silent no-op.
extrepo nopost url=https://example.com/x.git dest="$checkout"
assert_ok 'an entry without post= is a no-op' extrepo_run_post nopost

t_summary
