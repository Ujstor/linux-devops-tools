# shellcheck shell=bash
# lib/repo.sh — third-party apt repositories: keys, deb822 sources, suite resolution.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
#
# D5/K14: every repo is a deb822 `.sources` file plus an ASCII-ARMORED `.asc` key in
# /etc/apt/keyrings. apt has accepted armored keys in `Signed-By:` since 1.4 and every
# target ships >= 2.2, so `gpg --dearmor` is never called and `gnupg` stops being a
# dependency of this repository (constraint C1 — Debian minimal has no gnupg).
#
# MUST-FIX S10: a key is fetched to a temp file, VALIDATED as a key, and only then
# installed. An existing keyring that is empty or corrupt is REPAIRED rather than
# trusted forever. `curl … | sudo tee /etc/apt/keyrings/x.asc` never happens here.
#
# MUST-FIX C6: suite probing follows redirects and accepts any 2xx — pkgs.k8s.io
# answers 302 and a 200-only test declares the Kubernetes repo non-existent.
#
# Every sources file is CONTENT-COMPARED before writing, so a re-run is a no-op and
# `apt-get update` is not forced for nothing.
#
# repo_ensure_brave() was DELETED (SPEC-ADDENDUM C16): there is no GUI browser in any
# profile, so /etc/apt/keyrings is now exceptionless.

[ -n "${_DEVENV_REPO:-}" ] && return 0
_DEVENV_REPO=1

KEYRING_DIR=${KEYRING_DIR:-/etc/apt/keyrings}
SOURCES_DIR=${SOURCES_DIR:-/etc/apt/sources.list.d}

# _repo_key_path NAME KIND   (private)
_repo_key_path() {
  case $2 in
    asc) printf '%s/%s.asc\n' "$KEYRING_DIR" "$1" ;;
    bin) printf '%s/%s.gpg\n' "$KEYRING_DIR" "$1" ;;
    *) return 1 ;;
  esac
}

# _repo_key_valid FILE KIND   (private)
#   asc -> must begin with the PGP armor header.
#   bin -> first byte must be an OpenPGP public-key packet tag (0x98/0x99/0xc6).
_repo_key_valid() {
  local f=$1 kind=$2 b
  [ -s "$f" ] || return 1
  case $kind in
    asc) head -n1 -- "$f" | grep -qx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' ;;
    bin)
      b=$(od -An -tx1 -N1 -- "$f" 2>/dev/null | tr -d ' \n')
      case $b in 98 | 99 | c6) return 0 ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

# repo_key NAME URL KIND [--sha256 SUM]
#   Installs a vendor signing key at $KEYRING_DIR/NAME.{asc,gpg}, mode 0644.
#     KIND=asc  the vendor serves an ARMORED key; it is stored verbatim.
#     KIND=bin  the vendor serves an already-binary key (github-cli); stored as .gpg.
#   --sha256 pins the key file's digest (idempotency F15): a mismatch triggers a
#   re-fetch rather than silent trust. An empty value means "not pinned".
#   NEVER runs `gpg --dearmor` (K14). NEVER pipes a download straight into the live
#   keyring path.
#   Idempotent: an existing, VALID (and, when pinned, matching) key is a no-op.
#   An existing INVALID key is re-fetched — MUST-FIX S10's "repair a corrupt key
#   rather than failing forever".
#   Prints the installed path on stdout. Honours --dry-run. Returns non-zero on failure.
repo_key() {
  local name=${1:?repo_key: NAME required} url=${2:?repo_key: URL required}
  local kind=${3:?repo_key: KIND required (asc|bin)}
  shift 3
  local pin=''
  while [ $# -gt 0 ]; do
    case $1 in
      --sha256)
        pin=${2:-}
        shift 2
        ;;
      *)
        log_error "repo_key: unknown option $1"
        return 1
        ;;
    esac
  done
  local dest tmp
  dest=$(_repo_key_path "$name" "$kind") || {
    log_error "repo_key: KIND must be asc or bin, got '$kind'"
    return 1
  }

  if [ -f "$dest" ]; then
    if _repo_key_valid "$dest" "$kind"; then
      if [ -z "$pin" ]; then
        log_debug "keyring already present: $dest"
        printf '%s\n' "$dest"
        return 0
      fi
      if verify_sha256 "$dest" "$pin" >/dev/null 2>&1; then
        log_debug "keyring already present and pinned: $dest"
        printf '%s\n' "$dest"
        return 0
      fi
      log_warn "$dest does not match its pinned digest — re-fetching it"
    else
      log_warn "$dest is empty or is not a PGP key — repairing it"
    fi
  fi

  if is_dry_run; then
    log_dryrun "install signing key $dest from $url"
    printf '%s\n' "$dest"
    return 0
  fi

  local work
  work=$(devenv_tmpdir) || return 1
  tmp="$work/$name.key"
  download "$url" "$tmp" || {
    log_error "could not download the signing key for '$name' from $url"
    return 1
  }
  if ! _repo_key_valid "$tmp" "$kind"; then
    log_error "$url did not serve a $kind OpenPGP public key — refusing to install it"
    return 1
  fi
  if [ -n "$pin" ]; then
    verify_sha256 "$tmp" "$pin" || return 1
  fi
  ensure_dir "$KEYRING_DIR" 0755 || return 1
  _fs_run_for "$dest" install -m 0644 -- "$tmp" "$dest" || return 1
  log_success "installed signing key $dest"
  changed "apt key $name"
  printf '%s\n' "$dest"
  return 0
}

