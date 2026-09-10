# shellcheck shell=bash
# lib/os.sh — distro / platform / architecture detection.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
#
# MUST-FIX C8: /etc/os-release is NEVER sourced. It is parsed line by line so that
# NAME, VERSION, ID, LOGO, HOME_URL … can never leak into the caller's shell.
#
# `os_detect` runs once at source time and exports the variable contract below.
# It is re-runnable: point OS_RELEASE_FILE at a fixture and call it again
# (that is how tests/unit/test_os_detect.sh works).

[ -n "${_DEVENV_OS:-}" ] && return 0
_DEVENV_OS=1

# ---------------------------------------------------------------------------
# THE VARIABLE CONTRACT — the only OS facts a module may rely on.
#
#   OS_ID                 /etc/os-release ID           debian | ubuntu | linuxmint | …
#   OS_ID_LIKE            /etc/os-release ID_LIKE      "debian" | "ubuntu debian" | ""
#   OS_FAMILY             always "debian" on a supported box (else "")
#   OS_FLAVOR             debian | ubuntu — which vendor archive layout to use
#   OS_CODENAME           the distro's OWN codename    bookworm | noble | faye | ""
#   OS_UPSTREAM_CODENAME  the Debian/Ubuntu codename third-party repos publish for.
#                         EMPTY on Debian sid/testing and on an unmappable derivative;
#                         every repo helper then takes its documented fallback branch.
#   OS_VERSION_ID         12 | 24.04 | ""
#   OS_VERSION_MAJOR      12 | 24 | ""
#   OS_PRETTY             PRETTY_NAME
#   OS_LIBC               glibc version, e.g. 2.39 ("" if it cannot be read)
#   OS_ARCH_DPKG          amd64 arm64 armhf i386 ppc64el riscv64 s390x   (source of truth)
#   OS_ARCH_UNAME         x86_64 aarch64 armv7l i686 ppc64le riscv64 s390x
#   OS_ARCH_GO            amd64 arm64 arm 386 ppc64le riscv64 s390x
#   OS_ARCH_RUST          x86_64 aarch64 armv7 i686 powerpc64le riscv64gc s390x
#   IS_WSL                0|1        WSL_VERSION       1|2|""      HAS_WSLG   0|1
#   HAS_WSL_INTEROP       0|1        IS_CONTAINER      0|1
#   HAS_SYSTEMD           0|1        INIT_SYSTEM       systemd|sysv|unknown
#   IS_HEADLESS           0|1        (no usable graphical session — see _os_detect_headless)
#
# ARCHITECTURE SUPPORT (MUST-FIX P7). The mapping below is complete and correct for
# every Debian architecture, and `require_arch` exists so a module can gate on it.
# Only **amd64 / x86_64 is tested**. arm64 is best-effort: where an upstream publishes
# no arm64 asset, gh_release_install returns 78 and the module logs a skip — it never
# silently installs nothing. Nothing else is claimed.
# ---------------------------------------------------------------------------

# have CMD
#   Args: a command name. Returns 0 when it resolves on PATH, 1 otherwise.
#   Silent. Never dies. Safe inside `if`.
have() { command -v "$1" >/dev/null 2>&1; }

