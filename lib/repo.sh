# shellcheck shell=bash
# lib/repo.sh — third-party package repositories: keys, sources, suite resolution.
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
#
# THE OTHER FAMILIES (spec 002 FR-009, plan D6). Every repo_ensure_<vendor> keeps its
# signature and dispatches on OS_FAMILY. debian runs the code above it unchanged
# (FR-008); redhat writes /etc/yum.repos.d/<name>.repo and suse
# /etc/zypp/repos.d/<name>.repo (repo_add_rpm); arch returns 78, because no vendor
# here publishes a pacman repository. The key is held to the SAME rules as an apt
# key — fetched to a temp file, validated as an armored OpenPGP key, optionally
# digest-pinned, repaired when corrupt — then kept in /etc/pki/rpm-gpg and imported
# with `rpm --import`, explicitly: neither dnf's prompt nor zypper's
# --gpg-auto-import-keys is ever what decides to trust a vendor. The .repo file
# names the key by its local path, so dnf and zypper never fetch a key themselves.
# Whether a key is already trusted is read from the rpm database by FINGERPRINT,
# computed here in bash (_repo_pgp_fingerprints) — still no gpg, on any family.
# A vendor that publishes nothing for a family returns 78 with the reason, and the
# module takes plan D6's fallback: the distribution's own package, then a verified
# release artifact, then `uv tool install`, then a skip.

[ -n "${_DEVENV_REPO:-}" ] && return 0
_DEVENV_REPO=1

KEYRING_DIR=${KEYRING_DIR:-/etc/apt/keyrings}
SOURCES_DIR=${SOURCES_DIR:-/etc/apt/sources.list.d}
# The rpm families. /etc/pki/rpm-gpg is where EL and Fedora keep vendor keys; Leap
# has no such directory and gets one, because one place per machine beats a
# second convention for the same file.
RPM_KEY_DIR=${RPM_KEY_DIR:-/etc/pki/rpm-gpg}
YUM_REPOS_DIR=${YUM_REPOS_DIR:-/etc/yum.repos.d}
ZYPP_REPOS_DIR=${ZYPP_REPOS_DIR:-/etc/zypp/repos.d}

# _repo_key_path NAME KIND   (private)
_repo_key_path() {
  case $2 in
    asc) printf '%s/%s.asc\n' "$KEYRING_DIR" "$1" ;;
    bin) printf '%s/%s.gpg\n' "$KEYRING_DIR" "$1" ;;
    rpm) printf '%s/RPM-GPG-KEY-%s\n' "$RPM_KEY_DIR" "$1" ;;
    *) return 1 ;;
  esac
}

# _repo_key_valid FILE KIND   (private)
#   asc, rpm -> must begin with the PGP armor header (`rpm --import` takes armor only).
#   bin -> first byte must be an OpenPGP public-key packet tag (0x98/0x99/0xc6).
_repo_key_valid() {
  local f=$1 kind=$2 b
  [ -s "$f" ] || return 1
  case $kind in
    asc | rpm) head -n1 -- "$f" | grep -qx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' ;;
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
#     KIND=rpm  an ARMORED key for the rpm families: stored verbatim as
#               $RPM_KEY_DIR/RPM-GPG-KEY-NAME and then imported into the rpm
#               database (_repo_rpm_import) — on every run, the import is
#               re-checked even when the file was already there.
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
    log_error "repo_key: KIND must be asc, bin or rpm, got '$kind'"
    return 1
  }

  if [ -f "$dest" ]; then
    if _repo_key_valid "$dest" "$kind"; then
      if [ -z "$pin" ]; then
        log_debug "keyring already present: $dest"
        if [ "$kind" = rpm ]; then _repo_rpm_import "$name" "$dest" || return 1; fi
        printf '%s\n' "$dest"
        return 0
      fi
      if verify_sha256 "$dest" "$pin" >/dev/null 2>&1; then
        log_debug "keyring already present and pinned: $dest"
        if [ "$kind" = rpm ]; then _repo_rpm_import "$name" "$dest" || return 1; fi
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
    if [ "$kind" = rpm ]; then log_dryrun "rpm --import $dest"; fi
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
  # ${dest%/*} is $KEYRING_DIR for an apt key and $RPM_KEY_DIR for an rpm one.
  ensure_dir "${dest%/*}" 0755 || return 1
  _fs_run_for "$dest" install -m 0644 -- "$tmp" "$dest" || return 1
  log_success "installed signing key $dest"
  if [ "$kind" = rpm ]; then
    fs_selinux_relabel "$dest"
    changed "rpm key $name"
    _repo_rpm_import "$name" "$dest" || return 1
  else
    changed "apt key $name"
  fi
  printf '%s\n' "$dest"
  return 0
}