# _repo_drop_legacy NAME   (private)
#   Removes the one-line .list form of the same repo, plus the
#   archive_uri-*NAME*.list files add-apt-repository leaves behind. Two sources for
#   one URI make apt warn on every update.
_repo_drop_legacy() {
  local name=$1 f
  for f in "$SOURCES_DIR/$name.list" "$SOURCES_DIR/$name-archive.list"; do
    if [ -f "$f" ]; then
      log_info "removing the superseded $f"
      _fs_run_for "$f" rm -f -- "$f" || true
      changed "removed $f"
    fi
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    log_info "removing the stale $f left by add-apt-repository"
    _fs_run_for "$f" rm -f -- "$f" || true
    changed "removed $f"
  done < <(find "$SOURCES_DIR" -maxdepth 1 -name "archive_uri-*${name}*.list" 2>/dev/null)
  return 0
}

# repo_add NAME URI SUITES COMPONENTS SIGNED_BY [ARCH]
#   Renders a deb822 source at $SOURCES_DIR/NAME.sources.
#     SUITES      space-separated (usually one codename)
#     COMPONENTS  space-separated (usually "main"; empty for a flat repo — use
#                 repo_add_flat instead)
#     SIGNED_BY   the keyring path returned by repo_key
#     ARCH        optional Architectures: value (defaults to $OS_ARCH_DPKG)
#   Writes ONLY when the rendered content differs, so a re-run changes nothing and
#   does not force an index refresh. Sets NEED_APT_UPDATE=1 on change and drops the
#   legacy .list form of the same repo.
#   Honours --dry-run. Returns 0.
repo_add() {
  local name=${1:?repo_add: NAME required} uri=${2:?repo_add: URI required}
  local suites=${3:?repo_add: SUITES required} comps=${4:?repo_add: COMPONENTS required}
  local key=${5:?repo_add: SIGNED_BY required} arch=${6:-${OS_ARCH_DPKG:-}}
  local dest="$SOURCES_DIR/$name.sources" tmp
  tmp=$(devenv_tmpfile) || return 1
  {
    printf '# Managed by linux-devops-tools. Local edits are overwritten.\n'
    printf 'Types: deb\n'
    printf 'URIs: %s\n' "$uri"
    printf 'Suites: %s\n' "$suites"
    printf 'Components: %s\n' "$comps"
    [ -n "$arch" ] && printf 'Architectures: %s\n' "$arch"
    printf 'Signed-By: %s\n' "$key"
  } >"$tmp"

  _repo_drop_legacy "$name"
  if [ -f "$dest" ] && cmp -s -- "$tmp" "$dest"; then
    log_debug "apt source unchanged: $dest"
    DEVENV_CHANGED_LAST=0
    return 0
  fi
  ensure_dir "$SOURCES_DIR" || return 1
  if is_dry_run; then
    log_dryrun "write $dest ($uri $suites $comps)"
    changed "apt source $name"
    NEED_APT_UPDATE=1
    export NEED_APT_UPDATE
    return 0
  fi
  _fs_run_for "$dest" install -m 0644 -- "$tmp" "$dest" || return 1
  log_success "configured the $name apt repository ($suites)"
  changed "apt source $name"
  NEED_APT_UPDATE=1
  export NEED_APT_UPDATE
  return 0
}