# os_release_get KEY
#   Args: an os-release key (ID, VERSION_CODENAME, …).
#   Prints the unquoted value on stdout; returns 1 when the key or the file is absent.
#   Reads ${OS_RELEASE_FILE:-/etc/os-release}. NEVER sources it (MUST-FIX C8).
#   Dry-run: read-only, always runs.
os_release_get() {
  local key=${1:?os_release_get: KEY required}
  local file=${OS_RELEASE_FILE:-/etc/os-release}
  local line val
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "$key"=*) ;;
      *) continue ;;
    esac
    val=${line#*=}
    case $val in
      '"'*'"')
        val=${val#\"}
        val=${val%\"}
        ;;
      "'"*"'")
        val=${val#\'}
        val=${val%\'}
        ;;
    esac
    printf '%s\n' "$val"
    return 0
  done <"$file"
  return 1
}

# _os_map_codename CODENAME
#   Args: a derivative's own codename.
#   Prints the upstream Debian/Ubuntu codename it is built from, or nothing.
#   Returns 1 when the codename is unknown. Static table on purpose: no network,
#   no lsb_release (absent on minimal Debian).
_os_map_codename() {
  case ${1:-} in
    # Devuan -> Debian
    chimaera) printf 'bullseye\n' ;;
    daedalus) printf 'bookworm\n' ;;
    excalibur) printf 'trixie\n' ;;
    freia) printf 'forky\n' ;;
    # LMDE -> Debian
    elsie) printf 'bullseye\n' ;;
    faye) printf 'bookworm\n' ;;
    gigi) printf 'trixie\n' ;;
    # Kali rolling tracks Debian testing
    kali-rolling | kali-dev) printf 'trixie\n' ;;
    # Linux Mint -> Ubuntu
    una | uma | ulyssa | ulyana) printf 'focal\n' ;;
    vanessa | vera | victoria | virginia) printf 'jammy\n' ;;
    wilma | xia | zara | zena) printf 'noble\n' ;;
    # elementary OS -> Ubuntu
    jolnir) printf 'focal\n' ;;
    horus) printf 'noble\n' ;;
    *) return 1 ;;
  esac
}

# _os_codename_family CODENAME  -> debian | ubuntu | "" (private)
_os_codename_family() {
  case ${1:-} in
    buster | bullseye | bookworm | trixie | forky | duke) printf 'debian\n' ;;
    focal | jammy | kinetic | lunar | mantic | noble | oracular | plucky | questing | resolute)
      printf 'ubuntu\n'
      ;;
    *) return 1 ;;
  esac
}

# _os_codename_rank CODENAME  -> a monotonically increasing integer (private)
_os_codename_rank() {
  case ${1:-} in
    buster) printf '10\n' ;;
    bullseye) printf '11\n' ;;
    bookworm) printf '12\n' ;;
    trixie) printf '13\n' ;;
    forky) printf '14\n' ;;
    duke) printf '15\n' ;;
    focal) printf '2004\n' ;;
    jammy) printf '2204\n' ;;
    kinetic) printf '2210\n' ;;
    lunar) printf '2304\n' ;;
    mantic) printf '2310\n' ;;
    noble) printf '2404\n' ;;
    oracular) printf '2410\n' ;;
    plucky) printf '2504\n' ;;
    questing) printf '2510\n' ;;
    resolute) printf '2604\n' ;;
    *) return 1 ;;
  esac
}