# _repo_pgp_fingerprints FILE   (private)
#   Prints the v4 fingerprint (40 lower-case hex digits) of every PRIMARY public
#   key in an armored OpenPGP file, one per line — the identity the rpm database
#   files a key under. Pure bash, base64, od and sha1sum: a v4 fingerprint is the
#   SHA-1 of 0x99, the two-byte body length and the public-key packet body
#   (RFC 4880 12.2), so neither gpg nor sequoia is needed to ask "is this key
#   trusted already". Checked against `gpg --show-keys` for all seven vendor keys
#   used here, the two-key github-cli file included.
#   Every armor block in the file is read; packets are walked by their headers
#   (old and new format), and only tag 6 is hashed — user ids, signatures and
#   subkeys are stepped over.
#   Returns 1 when the file does not decode, a packet header is malformed, or a
#   primary key is not version 4 (the caller then imports rather than guesses).
#   Read-only.
_repo_pgp_fingerprints() {
  local f=${1:?_repo_pgp_fingerprints: FILE required} block hex i n b o tag len hl body
  local -a by
  [ -r "$f" ] || return 1
  while IFS= read -r block; do
    [ -n "$block" ] || continue
    hex=$(printf '%s' "$block" | base64 -d 2>/dev/null | od -An -v -tx1) || return 1
    read -r -a by <<<"$(printf '%s' "$hex" | tr '\n' ' ')"
    i=0 n=${#by[@]}
    [ "$n" -gt 0 ] || return 1
    while [ "$i" -lt "$n" ]; do
      b=$((16#${by[i]}))
      [ $((b & 0x80)) -ne 0 ] || return 1
      if [ $((b & 0x40)) -ne 0 ]; then
        # New-format header: the tag in the low six bits, then a 1-, 2- or 5-octet
        # length. A partial body length (224..254) never occurs in a key packet.
        tag=$((b & 0x3f)) o=$((16#${by[i + 1]:-0}))
        if [ "$o" -lt 192 ]; then
          len=$o hl=2
        elif [ "$o" -lt 224 ]; then
          len=$((((o - 192) << 8) + 16#${by[i + 2]:-0} + 192)) hl=3
        elif [ "$o" -eq 255 ]; then
          len=$((16#${by[i + 2]}${by[i + 3]}${by[i + 4]}${by[i + 5]})) hl=6
        else
          return 1
        fi
      else
        # Old-format header: the tag in bits 5..2, the length type in bits 1..0.
        tag=$(((b >> 2) & 0xf))
        case $((b & 3)) in
          0) len=$((16#${by[i + 1]})) hl=2 ;;
          1) len=$((16#${by[i + 1]}${by[i + 2]})) hl=3 ;;
          2) len=$((16#${by[i + 1]}${by[i + 2]}${by[i + 3]}${by[i + 4]})) hl=5 ;;
          *) return 1 ;;
        esac
      fi
      [ $((i + hl + len)) -le "$n" ] || return 1
      if [ "$tag" -eq 6 ]; then
        [ "${by[i + hl]}" = 04 ] || return 1
        body="99 $(printf '%02x %02x' $((len >> 8)) $((len & 255))) ${by[*]:i+hl:len}"
        printf '%b' "\\x${body// /\\x}" | sha1sum | cut -c1-40
      fi
      i=$((i + hl + len))
    done
  done < <(awk '
    /^-----BEGIN PGP PUBLIC KEY BLOCK-----/ { inb = 1; hdr = 1; buf = ""; next }
    /^-----END PGP PUBLIC KEY BLOCK-----/ { if (inb) print buf; inb = 0; next }
    !inb { next }
    hdr && /:/ { next }
    hdr { hdr = 0; if ($0 ~ /^[[:space:]]*$/) next }
    /^=/ { next }
    { gsub(/[[:space:]]/, ""); buf = buf $0 }' "$f")
}

# _repo_rpm_import NAME FILE   (private)
#   Makes sure every primary key in FILE is in the rpm database.
#   Read-only when it already is. rpm files a key as the package gpg-pubkey whose
#   VERSION is the low 32 bits of the key id up to rpm 4.20 (EL 9/10, Leap 16) and
#   the whole fingerprint from rpm 6 (Fedora 43/44) — verified in all seven images
#   — so both spellings of each fingerprint are accepted. The RELEASE is not
#   compared: rpm 4.16 and 4.19 file the same github-cli key under different ones.
#   A key this cannot fingerprint is simply imported: `rpm --import` of a key that
#   is already present succeeds and changes nothing.
#   Honours --dry-run through run_sudo. Returns 0, or 1 when rpm refuses the key.
_repo_rpm_import() {
  local name=$1 file=$2 known fprs fpr missing=0
  have rpm || {
    log_error "rpm is not installed — cannot trust the $name signing key"
    return 1
  }
  known=$(rpm -q gpg-pubkey --qf '%{VERSION}\n' 2>/dev/null | tr 'A-F' 'a-f') || known=''
  if fprs=$(_repo_pgp_fingerprints "$file") && [ -n "$fprs" ]; then
    while IFS= read -r fpr; do
      case $'\n'"$known"$'\n' in
        *$'\n'"$fpr"$'\n'* | *$'\n'"${fpr:32:8}"$'\n'*) ;;
        *) missing=1 ;;
      esac
    done <<<"$fprs"
    if [ "$missing" = 0 ]; then
      log_debug "the rpm database already trusts the $name key"
      return 0
    fi
  fi
  run_sudo rpm --import "$file" || {
    log_error "rpm refused the $name signing key in $file"
    return 1
  }
  log_success "imported the $name signing key into the rpm database"
  changed "rpm import $name"
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

# _repo_rpm_dir   (private)
#   Prints the directory this family's package manager reads .repo files from.
#   Returns 1 on a family that has none.
_repo_rpm_dir() {
  case ${OS_FAMILY:-} in
    redhat) printf '%s\n' "$YUM_REPOS_DIR" ;;
    suse) printf '%s\n' "$ZYPP_REPOS_DIR" ;;
    *) return 1 ;;
  esac
}

# repo_add_rpm NAME LABEL BASEURL KEYFILE REPO_GPGCHECK [KEY=VALUE…]
#   Renders the rpm-family source for one vendor: /etc/yum.repos.d/NAME.repo on
#   redhat, /etc/zypp/repos.d/NAME.repo on suse — one section, [NAME].
#     LABEL          the name= line (dnf prints it while refreshing)
#     BASEURL        verbatim. dnf and zypper both expand $releasever and $basearch,
#                    so pass them single-quoted when the vendor's tree is laid out
#                    by them: a `dnf system-upgrade` then follows on its own.
#     KEYFILE        the path repo_key printed. Named as file://, so neither tool
#                    ever fetches a key; it is already imported (repo_key KIND=rpm).
#     REPO_GPGCHECK  1 when the vendor signs its repomd.xml (a repomd.xml.asc
#                    exists), 0 when it signs only the packages. gpgcheck — the
#                    package signatures — is 1 always.
#     KEY=VALUE      extra lines, verbatim (includepkgs=… keeps a vendor's
#                    catch-all repository to the one package this repo wants).
#   zypper spells the two checks out (pkg_gpgcheck/repo_gpgcheck): its plain
#   gpgcheck=1 would otherwise demand a signed repomd.xml from a vendor that
#   publishes none, and answer "no" in non-interactive mode.
#   Same contract as repo_add: written ONLY when the content differs, so a re-run
#   changes nothing; NEED_APT_UPDATE=1 on change (the name is historical — it is
#   pkg_update's "refresh the index" flag on every family).
#   Honours --dry-run. Returns 0, or 1 on a family without .repo files.
repo_add_rpm() {
  local name=${1:?repo_add_rpm: NAME required} label=${2:?repo_add_rpm: LABEL required}
  local uri=${3:?repo_add_rpm: BASEURL required} key=${4:?repo_add_rpm: KEYFILE required}
  local rgc=${5:?repo_add_rpm: REPO_GPGCHECK required} dir dest tmp extra
  shift 5
  dir=$(_repo_rpm_dir) || {
    log_error "repo_add_rpm: the ${OS_FAMILY:-unknown} family has no .repo files"
    return 1
  }
  dest="$dir/$name.repo"
  tmp=$(devenv_tmpfile) || return 1
  {
    printf '# Managed by linux-devops-tools. Local edits are overwritten.\n'
    printf '[%s]\n' "$name"
    printf 'name=%s\n' "$label"
    printf 'baseurl=%s\n' "$uri"
    if [ "${OS_FAMILY:-}" = suse ]; then printf 'type=rpm-md\n'; fi
    printf 'enabled=1\n'
    if [ "${OS_FAMILY:-}" = suse ]; then printf 'autorefresh=1\n'; fi
    printf 'gpgcheck=1\n'
    printf 'repo_gpgcheck=%s\n' "$rgc"
    if [ "${OS_FAMILY:-}" = suse ]; then printf 'pkg_gpgcheck=1\n'; fi
    printf 'gpgkey=file://%s\n' "$key"
    for extra in "$@"; do printf '%s\n' "$extra"; done
  } >"$tmp"

  if [ -f "$dest" ] && cmp -s -- "$tmp" "$dest"; then
    log_debug "package source unchanged: $dest"
    DEVENV_CHANGED_LAST=0
    return 0
  fi
  ensure_dir "$dir" || return 1
  if is_dry_run; then
    log_dryrun "write $dest ($uri)"
    changed "${OS_PKG_MGR:-rpm} source $name"
    NEED_APT_UPDATE=1
    export NEED_APT_UPDATE
    return 0
  fi
  _fs_run_for "$dest" install -m 0644 -- "$tmp" "$dest" || return 1
  # Both rpm families run SELinux enforcing: restorecon gives the file the label
  # the policy names for its path (plan D9). A no-op where SELinux is off.
  fs_selinux_relabel "$dest"
  log_success "configured the $name ${OS_PKG_MGR:-rpm} repository"
  changed "${OS_PKG_MGR:-rpm} source $name"
  NEED_APT_UPDATE=1
  export NEED_APT_UPDATE
  return 0
}

# repo_rpm_published URL
#   Returns 0 when URL is an rpm-md repository: <URL>/repodata/repomd.xml answers
#   2xx after redirects (get.trivy.dev answers 302). The rpm form of
#   repo_suite_exists — a vendor tree that has no directory for this release or
#   architecture is a 404 here, before any .repo file is written.
#   Read-only; safe under --dry-run.
repo_rpm_published() {
  local uri=${1:?repo_rpm_published: URL required}
  http_ok "${uri%/}/repodata/repomd.xml"
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
  # awk reads the whole index: `grep -qx` would exit at the first match, gzip
  # would die of SIGPIPE and pipefail would report a package that IS there as
  # absent — on exactly the large indexes this check exists for.
  http_body "$idx" 2>/dev/null | gzip -dc 2>/dev/null \
    | awk -v want="Package: $pkg" '$0 == want { found = 1 } END { exit !found }'
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
#
# Spec 002: each public repo_ensure_<vendor> is now a dispatch on OS_FAMILY, and
# the Debian body it used to be is the _repo_<vendor>_deb right below it, moved,
# not rewritten (FR-008). An unset OS_FAMILY takes the Debian branch, which is
# what every caller saw before the family existed. 78 also means "this vendor
# publishes nothing for this family or release"; the reason is logged here.
# What was checked, on 2026-10-06, for the families' .repo files:
#
#   vendor      redhat (EL 9/10, Fedora 43/44)          suse (Leap 16.0)
#   docker      linux/{centos,fedora,rhel}/$rv/$ba      none (s390x only) -> 78
#   hashicorp   RHEL/$rv/$ba, fedora/$rv/$ba            none -> 78
#   kubernetes  pkgs.k8s.io core:/stable:/vX.Y/rpm/     the same tree
#   github-cli  cli.github.com/packages/rpm             the same tree
#   azure-cli   packages.microsoft.com/rhel/{9,10}/prod none (and no Fedora) -> 78
#               (yumrepos/azure-cli stops at el7 builds)
#   trivy       get.trivy.dev/rpm/releases/$ba          the same tree
#   arch: 78 for all six; nobody publishes a pacman repository.
# ---------------------------------------------------------------------------

# _repo_rpm_family VENDOR   (private)
#   Returns 0 on redhat and suse. On arch it logs why there is no vendor
#   repository and returns 1, so the caller can `|| return 78`.
_repo_rpm_family() {
  case ${OS_FAMILY:-} in
    redhat | suse) return 0 ;;
  esac
  log_skip "$1: no vendor repository for the ${OS_FAMILY:-unknown} family — the distribution's own package is used"
  return 1
}

# repo_ensure_docker
#   debian  download.docker.com/linux/$OS_FLAVOR (see _repo_docker_deb).
#   redhat  download.docker.com/linux/<tree>: fedora on Fedora, rhel on RHEL, and
#           centos for every EL rebuild (AlmaLinux, Rocky, CentOS Stream, Oracle) —
#           Docker's own instructions send the rebuilds to the CentOS tree. The
#           .repo file uses $releasever, as Docker's own does; the probe first
#           proves this release's tree exists (centos/10 and fedora/44 do).
#   suse, arch -> 78: Docker builds no Leap or Arch packages, and plan D6 takes
#           the distribution's own docker, docker-buildx and docker-compose there.
repo_ensure_docker() {
  case ${OS_FAMILY:-} in
    debian | '') _repo_docker_deb ;;
    redhat) _repo_docker_rpm ;;
    *)
      log_skip "docker: Docker publishes no ${OS_FAMILY} repository — the distribution's own docker is used"
      return 78
      ;;
  esac
}

# _repo_docker_deb   (private)
#   URI download.docker.com/linux/$OS_FLAVOR, suite = OS_UPSTREAM_CODENAME, key asc.
#   Fallback steps DOWN that vendor's own published ladder, never up.
#   The component is `stable`: Docker's archive has no `main` (its Release file
#   publishes `stable edge test nightly`, verified live for debian/bookworm and
#   ubuntu/noble). With `main`, apt skipped the index — "repository … doesn't
#   have the component 'main'" — and every docker package had no candidate. That
#   is why modules/30-containers.sh carried a private copy of this function; it
#   calls this one again now.
_repo_docker_deb() {
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
  repo_add docker "$uri" "$suite" stable "$key"
}

# _repo_docker_rpm   (private)
#   The rpm key is NOT the apt key (060A…9F35 "CE rpm", against 9DC8…CD88 "CE
#   deb"), so it has a pin of its own: DOCKER_RPM_KEY_SHA256. Docker signs its
#   repomd.xml, so repo_gpgcheck is on.
_repo_docker_rpm() {
  local tree uri key
  case ${OS_DISTRO:-} in
    fedora) tree=fedora ;;
    rhel) tree=rhel ;;
    *) tree=centos ;;
  esac
  uri="https://download.docker.com/linux/$tree"
  repo_rpm_published "$uri/${OS_VERSION_MAJOR:-}/${OS_ARCH_RPM:-}/stable" || {
    log_warn "docker publishes no $tree ${OS_VERSION_MAJOR:-?} tree for ${OS_ARCH_RPM:-this architecture} — skipping the docker repo"
    return 78
  }
  key=$(repo_key docker "$uri/gpg" rpm --sha256 "${DOCKER_RPM_KEY_SHA256:-}") || return 1
  # shellcheck disable=SC2016  # $releasever/$basearch are dnf's variables, written verbatim
  repo_add_rpm docker 'Docker CE Stable - $basearch' "$uri"'/$releasever/$basearch/stable' "$key" 1
}

# repo_ensure_hashicorp
#   debian  the apt allowlist (see _repo_hashicorp_deb).
#   redhat  rpm.releases.hashicorp.com/{RHEL,fedora}/$releasever/$basearch/stable.
#           HashiCorp drops a Fedora release quickly — fedora/42 is already a 404
#           — so the probe matters: no tree for this release is 78, and
#           modules/40-iac.sh then installs the verified release zip instead.
#   suse, arch -> 78 (no SUSE tree; Arch packages terraform itself).
repo_ensure_hashicorp() {
  case ${OS_FAMILY:-} in
    debian | '') _repo_hashicorp_deb ;;
    redhat) _repo_hashicorp_rpm ;;
    *)
      log_skip "hashicorp: HashiCorp publishes no ${OS_FAMILY} repository"
      return 78
      ;;
  esac
}