# repo_add_flat NAME URI SIGNED_BY
#   The FLAT-repository form, for archives that publish no suite/component tree —
#   pkgs.k8s.io is the only one in this repo.
#   correctness C16: rendered as deb822 like everything else (D5), which for a flat
#   repo means `Suites: /` and NO Components field:
#       Types: deb
#       URIs: https://pkgs.k8s.io/core:/stable:/v1.34/deb/
#       Suites: /
#       Signed-By: /etc/apt/keyrings/kubernetes.asc
#   Same content-compare, same legacy cleanup, same NEED_APT_UPDATE contract.
repo_add_flat() {
  local name=${1:?repo_add_flat: NAME required} uri=${2:?repo_add_flat: URI required}
  local key=${3:?repo_add_flat: SIGNED_BY required}
  local dest="$SOURCES_DIR/$name.sources" tmp
  tmp=$(devenv_tmpfile) || return 1
  {
    printf '# Managed by linux-devops-tools. Local edits are overwritten.\n'
    printf 'Types: deb\n'
    printf 'URIs: %s\n' "$uri"
    printf 'Suites: /\n'
    printf 'Signed-By: %s\n' "$key"
  } >"$tmp"

  _repo_drop_legacy "$name"
  if [ -f "$dest" ] && cmp -s -- "$tmp" "$dest"; then
    log_debug "apt source unchanged: $dest"
    DEVENV_CHANGED_LAST=0
    return 0
  fi
  ensure_dir "$SOURCES_DIR" || return 1
  if is_dry_run; then
    log_dryrun "write $dest ($uri, flat)"
    changed "apt source $name"
    NEED_APT_UPDATE=1
    export NEED_APT_UPDATE
    return 0
  fi
  _fs_run_for "$dest" install -m 0644 -- "$tmp" "$dest" || return 1
  log_success "configured the $name apt repository (flat)"
  changed "apt source $name"
  NEED_APT_UPDATE=1
  export NEED_APT_UPDATE
  return 0
}

# repo_remove NAME
#   Removes $SOURCES_DIR/NAME.sources and the legacy .list forms. Leaves the keyring
#   in place (other sources may reference it). Honours --dry-run. Returns 0.
repo_remove() {
  local name=${1:?repo_remove: NAME required}
  local dest="$SOURCES_DIR/$name.sources"
  _repo_drop_legacy "$name"
  [ -f "$dest" ] || return 0
  _fs_run_for "$dest" rm -f -- "$dest" || return 0
  changed "removed apt source $name"
  NEED_APT_UPDATE=1
  export NEED_APT_UPDATE
  return 0
}

# repo_suite_exists URI SUITE
#   Returns 0 when <URI>/dists/<SUITE>/Release answers 2xx AFTER following redirects.
#   MUST-FIX C6: pkgs.k8s.io answers 302; a 200-only test would report "no such
#   suite" for the Kubernetes archive and drift.yml would open a false-alarm PR
#   every week. Read-only; safe under --dry-run.
repo_suite_exists() {
  local uri=${1:?repo_suite_exists: URI required} suite=${2:?repo_suite_exists: SUITE required}
  http_ok "${uri%/}/dists/${suite}/Release"
}

# repo_suite_has_pkg URI SUITE COMPONENT PKG
#   Returns 0 when the suite's binary index actually LISTS PKG.
#   HashiCorp's oracular/plucky/questing suites answer 200 with an EMPTY index, so
#   existence alone is not enough. Falls back to "exists" when gzip is unavailable.
repo_suite_has_pkg() {
  local uri=${1%/} suite=$2 comp=$3 pkg=$4
  local idx="${uri}/dists/${suite}/${comp}/binary-${OS_ARCH_DPKG:-amd64}/Packages.gz"
  if ! have gzip; then
    log_debug "gzip is absent — cannot inspect $idx, accepting the suite on existence alone"
    return 0
  fi
  http_body "$idx" 2>/dev/null | gzip -dc 2>/dev/null | grep -qx "Package: $pkg"
}