# _os_detect_arch  (private) — sets OS_ARCH_*
_os_detect_arch() {
  OS_ARCH_UNAME=$(uname -m 2>/dev/null || printf 'unknown\n')
  if have dpkg; then
    OS_ARCH_DPKG=$(dpkg --print-architecture 2>/dev/null || printf '\n')
  else
    OS_ARCH_DPKG=''
  fi
  if [ -z "$OS_ARCH_DPKG" ]; then
    case $OS_ARCH_UNAME in
      x86_64 | amd64) OS_ARCH_DPKG=amd64 ;;
      aarch64 | arm64) OS_ARCH_DPKG=arm64 ;;
      armv7l | armv6l) OS_ARCH_DPKG=armhf ;;
      i686 | i386) OS_ARCH_DPKG=i386 ;;
      ppc64le) OS_ARCH_DPKG=ppc64el ;;
      riscv64) OS_ARCH_DPKG=riscv64 ;;
      s390x) OS_ARCH_DPKG=s390x ;;
      *) OS_ARCH_DPKG=$OS_ARCH_UNAME ;;
    esac
  fi
  # dpkg is the source of truth: an armhf userland on an arm64 kernel reports
  # aarch64 from uname but armhf from dpkg, and the packages must match dpkg.
  case $OS_ARCH_DPKG in
    amd64)
      OS_ARCH_GO=amd64 OS_ARCH_RUST=x86_64
      OS_ARCH_UNAME=x86_64
      ;;
    arm64)
      OS_ARCH_GO=arm64 OS_ARCH_RUST=aarch64
      OS_ARCH_UNAME=aarch64
      ;;
    armhf)
      OS_ARCH_GO=arm OS_ARCH_RUST=armv7
      OS_ARCH_UNAME=armv7l
      ;;
    i386)
      OS_ARCH_GO=386 OS_ARCH_RUST=i686
      OS_ARCH_UNAME=i686
      ;;
    ppc64el)
      OS_ARCH_GO=ppc64le OS_ARCH_RUST=powerpc64le
      OS_ARCH_UNAME=ppc64le
      ;;
    riscv64) OS_ARCH_GO=riscv64 OS_ARCH_RUST=riscv64gc ;;
    s390x) OS_ARCH_GO=s390x OS_ARCH_RUST=s390x ;;
    *) OS_ARCH_GO=$OS_ARCH_DPKG OS_ARCH_RUST=$OS_ARCH_UNAME ;;
  esac
  export OS_ARCH_DPKG OS_ARCH_UNAME OS_ARCH_GO OS_ARCH_RUST
}

# _os_detect_platform  (private) — sets IS_WSL/WSL_VERSION/HAS_WSLG/HAS_WSL_INTEROP/
#                       IS_CONTAINER/HAS_SYSTEMD/INIT_SYSTEM
# K25: WSL is detected from the filesystem, NEVER from $WSL_DISTRO_NAME (verified
# unset in the user's own live shell; it is only exported by the wsl.exe launcher).
_os_detect_platform() {
  local osrel=''
  [ -r /proc/sys/kernel/osrelease ] && read -r osrel </proc/sys/kernel/osrelease

  # The container check comes FIRST because the WSL check depends on it.
  IS_CONTAINER=0
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${container:-}" ]; then
    IS_CONTAINER=1
  elif grep -qE '(docker|lxc|containerd|kubepods|podman)' /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=1
  fi

  # A CONTAINER RUNNING ON A WSL2 HOST IS NOT WSL. It shares the host's kernel, so
  # /proc/sys/kernel/osrelease reads "…-microsoft-standard-WSL2" inside every
  # docker container started from a WSL2 distribution — which is exactly how the
  # container matrix runs. Trusting that string alone made `70-wsl.sh` "succeed"
  # on debian:12, and would have offered to write /etc/wsl.conf in a container
  # that has no /etc/wsl.conf, no interop and no Windows to restart.
  # So: a WSL-specific FILESYSTEM marker is proof either way, and the kernel
  # string is only believed when this is not a container (which keeps WSL1, whose
  # kernel says "Microsoft" and which has none of those directories, working).
  IS_WSL=0 WSL_VERSION='' HAS_WSLG=0 HAS_WSL_INTEROP=0
  if [ -d /run/WSL ] || [ -d /usr/lib/wsl ] || [ -d /mnt/wsl ]; then
    IS_WSL=1
  elif [ "$IS_CONTAINER" = 0 ]; then
    case $osrel in *[Mm]icrosoft* | *WSL*) IS_WSL=1 ;; esac
  fi
  if [ "$IS_WSL" = 1 ]; then
    case $osrel in
      *WSL2* | *microsoft-standard*) WSL_VERSION=2 ;;
      *) WSL_VERSION=1 ;;
    esac
    [ -d /run/WSL ] && WSL_VERSION=2
    [ -d /mnt/wslg ] && HAS_WSLG=1
    if grep -q enabled /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null \
      || grep -q enabled /proc/sys/fs/binfmt_misc/WSLInterop-late 2>/dev/null; then
      HAS_WSL_INTEROP=1
    fi
  fi

  HAS_SYSTEMD=0
  [ -d /run/systemd/system ] && HAS_SYSTEMD=1
  if [ "$HAS_SYSTEMD" = 1 ]; then
    INIT_SYSTEM=systemd
  elif [ -d /etc/init.d ]; then
    INIT_SYSTEM=sysv
  else
    INIT_SYSTEM=unknown
  fi

  export IS_WSL WSL_VERSION HAS_WSLG HAS_WSL_INTEROP IS_CONTAINER HAS_SYSTEMD INIT_SYSTEM
}