# _repo_hashicorp_deb   (private)
#   ALLOWLIST, not a probe (D6): three HashiCorp suites answer 200 with an EMPTY
#   index, so "the suite exists" is not evidence that terraform is in it.
#   Anything outside the allowlist falls back to bookworm (Debian) / noble (Ubuntu),
#   which renders byte-identical content on both distributions.
_repo_hashicorp_deb() {
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

# _repo_hashicorp_rpm   (private)
#   rpm.releases.hashicorp.com/gpg is byte-identical to the apt host's key
#   (sha256 1df7d66b…5430 on both), so HASHICORP_KEY_SHA256 pins either.
#   repomd.xml is signed: repo_gpgcheck on.
_repo_hashicorp_rpm() {
  local tree uri key
  case ${OS_DISTRO:-} in
    fedora) tree=fedora ;;
    *) tree=RHEL ;;
  esac
  uri="https://rpm.releases.hashicorp.com/$tree"
  repo_rpm_published "$uri/${OS_VERSION_MAJOR:-}/${OS_ARCH_RPM:-}/stable" || {
    log_warn "hashicorp publishes no $tree ${OS_VERSION_MAJOR:-?} tree for ${OS_ARCH_RPM:-this architecture}"
    return 78
  }
  key=$(repo_key hashicorp "https://rpm.releases.hashicorp.com/gpg" rpm \
    --sha256 "${HASHICORP_KEY_SHA256:-}") || return 1
  # shellcheck disable=SC2016  # $releasever/$basearch are dnf's variables, written verbatim
  repo_add_rpm hashicorp 'Hashicorp Stable - $basearch' "$uri"'/$releasever/$basearch/stable' "$key" 1
}