# repo_suite_pick URI SUITE…
#   Prints the FIRST suite in the list that exists. When REPO_VERIFY_PKG is set, the
#   suite must also list that package (see repo_suite_has_pkg); REPO_VERIFY_COMPONENT
#   defaults to `main`.
#   Returns 1 and prints nothing when none of the suites qualifies — the caller then
#   logs a skip rather than writing a source apt cannot use.
#   Read-only; under --dry-run it still probes (probing mutates nothing).
repo_suite_pick() {
  local uri=${1:?repo_suite_pick: URI required}
  shift
  local s
  for s in "$@"; do
    [ -n "$s" ] || continue
    repo_suite_exists "$uri" "$s" || continue
    if [ -n "${REPO_VERIFY_PKG:-}" ]; then
      repo_suite_has_pkg "$uri" "$s" "${REPO_VERIFY_COMPONENT:-main}" "$REPO_VERIFY_PKG" || {
        log_debug "$uri $s exists but does not list ${REPO_VERIFY_PKG}"
        continue
      }
    fi
    printf '%s\n' "$s"
    return 0
  done
  return 1
}

# _repo_ladder_down FLAVOR CODENAME LADDER…   (private)
#   Prints the vendor-published suites that are at most as new as CODENAME, newest
#   first. That is what "step down the vendor's published list" means: a trixie box
#   may fall back to bookworm, never up to forky.
_repo_ladder_down() {
  local codename=$1
  shift
  local want s r out=()
  want=$(_os_codename_rank "$codename" 2>/dev/null) || want=999999
  for s in "$@"; do
    r=$(_os_codename_rank "$s" 2>/dev/null) || continue
    [ "$r" -le "$want" ] || continue
    out=("$s" "${out[@]}")
  done
  [ ${#out[@]} -gt 0 ] || return 1
  printf '%s\n' "${out[@]}"
}

# repo_migrate_legacy
#   Removes the stale .list/keyring pairs the OLD wsl2-config repo left behind, so a
#   machine it provisioned stops seeing duplicate-source warnings. Reports each
#   removal. Honours --dry-run. Always returns 0.
repo_migrate_legacy() {
  local n
  for n in docker github-cli hashicorp kubernetes azure-cli trivy; do
    if [ -f "$SOURCES_DIR/$n.sources" ]; then _repo_drop_legacy "$n"; fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Per-vendor helpers. They exist as separate functions because their fallback
# logic genuinely differs (K3); a half-expressive data table would be worse.
# Each prints nothing on stdout, returns 0 on success and 78 when this box's
# codename has no usable suite (the module then logs a skip).
# ---------------------------------------------------------------------------

# repo_ensure_docker
#   URI download.docker.com/linux/$OS_FLAVOR, suite = OS_UPSTREAM_CODENAME, key asc.
#   Fallback steps DOWN that vendor's own published ladder, never up.
repo_ensure_docker() {
  os_is_debian || os_is_ubuntu || {
    log_skip "docker apt repo: unsupported distribution"
    return 78
  }
  [ -n "${OS_UPSTREAM_CODENAME:-}" ] || {
    log_skip "docker apt repo: no upstream codename for ${OS_CODENAME:-unknown}"
    return 78
  }
  local uri="https://download.docker.com/linux/$OS_FLAVOR" key suite
  local ladder=() cands=()
  if os_is_debian; then
    ladder=(bullseye bookworm trixie forky)
  else
    ladder=(jammy noble oracular plucky questing resolute)
  fi
  mapfile -t cands < <(_repo_ladder_down "$OS_UPSTREAM_CODENAME" "${ladder[@]}")
  suite=$(repo_suite_pick "$uri" "${cands[@]}") || {
    log_warn "docker publishes no suite for ${OS_FLAVOR} ${OS_UPSTREAM_CODENAME} — skipping the docker repo"
    return 78
  }
  [ "$suite" = "$OS_UPSTREAM_CODENAME" ] \
    || log_warn "docker has no '$OS_UPSTREAM_CODENAME' suite — falling back to '$suite'"
  key=$(repo_key docker "$uri/gpg" asc --sha256 "${DOCKER_KEY_SHA256:-}") || return 1
  repo_add docker "$uri" "$suite" main "$key"
}

# repo_ensure_hashicorp
#   ALLOWLIST, not a probe (D6): three HashiCorp suites answer 200 with an EMPTY
#   index, so "the suite exists" is not evidence that terraform is in it.
#   Anything outside the allowlist falls back to bookworm (Debian) / noble (Ubuntu),
#   which renders byte-identical content on both distributions.
repo_ensure_hashicorp() {
  os_is_debian || os_is_ubuntu || {
    log_skip "hashicorp apt repo: unsupported distribution"
    return 78
  }
  local uri="https://apt.releases.hashicorp.com" suite key
  case ${OS_UPSTREAM_CODENAME:-} in
    bookworm | trixie | jammy | noble | resolute) suite=$OS_UPSTREAM_CODENAME ;;
    *)
      if os_is_debian; then suite=bookworm; else suite=noble; fi
      log_warn "hashicorp does not publish '${OS_UPSTREAM_CODENAME:-unknown}' — using '$suite'"
      ;;
  esac
  key=$(repo_key hashicorp "$uri/gpg" asc --sha256 "${HASHICORP_KEY_SHA256:-}") || return 1
  repo_add hashicorp "$uri" "$suite" main "$key"
}

# repo_ensure_kubernetes MINOR
#   The flat pkgs.k8s.io repo for one minor (e.g. v1.34). The signing key is
#   per-minor but identical in practice; it is re-fetched whenever the minor changes.
#   Detects a DOWNGRADE (the configured minor is newer than MINOR) and refuses unless
#   DEVENV_ALLOW_DOWNGRADES=1, because apt would then offer an older kubectl.
#   Forces one `pkg_update` when the source changed.
repo_ensure_kubernetes() {
  local minor=${1:?repo_ensure_kubernetes: MINOR required}
  case $minor in v[0-9]*.[0-9]*) ;; *)
    log_error "repo_ensure_kubernetes: MINOR must look like v1.34, got '$minor'"
    return 1
    ;;
  esac
  local base="https://pkgs.k8s.io/core:/stable:/$minor/deb/" key cur
  cur=$(grep -hoE 'stable:/v[0-9]+\.[0-9]+' "$SOURCES_DIR/kubernetes.sources" \
    "$SOURCES_DIR/kubernetes.list" 2>/dev/null | head -n1) || cur=''
  cur=${cur#stable:/}
  if [ -n "$cur" ] && [ "$cur" != "$minor" ]; then
    if version_ge "${cur#v}" "${minor#v}"; then
      if [ "${DEVENV_ALLOW_DOWNGRADES:-0}" != 1 ]; then
        log_warn "the kubernetes repo is pinned to $cur, newer than the requested $minor."
        log_warn "  keeping $cur. Set DEVENV_ALLOW_DOWNGRADES=1 (and K8S_MINOR=$minor) to move back."
        return 0
      fi
      log_warn "downgrading the kubernetes repo from $cur to $minor on request"
    else
      log_info "moving the kubernetes repo from $cur to $minor"
    fi
  fi
  key=$(repo_key kubernetes "${base}Release.key" asc --sha256 "${KUBERNETES_KEY_SHA256:-}") || return 1
  repo_add_flat kubernetes "$base" "$key" || return 1
  if [ "${DEVENV_CHANGED_LAST:-0}" = 1 ]; then pkg_update --force; fi
  return 0
}