# _os_detect_headless  (private) — sets IS_HEADLESS
# VERIFIED-FACT #4: Ujstor/tmux-config does `set-environment -g DISPLAY :1`
# unconditionally, so $DISPLAY alone makes a headless box look graphical inside
# tmux. A display counts only when its SOCKET exists.
_os_detect_headless() {
  IS_HEADLESS=1
  if [ "${HAS_WSLG:-0}" = 1 ]; then
    IS_HEADLESS=0
  elif [ -n "${WAYLAND_DISPLAY:-}" ] \
    && { [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WAYLAND_DISPLAY" ] \
      || [ -S "$WAYLAND_DISPLAY" ]; }; then
    IS_HEADLESS=0
  elif [ -n "${DISPLAY:-}" ]; then
    local n=${DISPLAY#*:}
    n=${n%%.*}
    [ -S "/tmp/.X11-unix/X${n}" ] && IS_HEADLESS=0
    case $DISPLAY in */*) [ -S "$DISPLAY" ] && IS_HEADLESS=0 ;; esac
  fi
  export IS_HEADLESS
}

# os_detect
#   Args: none. Reads ${OS_RELEASE_FILE:-/etc/os-release}.
#   Sets and exports the whole variable contract above. Called once at source time
#   and re-runnable (unit tests point OS_RELEASE_FILE at a fixture).
#   Exit codes: always 0 — an unsupported box is reported by os_require_supported,
#   not by a failure here, so `devenv list`/`--help` still work anywhere.
#   Dry-run: read-only, always runs.
os_detect() {
  OS_ID=$(os_release_get ID || printf '\n')
  OS_ID_LIKE=$(os_release_get ID_LIKE || printf '\n')
  OS_PRETTY=$(os_release_get PRETTY_NAME || printf '\n')
  OS_VERSION_ID=$(os_release_get VERSION_ID || printf '\n')
  OS_VERSION_MAJOR=${OS_VERSION_ID%%.*}

  local own upstream ubuntu_cn debian_cn
  own=$(os_release_get VERSION_CODENAME || printf '\n')
  ubuntu_cn=$(os_release_get UBUNTU_CODENAME || printf '\n')
  debian_cn=$(os_release_get DEBIAN_CODENAME || printf '\n')

  # Codename precedence, exact (SPEC 5.3.3).
  OS_FLAVOR='' upstream=''
  case $OS_ID in
    ubuntu)
      OS_FLAVOR=ubuntu
      upstream=$own
      ;;
    debian)
      OS_FLAVOR=debian
      upstream=$own
      ;;
    *)
      if [ -n "$ubuntu_cn" ]; then
        OS_FLAVOR=ubuntu
        upstream=$ubuntu_cn
      elif [ -n "$debian_cn" ]; then
        OS_FLAVOR=debian
        upstream=$debian_cn
      else
        case " $OS_ID_LIKE " in
          *' ubuntu '*) OS_FLAVOR=ubuntu ;;
          *' debian '*) OS_FLAVOR=debian ;;
        esac
        [ -n "$OS_FLAVOR" ] && upstream=$(_os_map_codename "$own" || printf '\n')
      fi
      ;;
  esac

  # A mapped codename must belong to the flavour we picked; otherwise drop it
  # rather than hand a vendor a suite it does not publish.
  if [ -n "$upstream" ] && [ "$(_os_codename_family "$upstream" 2>/dev/null || printf '\n')" != "$OS_FLAVOR" ]; then
    upstream=''
  fi

  OS_CODENAME=$own
  OS_UPSTREAM_CODENAME=$upstream
  # Debian sid/unstable publishes no VERSION_CODENAME. Name it for the summary,
  # but leave OS_UPSTREAM_CODENAME empty so every repo helper takes its
  # "suite not published" branch instead of inventing one.
  if [ "$OS_FLAVOR" = debian ] && [ -z "$OS_CODENAME" ]; then
    case $OS_PRETTY in *sid*) OS_CODENAME=sid ;; esac
  fi

  OS_FAMILY=''
  [ -n "$OS_FLAVOR" ] && OS_FAMILY=debian

  OS_LIBC=''
  if have getconf; then
    OS_LIBC=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
  fi
  if [ -z "$OS_LIBC" ] && have ldd; then
    OS_LIBC=$(ldd --version 2>/dev/null | awk 'NR==1{print $NF}')
  fi

  _os_detect_arch
  _os_detect_platform
  _os_detect_headless

  export OS_ID OS_ID_LIKE OS_FAMILY OS_FLAVOR OS_CODENAME OS_UPSTREAM_CODENAME
  export OS_VERSION_ID OS_VERSION_MAJOR OS_PRETTY OS_LIBC
  return 0
}

# ---------------------------------------------------------------------------
# Predicates — all are 0/1 and safe inside `if`. None exits.
# ---------------------------------------------------------------------------

# os_is_ubuntu / os_is_debian  — which vendor archive layout applies.
os_is_ubuntu() { [ "${OS_FLAVOR:-}" = ubuntu ]; }
os_is_debian() { [ "${OS_FLAVOR:-}" = debian ]; }
# os_is_wsl / os_is_wsl2 / os_has_wslg
os_is_wsl() { [ "${IS_WSL:-0}" = 1 ]; }
os_is_wsl2() { [ "${IS_WSL:-0}" = 1 ] && [ "${WSL_VERSION:-}" = 2 ]; }
os_has_wslg() { [ "${HAS_WSLG:-0}" = 1 ]; }
# os_is_container / os_has_systemd / os_is_headless
os_is_container() { [ "${IS_CONTAINER:-0}" = 1 ]; }
os_has_systemd() { [ "${HAS_SYSTEMD:-0}" = 1 ]; }
os_is_headless() { [ "${IS_HEADLESS:-1}" = 1 ]; }

# os_upstream_ge CODENAME
#   Args: a Debian or Ubuntu codename.
#   Returns 0 when OS_UPSTREAM_CODENAME is that release or newer.
#   Returns 1 when it is older, when OS_UPSTREAM_CODENAME is empty (sid/testing,
#   unmappable derivative) or when the two codenames belong to different ladders
#   (comparing bookworm with noble is meaningless — ask os_is_debian first).
#   Never dies. Safe inside `if`.
os_upstream_ge() {
  local want=${1:?os_upstream_ge: CODENAME required} have_cn=${OS_UPSTREAM_CODENAME:-}
  [ -n "$have_cn" ] || return 1
  local fa fb ra rb
  fa=$(_os_codename_family "$have_cn") || return 1
  fb=$(_os_codename_family "$want") || return 1
  [ "$fa" = "$fb" ] || {
    log_debug "os_upstream_ge: $have_cn and $want are different distributions"
    return 1
  }
  ra=$(_os_codename_rank "$have_cn") || return 1
  rb=$(_os_codename_rank "$want") || return 1
  [ "$ra" -ge "$rb" ]
}

# os_require_supported
#   Args: none.
#   Returns 0 on a Debian-family box. Returns 1 with a clear, actionable message
#   on anything else — 00-preflight turns that into a `die`.
#   RECONCILIATION: SPEC 5.3.3 also made a codename-less box fatal. SPEC 5.3.3's own
#   sid/testing rule ("every repo takes its unpublished branch") presupposes the run
#   continues, so a Debian-family box with no upstream codename gets ONE warning and
#   returns 0. Set DEVENV_REQUIRE_CODENAME=1 to make it fatal instead.
os_require_supported() {
  if [ -z "${OS_FAMILY:-}" ]; then
    log_error "unsupported distribution: ${OS_PRETTY:-${OS_ID:-unknown}}"
    log_error "linux-devops-tools targets Debian 12/13 and Ubuntu 22.04/24.04 (and Debian-family derivatives)."
    return 1
  fi
  if [ -z "${OS_UPSTREAM_CODENAME:-}" ]; then
    log_warn "no upstream ${OS_FLAVOR} codename for '${OS_CODENAME:-unknown}' — third-party apt repos will be skipped"
    if [ "${DEVENV_REQUIRE_CODENAME:-0}" = 1 ]; then
      log_error "DEVENV_REQUIRE_CODENAME=1 and no upstream codename could be resolved"
      return 1
    fi
  fi
  return 0
}

# os_summary
#   Args: none. Prints four log lines describing the box. Always 0.
os_summary() {
  log_info "distro   ${OS_PRETTY:-unknown} (id=${OS_ID:-?} flavor=${OS_FLAVOR:-?})"
  log_info "codename ${OS_CODENAME:-none} -> upstream ${OS_UPSTREAM_CODENAME:-none}  libc ${OS_LIBC:-?}"
  log_info "arch     dpkg=${OS_ARCH_DPKG:-?} go=${OS_ARCH_GO:-?} uname=${OS_ARCH_UNAME:-?}"
  log_info "platform wsl=${IS_WSL:-0}${WSL_VERSION:+v$WSL_VERSION} wslg=${HAS_WSLG:-0} container=${IS_CONTAINER:-0} init=${INIT_SYSTEM:-?} headless=${IS_HEADLESS:-?}"
}

# version_ge A B
#   Returns 0 when version A >= version B. Uses dpkg --compare-versions when dpkg
#   is present, otherwise a pure-bash dotted-numeric compare (leading 'v' and any
#   -suffix are ignored). Safe inside `if`; never dies.
version_ge() {
  local a=${1:-} b=${2:-}
  a=${a#v} b=${b#v}
  [ -n "$a" ] || return 1
  [ -n "$b" ] || return 0
  if have dpkg; then
    dpkg --compare-versions "$a" ge "$b" 2>/dev/null && return 0
    dpkg --compare-versions "$a" lt "$b" 2>/dev/null && return 1
  fi
  local ai bi i n
  IFS='.-+~' read -r -a ai <<<"$a"
  IFS='.-+~' read -r -a bi <<<"$b"
  n=${#ai[@]}
  [ "${#bi[@]}" -gt "$n" ] && n=${#bi[@]}
  for ((i = 0; i < n; i++)); do
    local x=${ai[i]:-0} y=${bi[i]:-0}
    case $x in '' | *[!0-9]*) x=0 ;; esac
    case $y in '' | *[!0-9]*) y=0 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}

# kernel_version
#   Prints the dotted-numeric part of `uname -r` (e.g. 6.6.87). Always 0.
kernel_version() {
  local r
  r=$(uname -r 2>/dev/null || printf '\n')
  r=${r%%-*}
  printf '%s\n' "$r"
}

# require_arch ARCH…
#   Args: one or more dpkg architecture names.
#   Returns 0 when OS_ARCH_DPKG is one of them. Otherwise calls `skip`, so the
#   MODULE EXITS 78. Only call it at module top level, never from a helper whose
#   caller expects to continue.
require_arch() {
  local a
  for a in "$@"; do
    [ "$a" = "${OS_ARCH_DPKG:-}" ] && return 0
  done
  skip "architecture ${OS_ARCH_DPKG:-unknown} is not supported by this module (needs: $*)"
}

os_detect