# _repo_k8s_current FILE…   (private)
#   Prints the minor (v1.34) the kubernetes source in FILE… points at, or nothing.
_repo_k8s_current() {
  local cur
  cur=$(grep -hoE 'stable:/v[0-9]+\.[0-9]+' "$@" 2>/dev/null | head -n1) || cur=''
  printf '%s\n' "${cur#stable:/}"
}

# _repo_k8s_moving CURRENT MINOR   (private)
#   The downgrade guard: returns 1 (and says why) when the configured CURRENT minor
#   is newer than MINOR and DEVENV_ALLOW_DOWNGRADES is not 1 — the package manager
#   would otherwise offer an older kubectl. Returns 0 when MINOR may be written.
_repo_k8s_moving() {
  local cur=$1 minor=$2
  if [ -n "$cur" ] && [ "$cur" != "$minor" ]; then
    if version_ge "${cur#v}" "${minor#v}"; then
      if [ "${DEVENV_ALLOW_DOWNGRADES:-0}" != 1 ]; then
        log_warn "the kubernetes repo is pinned to $cur, newer than the requested $minor."
        log_warn "  keeping $cur. Set DEVENV_ALLOW_DOWNGRADES=1 (and K8S_MINOR=$minor) to move back."
        return 1
      fi
      log_warn "downgrading the kubernetes repo from $cur to $minor on request"
    else
      log_info "moving the kubernetes repo from $cur to $minor"
    fi
  fi
  return 0
}