# repo_ensure_github_cli
#   Suite is literally `stable`, so one identical line on both distributions.
#   The key is BINARY (kind bin) — one of only two vendors that publish one.
#   Also removes the /usr/share/keyrings copy the vendor's own instructions create,
#   so there is exactly one trusted copy.
repo_ensure_github_cli() {
  local uri="https://cli.github.com/packages" key
  key=$(repo_key github-cli "$uri/githubcli-archive-keyring.gpg" bin \
    --sha256 "${GITHUB_CLI_KEY_SHA256:-}") || return 1
  local legacy=/usr/share/keyrings/githubcli-archive-keyring.gpg
  if [ -f "$legacy" ]; then
    log_info "removing the duplicate $legacy (the keyring now lives in $KEYRING_DIR)"
    _fs_run_for "$legacy" rm -f -- "$legacy" || true
  fi
  repo_add github-cli "$uri" stable main "$key"
}

# repo_ensure_azure_cli
#   packages.microsoft.com does not publish every Debian suite (trixie is a verified
#   404). Order: use this box's own codename when it is actually published, else the
#   K12 ABI map, else 78 so the module can fall back to `uv tool install azure-cli`.
#   K12: trixie/forky/plucky/questing -> NOBLE, not bookworm. trixie ships libssl3t64
#   and glibc 2.41, so the bookworm build's `Depends: libssl3` is unsatisfiable while
#   the noble build's libssl3t64 / glibc >= 2.38 requirement is satisfied.
#   correctness C21: the probe runs first, so the static map only has to cover the
#   suites that are genuinely missing.
repo_ensure_azure_cli() {
  local uri="https://packages.microsoft.com/repos/azure-cli/" suite='' key
  if [ -n "${OS_UPSTREAM_CODENAME:-}" ] && repo_suite_exists "$uri" "$OS_UPSTREAM_CODENAME"; then
    suite=$OS_UPSTREAM_CODENAME
  else
    case ${OS_UPSTREAM_CODENAME:-} in
      bullseye | bookworm | jammy | noble | resolute) suite=$OS_UPSTREAM_CODENAME ;;
      trixie | forky | plucky | questing)
        suite=noble
        log_warn "packages.microsoft.com publishes no '$OS_UPSTREAM_CODENAME' suite for azure-cli."
        log_warn "  Using the 'noble' build (K12): it depends on libssl3t64 and glibc >= 2.38,"
        log_warn "  which ${OS_CODENAME:-this release} satisfies; the bookworm build needs libssl3 and does not."
        ;;
      *)
        log_warn "no azure-cli suite for '${OS_UPSTREAM_CODENAME:-unknown}' — install it with 'uv tool install azure-cli' instead"
        return 78
        ;;
    esac
  fi
  key=$(repo_key microsoft "https://packages.microsoft.com/keys/microsoft.asc" asc \
    --sha256 "${AZURE_CLI_KEY_SHA256:-}") || return 1
  repo_add azure-cli "$uri" "$suite" main "$key"
}