# repo_ensure_kubernetes MINOR
#   The pkgs.k8s.io repository for one minor (e.g. v1.34): the flat deb repo on
#   debian, the rpm-md tree core:/stable:/MINOR/rpm/ on redhat AND suse (zypper
#   reads it as it is). The signing key is per-minor but identical in practice; the
#   rpm tree's repodata/repomd.xml.key is byte-identical to the deb Release.key
#   (sha256 7627818c…e54d), so KUBERNETES_KEY_SHA256 pins both.
#   Detects a DOWNGRADE (the configured minor is newer than MINOR) and refuses unless
#   DEVENV_ALLOW_DOWNGRADES=1, because apt would then offer an older kubectl.
#   Forces one `pkg_update` when the source changed.
#   arch -> 78: modules/35-kubernetes.sh installs the distribution's kubectl and
#   reports its minor against MINOR.
repo_ensure_kubernetes() {
  local minor=${1:?repo_ensure_kubernetes: MINOR required}
  case $minor in v[0-9]*.[0-9]*) ;; *)
    log_error "repo_ensure_kubernetes: MINOR must look like v1.34, got '$minor'"
    return 1
    ;;
  esac
  local base key cur dir
  case ${OS_FAMILY:-} in
    debian | '')
      base="https://pkgs.k8s.io/core:/stable:/$minor/deb/"
      cur=$(_repo_k8s_current "$SOURCES_DIR/kubernetes.sources" "$SOURCES_DIR/kubernetes.list")
      _repo_k8s_moving "$cur" "$minor" || return 0
      key=$(repo_key kubernetes "${base}Release.key" asc --sha256 "${KUBERNETES_KEY_SHA256:-}") || return 1
      repo_add_flat kubernetes "$base" "$key" || return 1
      ;;
    redhat | suse)
      base="https://pkgs.k8s.io/core:/stable:/$minor/rpm/"
      dir=$(_repo_rpm_dir) || return 1
      cur=$(_repo_k8s_current "$dir/kubernetes.repo")
      _repo_k8s_moving "$cur" "$minor" || return 0
      repo_rpm_published "$base" || {
        log_warn "pkgs.k8s.io publishes no rpm tree for $minor"
        return 78
      }
      key=$(repo_key kubernetes "${base}repodata/repomd.xml.key" rpm \
        --sha256 "${KUBERNETES_KEY_SHA256:-}") || return 1
      repo_add_rpm kubernetes "Kubernetes $minor" "$base" "$key" 1 || return 1
      ;;
    *)
      _repo_rpm_family kubernetes || return 78
      ;;
  esac
  if [ "${DEVENV_CHANGED_LAST:-0}" = 1 ]; then pkg_update --force; fi
  return 0
}

# repo_ensure_github_cli
#   debian  suite `stable`, binary key (see _repo_github_cli_deb).
#   redhat, suse  cli.github.com/packages/rpm, the tree the vendor's own
#           gh-cli.repo names. Its key is the ARMORED githubcli-archive-keyring.asc
#           — a different file from the apt .gpg (and `rpm --import` takes armor
#           only), so it has its own pin, GITHUB_CLI_RPM_KEY_SHA256. It holds two
#           keys: the 2022 one, expired since 2026-09-05 (rpm 4.19+ warns about it
#           on import), and the 2026 one that signs the repomd.xml today.
#   arch -> 78: the distribution's `github-cli` (packages.map: gh -> github-cli).
repo_ensure_github_cli() {
  case ${OS_FAMILY:-} in
    debian | '') _repo_github_cli_deb ;;
    *)
      _repo_rpm_family github-cli || return 78
      local uri="https://cli.github.com/packages" key
      key=$(repo_key github-cli "$uri/githubcli-archive-keyring.asc" rpm \
        --sha256 "${GITHUB_CLI_RPM_KEY_SHA256:-}") || return 1
      repo_add_rpm github-cli 'packages for the GitHub CLI' "$uri/rpm" "$key" 1
      ;;
  esac
}

# _repo_github_cli_deb   (private)
#   Suite is literally `stable`, so one identical line on both distributions.
#   The key is BINARY (kind bin) — one of only two vendors that publish one.
#   Also removes the /usr/share/keyrings copy the vendor's own instructions create,
#   so there is exactly one trusted copy.
_repo_github_cli_deb() {
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
#   debian  the suite probe and the K12 map (see _repo_azure_cli_deb).
#   redhat  Microsoft's per-release product repository,
#           packages.microsoft.com/rhel/<major>/prod/ — the one its
#           packages-microsoft-prod.rpm configures — narrowed with
#           includepkgs=azure-cli to the one package the apt source carries, so a
#           dnf upgrade never swaps a distribution package for a Microsoft build.
#           yumrepos/azure-cli, the older instruction, holds el7 builds only.
#           EL 9 is signed with microsoft.asc (the apt key, AZURE_CLI_KEY_SHA256);
#           EL 10 with microsoft-2025.asc, which has its own pin
#           (AZURE_CLI_2025_KEY_SHA256). Fedora: Microsoft builds no azure-cli -> 78.
#   suse, arch -> 78.
#   78 sends modules/45-cloud.sh to `uv tool install azure-cli` (plan D6).
repo_ensure_azure_cli() {
  case ${OS_FAMILY:-} in
    debian | '') _repo_azure_cli_deb ;;
    redhat)
      local uri keyname keyurl pin key
      if [ "${OS_DISTRO:-}" = fedora ]; then
        log_skip "azure-cli: Microsoft builds no azure-cli for Fedora"
        return 78
      fi
      uri="https://packages.microsoft.com/rhel/${OS_VERSION_MAJOR:-}/prod/"
      repo_rpm_published "$uri" || {
        log_warn "packages.microsoft.com publishes no rhel/${OS_VERSION_MAJOR:-?} repository"
        return 78
      }
      if [ "${OS_VERSION_MAJOR:-0}" -ge 10 ] 2>/dev/null; then
        keyname=microsoft-2025 keyurl=https://packages.microsoft.com/keys/microsoft-2025.asc
        pin=${AZURE_CLI_2025_KEY_SHA256:-}
      else
        keyname=microsoft keyurl=https://packages.microsoft.com/keys/microsoft.asc
        pin=${AZURE_CLI_KEY_SHA256:-}
      fi
      key=$(repo_key "$keyname" "$keyurl" rpm --sha256 "$pin") || return 1
      repo_add_rpm azure-cli 'Azure CLI (Microsoft Production)' "$uri" "$key" 1 includepkgs=azure-cli
      ;;
    *)
      log_skip "azure-cli: Microsoft publishes no ${OS_FAMILY} build of azure-cli"
      return 78
      ;;
  esac
}