# repo_ensure_trivy
#   The suite is literally `generic`, so this renders one identical line on Debian
#   and Ubuntu with no codename logic at all.
repo_ensure_trivy() {
  local uri="https://get.trivy.dev/deb" key
  key=$(repo_key trivy "$uri/public.key" asc --sha256 "${TRIVY_KEY_SHA256:-}") || return 1
  repo_add trivy "$uri" generic main "$key"
}

# _k8s_stream_cache FILE VALUE   (private) — print VALUE, and remember it unless dry-run.
_k8s_stream_cache() {
  printf '%s\n' "$2"
  is_dry_run && return 0
  ensure_dir "$(dirname -- "$1")" >/dev/null 2>&1 || return 0
  printf '%s\n' "$2" >"$1" 2>/dev/null || true
  return 0
}

# k8s_detect_stream
#   Prints the Kubernetes minor to configure (e.g. v1.34).
#   K8S_MINOR from versions.env wins. The literal value `auto` enables the three-tier
#   probe: the current cluster's serverVersion -> dl.k8s.io/release/stable.txt ->
#   the cached answer in $DEVENV_CACHE/k8s-stream.
#   A workstation should track the FLEET, not upstream: kubectl supports +/-1 minor
#   from the API server, so the default must be deterministic and offline-safe.
#   Always prints something and returns 0.
k8s_detect_stream() {
  local pin=${K8S_MINOR:-v1.34} cache="${DEVENV_CACHE:-/tmp}/k8s-stream" v
  if [ "$pin" != auto ]; then
    printf '%s\n' "$pin"
    return 0
  fi
  if have kubectl; then
    v=$(kubectl version -o json 2>/dev/null \
      | grep -oE '"minor":[[:space:]]*"[0-9]+' | tail -n1 | grep -oE '[0-9]+$') || v=''
    local maj
    maj=$(kubectl version -o json 2>/dev/null \
      | grep -oE '"major":[[:space:]]*"[0-9]+' | tail -n1 | grep -oE '[0-9]+$') || maj=''
    if [ -n "$v" ] && [ -n "$maj" ]; then
      _k8s_stream_cache "$cache" "v$maj.$v"
      return 0
    fi
  fi
  v=$(http_body https://dl.k8s.io/release/stable.txt 2>/dev/null | head -n1) || v=''
  case $v in
    v[0-9]*.[0-9]*.[0-9]*)
      _k8s_stream_cache "$cache" "${v%.*}"
      return 0
      ;;
  esac
  if [ -s "$cache" ]; then
    cat "$cache"
    return 0
  fi
  log_warn "could not detect a Kubernetes stream — falling back to v1.34"
  printf 'v1.34\n'
  return 0
}