# _repo_azure_cli_deb   (private)
#   packages.microsoft.com does not publish every Debian suite (trixie is a verified
#   404). Order: use this box's own codename when it is actually published, else the
#   K12 ABI map, else 78 so the module can fall back to `uv tool install azure-cli`.
#   K12: trixie/forky/plucky/questing -> NOBLE, not bookworm. trixie ships libssl3t64
#   and glibc 2.41, so the bookworm build's `Depends: libssl3` is unsatisfiable while
#   the noble build's libssl3t64 / glibc >= 2.38 requirement is satisfied.
#   correctness C21: the probe runs first, so the static map only has to cover the
#   suites that are genuinely missing.
_repo_azure_cli_deb() {
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
#   debian  suite `generic` (see _repo_trivy_deb).
#   redhat, suse  get.trivy.dev/rpm/releases/$basearch/ (it answers 302 to
#           aquasecurity.github.io/trivy-repo, as the deb tree does). The rpm
#           public.key is byte-identical to the deb one (sha256 067f4782…cb39), so
#           TRIVY_KEY_SHA256 pins both. Aqua signs the packages but publishes no
#           repomd.xml.asc (a verified 404), so repo_gpgcheck is off and gpgcheck on.
#   arch -> 78: the distribution's own `trivy`.
repo_ensure_trivy() {
  case ${OS_FAMILY:-} in
    debian | '') _repo_trivy_deb ;;
    *)
      _repo_rpm_family trivy || return 78
      local uri="https://get.trivy.dev/rpm" key
      repo_rpm_published "$uri/releases/${OS_ARCH_RPM:-}" || {
        log_warn "trivy publishes no rpm tree for ${OS_ARCH_RPM:-this architecture}"
        return 78
      }
      key=$(repo_key trivy "$uri/public.key" rpm --sha256 "${TRIVY_KEY_SHA256:-}") || return 1
      # shellcheck disable=SC2016  # $basearch is the package manager's variable, written verbatim
      repo_add_rpm trivy 'Trivy repository' "$uri"'/releases/$basearch/' "$key" 0
      ;;
  esac
}

# _repo_trivy_deb   (private)
#   The suite is literally `generic`, so this renders one identical line on Debian
#   and Ubuntu with no codename logic at all.
_repo_trivy_deb() {
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
