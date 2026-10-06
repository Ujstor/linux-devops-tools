# shellcheck shell=bash
# lib/net.sh — downloads, checksums and GitHub-release installs.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
# SPEC 5.3.6 calls this file `github.sh`; the FUNCTION NAMES below are unchanged.
# It is named net.sh because it also owns the generic download path, the checksum
# helpers and `sh_installer_run`, none of which are GitHub-specific.
#
# ============================================================================
# THE TAG / VERSION RULE  (MUST-FIX C7, correctness C9) — defined ONCE, here.
#
#   Every *_VERSION in versions.env is the UPSTREAM RELEASE TAG, verbatim, in the
#   project's own form.  dive tags carry a `v` (v0.13.1); delta and fastfetch do
#   not (0.18.2, 2.68.1).  Do not "normalise" a pin.
#
#   Inside an ASSET PATTERN:
#       {tag}      the resolved tag, verbatim                  v0.13.1   kustomize/v5.8.1
#       {version}  the tag with a leading `v` removed, and any
#                  component prefix stripped                   0.13.1    5.8.1
#   So the dive asset is  dive_{version}_linux_{arch_dpkg}.deb  and the download
#   URL is  .../download/{tag}/<asset>.  One rule, applied everywhere.
#
#   Other tokens:
#       {os}       linux        {Os}        Linux      (k9s ships BOTH spellings)
#       {arch}     = {arch_go}  {arch_go}   amd64 arm64 arm 386 …
#       {arch_dpkg} amd64 arm64 armhf i386 …    (dpkg names — .deb assets)
#       {arch_uname} x86_64 aarch64 …           {arch_rust} x86_64 aarch64 armv7 …
#   An unexpanded `{` after substitution is a hard failure, so a typo is loud.
# ============================================================================
#
# MUST-FIX C6: every release lookup FOLLOWS REDIRECTS (`-L`) and asserts that the
# final URL really is a release tag. vmware-tanzu/velero and dbrgn/tealdeer are
# both renamed repos whose Location has no /releases/tag/ in it; without the
# assertion the literal string "latest" is cached and fed into every download URL.
#
# MUST-FIX F14: a `curl | bash` vendor installer goes through `sh_installer_run`,
# which can verify a pinned sha256 of the SCRIPT and warns loudly when it cannot.
# Prefer gh_release_install with a published checksum wherever one exists.
#
# Spec 002 FR-015: a release asset that is a distribution PACKAGE (.deb, .rpm) goes
# through `pkg_release_install`, which hands it to this family's package manager —
# and never, on any family, to gh_release_install as if it were the executable.

[ -n "${_DEVENV_NET:-}" ] && return 0
_DEVENV_NET=1

DEVENV_CURL_OPTS=(--proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --max-time 300 --location)

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

# download URL DEST
#   Fetches URL to DEST atomically (temp file, then mv). Follows redirects, fails on
#   HTTP >= 400 (`-f` is mandatory: the old repo piped 404 HTML pages into bash).
#   Falls back to wget --https-only when curl is absent.
#   Honours --dry-run through `run`: nothing is fetched and 0 is returned.
#   Returns non-zero when the transfer fails.
download() {
  local url=${1:?download: URL required} dest=${2:?download: DEST required} tmp
  ensure_dir "$(dirname -- "$dest")" || return 1
  if is_dry_run; then
    log_dryrun "download $url -> $dest"
    return 0
  fi
  tmp="${dest}.part.$$"
  if have curl; then
    # --retry-all-errors ONLY here, never on the HEAD probes: a large asset download
    # is exactly where a transient transport error costs a whole module, and
    # `--retry` on its own does not cover curl-level failures. The container matrix
    # lost a `cloud` run to
    #     curl: (92) HTTP/2 stream 3 was not closed cleanly: INTERNAL_ERROR
    # halfway through an 18 MB .deb from gitlab.com, which one retry would have
    # ridden out. The probes keep the plain option set, so a 404 while walking a
    # vendor's suite ladder still fails immediately instead of four times slowly.
    # The option is only added when this curl knows it (7.71+; every target is far
    # newer, but an unknown option would make curl exit 2 and fail every download).
    # The help text is read whole: a `| grep -q` exits at its first match, curl
    # dies of SIGPIPE and pipefail turns a found option into "not supported".
    local -a retry_opt=()
    local help
    help=$(curl --help all 2>/dev/null) || help=''
    if [[ $help == *--retry-all-errors* ]]; then
      retry_opt=(--retry-all-errors)
    fi
    run curl -fsS "${DEVENV_CURL_OPTS[@]}" ${retry_opt[0]+"${retry_opt[@]}"} \
      -o "$tmp" -- "$url" || {
      rm -f -- "$tmp"
      return 1
    }
  elif have wget; then
    run wget -q --https-only --tries=3 -O "$tmp" -- "$url" || {
      rm -f -- "$tmp"
      return 1
    }
  else
    log_error "neither curl nor wget is available"
    return 1
  fi
  run mv -f -- "$tmp" "$dest"
}

# http_ok URL
#   Returns 0 when a HEAD of URL, AFTER following redirects, answers 2xx; 1 when
#   the server says the thing does not exist (404/410); 2 when it could not be
#   told — a timeout, a 5xx, a 429 or a rate-limit 403. Callers that SKIP on a
#   missing asset must skip on 1 only: a 2 taken for "not published" made a
#   network blip a silent skip, and the next run then installed it (dive on
#   ubuntu:24.04, pipeline 65170). Boolean callers are unaffected.
#   MUST-FIX C6: pkgs.k8s.io answers 302, so a 200-only test is wrong.
#   Read-only: runs under --dry-run. Returns 2 when curl is absent.
http_ok() {
  local url=${1:?http_ok: URL required} code
  have curl || return 2
  code=$(curl -sSIL "${DEVENV_CURL_OPTS[@]}" --max-time 20 -o /dev/null -w '%{http_code}' -- "$url" 2>/dev/null) || code=''
  case $code in
    2??) return 0 ;;
    404 | 410) return 1 ;;
    *) return 2 ;;
  esac
}

# http_body URL
#   Prints the body of URL on stdout. Read-only; runs under --dry-run.
#   Returns non-zero on any HTTP or transport error.
http_body() {
  local url=${1:?http_body: URL required}
  have curl || return 1
  curl -fsSL "${DEVENV_CURL_OPTS[@]}" --max-time 60 -- "$url" 2>/dev/null
}

# _urldecode STRING  (private) — decodes %XX escapes (tags such as kustomize%2Fv5.8.1).
_urldecode() {
  local s=$1
  case $s in *%*) printf '%b\n' "${s//%/\\x}" ;; *) printf '%s\n' "$s" ;; esac
}

# tag_to_version TAG
#   Applies THE rule above: strips any component prefix and one leading `v`.
#   kustomize/v5.8.1 -> 5.8.1 ; v0.13.1 -> 0.13.1 ; 2.68.1 -> 2.68.1. Always 0.
tag_to_version() {
  local t=${1-}
  t=${t##*/}
  printf '%s\n' "${t#v}"
}

# sha256_of FILE / verify_sha256 FILE EXPECTED  — sha256_of lives in lib/fs.sh.

# verify_sha256 FILE EXPECTED
#   Returns 0 when FILE's sha256 equals EXPECTED (case-insensitive), 1 otherwise or
#   when the digest cannot be computed. Logs the mismatch. Read-only.
verify_sha256() {
  local f=${1:?verify_sha256: FILE required} want=${2:?verify_sha256: EXPECTED required} got
  got=$(sha256_of "$f") || {
    log_error "cannot compute sha256 of $f"
    return 1
  }
  want=${want,,}
  got=${got,,}
  if [ "$got" != "$want" ]; then
    log_error "checksum mismatch for $f"
    log_error "  expected $want"
    log_error "  got      $got"
    return 1
  fi
  log_debug "sha256 ok: $f"
  return 0
}

# checksum_lookup SUMFILE ASSET
#   Prints the digest recorded for ASSET in a `<sum>  <name>` checksum file.
#   Tolerates the `<sum> *<name>` (binary-mode) form and full paths in the name
#   column. Returns 1 when the asset is not listed.
checksum_lookup() {
  local sumfile=${1:?checksum_lookup: SUMFILE required} asset=${2:?checksum_lookup: ASSET required}
  [ -r "$sumfile" ] || return 1
  awk -v want="$asset" '
    {
      name = $2
      sub(/^\*/, "", name)
      sub(/^.*\//, "", name)
      if (name == want) { print $1; found = 1; exit }
    }
    END { if (!found) exit 1 }
  ' "$sumfile"
}

# bin_version BIN [VERSION_ARGS] [REGEX]
#   Prints the installed version of BIN, or nothing.
#   VERSION_ARGS defaults to "--version" (a single string, word-split on purpose:
#   pass 'version --short' for helm). REGEX defaults to a dotted numeric with an
#   optional leading v. Returns 1 when BIN is absent or prints no version.
#   Read-only: runs under --dry-run.
bin_version() {
  local bin=${1:?bin_version: BIN required} args=${2:---version} re=${3:-}
  local out v
  have "$bin" || return 1
  [ -n "$re" ] || re='v?[0-9]+\.[0-9]+(\.[0-9]+)?'
  # shellcheck disable=SC2086   # deliberate word-splitting: VERSION_ARGS is a string
  out=$("$bin" $args 2>&1) || out=${out:-}
  v=$(printf '%s\n' "$out" | grep -oE "$re" | head -n1) || v=''
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# ---------------------------------------------------------------------------
# Release-tag resolution
# ---------------------------------------------------------------------------

# _gh_cache_file REPO [FILTER]   (private)
_gh_cache_file() {
  local key=${1//\//__}
  if [ -n "${2:-}" ]; then
    key="${key}__$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"
  fi
  printf '%s\n' "${DEVENV_CACHE:?DEVENV_CACHE unset}/tags/$key"
}

# gh_latest_tag REPO [TAG_REGEX]
#   Prints the newest release TAG of a GitHub repo.
#   Mechanism: HEAD https://github.com/REPO/releases/latest, FOLLOW redirects, and
#   assert the effective URL matches /releases/tag/<tag>. No api.github.com, so no
#   60-requests-per-hour rate limit (D14).
#   MUST-FIX C6: without -L a renamed repo (velero-io/velero, tealdeer-rs/tealdeer)
#   yields the literal string "latest"; without the assertion that string is cached
#   and used as a tag. This function returns 1 and says what it saw instead.
#   TAG_REGEX, when given, selects from the repo's releases.atom feed instead —
#   mandatory for kubernetes-sigs/kustomize (component-prefixed tags) and for
#   yonahd/kor (whose `latest` is the Helm-chart tag).
#   Cached for DEVENV_TAG_TTL seconds (default 21600 = 6 h) under $DEVENV_CACHE/tags.
#   Read-only; safe under --dry-run (it will use the cache and otherwise return 1).
gh_latest_tag() {
  local repo=${1:?gh_latest_tag: REPO required} filter=${2:-}
  local cache eff tag age now
  cache=$(_gh_cache_file "$repo" "$filter")
  if [ -f "$cache" ]; then
    now=$(date +%s)
    age=$(stat -c %Y -- "$cache" 2>/dev/null || printf '0\n')
    if [ $((now - age)) -lt "${DEVENV_TAG_TTL:-21600}" ]; then
      cat "$cache"
      return 0
    fi
  fi
  if is_dry_run; then
    log_dryrun "resolve latest tag of $repo (cache is cold)"
    return 1
  fi
  have curl || {
    log_error "curl is required to resolve the latest release of $repo"
    return 1
  }

  if [ -n "$filter" ]; then
    tag=$(http_body "https://github.com/$repo/releases.atom" \
      | grep -oE 'Repository/[0-9]+/[^<]+' | sed 's|^Repository/[0-9]*/||' \
      | grep -E "$filter" | head -n1) || tag=''
    if [ -z "$tag" ]; then
      log_error "no release tag of $repo matched /$filter/"
      return 1
    fi
  else
    eff=$(curl -sSIL "${DEVENV_CURL_OPTS[@]}" --max-time 30 -o /dev/null \
      -w '%{url_effective}' -- "https://github.com/$repo/releases/latest" 2>/dev/null) || eff=''
    case $eff in
      */releases/tag/*) tag=$(_urldecode "${eff##*/releases/tag/}") ;;
      '')
        log_error "could not reach https://github.com/$repo/releases/latest"
        return 1
        ;;
      *)
        log_error "$repo/releases/latest did not resolve to a release tag."
        log_error "  final URL: $eff"
        log_error "  the repository may have been renamed, or it has no releases."
        return 1
        ;;
    esac
  fi
  [ -n "$tag" ] || return 1
  ensure_dir "$(dirname -- "$cache")" >/dev/null 2>&1 || true
  printf '%s\n' "$tag" >"$cache" 2>/dev/null || true
  printf '%s\n' "$tag"
}

# gh_resolve_version REPO VERSION [TAG_REGEX]
#   Prints the tag to use. VERSION is returned verbatim unless it is the sentinel
#   `latest`, in which case gh_latest_tag resolves it. Returns 1 when `latest`
#   cannot be resolved (offline, or a dry run with a cold cache).
gh_resolve_version() {
  local repo=${1:?gh_resolve_version: REPO required} version=${2:?gh_resolve_version: VERSION required}
  local filter=${3:-}
  case $version in
    latest) gh_latest_tag "$repo" "$filter" ;;
    *) printf '%s\n' "$version" ;;
  esac
}

# expand_asset PATTERN TAG
#   Prints PATTERN with every {token} above substituted for TAG and this machine's
#   architecture. Returns 1 (with an error) when an unrecognised {token} survives.
expand_asset() {
  local pat=${1:?expand_asset: PATTERN required} tag=${2:?expand_asset: TAG required} ver
  ver=$(tag_to_version "$tag")
  pat=${pat//'{tag}'/$tag}
  pat=${pat//'{version}'/$ver}
  pat=${pat//'{os}'/linux}
  pat=${pat//'{Os}'/Linux}
  pat=${pat//'{arch_dpkg}'/${OS_ARCH_DPKG:-}}
  pat=${pat//'{arch_go}'/${OS_ARCH_GO:-}}
  pat=${pat//'{arch_uname}'/${OS_ARCH_UNAME:-}}
  pat=${pat//'{arch_rust}'/${OS_ARCH_RUST:-}}
  pat=${pat//'{arch}'/${OS_ARCH_GO:-}}
  case $pat in
    *'{'*)
      log_error "unknown token in asset pattern: $pat"
      return 1
      ;;
  esac
  printf '%s\n' "$pat"
}

# ---------------------------------------------------------------------------
# The download cache
# ---------------------------------------------------------------------------
#
# $DEVENV_CACHE/dl survives re-runs, so a second install of the same release is
# offline. Every cached file is named after its release TAG as well as its asset,
# because a lot of assets carry no version at all — k3d-linux-amd64,
# k9s_linux_amd64.deb, yq_linux_amd64, nvim-linux-x86_64.tar.gz. A cache keyed on
# the asset name alone hands a pin bump the PREVIOUS release: a checksum-verified
# install then fails its digest on every run until someone empties the cache, and
# an unverified one quietly reinstalls the old version and reports the new one.

# net_cache_path TAG ASSET
#   Prints $DEVENV_CACHE/dl/<TAG>.<ASSET>, with every `/` in TAG (the component
#   prefix of kustomize/v5.8.1) made a `_`. Pure: creates nothing. Always 0.
net_cache_path() {
  local tag=${1:?net_cache_path: TAG required} asset=${2:?net_cache_path: ASSET required}
  printf '%s/dl/%s.%s\n' "${DEVENV_CACHE:?DEVENV_CACHE unset}" "${tag//\//_}" "$asset"
}

# net_cache_prune KEEP ASSET
#   Deletes every other cached release of ASSET — <any tag>.ASSET beside KEEP —
#   and the version-less ASSET an older cache layout left there. Call it once KEEP
#   has been downloaded: installs are version-gated, so an older release is never
#   read again. Only regular files in KEEP's own directory are touched. Honours
#   --dry-run through `run`. Always 0.
net_cache_prune() {
  local keep=${1:?net_cache_prune: KEEP required} asset=${2:?net_cache_prune: ASSET required}
  local dir f
  dir=$(dirname -- "$keep")
  for f in "$dir/$asset" "$dir"/*."$asset"; do
    [ "$f" != "$keep" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    run rm -f -- "$f" || true
  done
  return 0
}

# ---------------------------------------------------------------------------
# Installers
# ---------------------------------------------------------------------------

# _net_extract ARCHIVE DESTDIR   (private) — tar.gz/tgz/tar.xz/tar.bz2/zip/plain.
_net_extract() {
  local ar=$1 dir=$2
  case $ar in
    *.tar.gz | *.tgz) run tar -xzf "$ar" -C "$dir" ;;
    *.tar.xz | *.txz) run tar -xJf "$ar" -C "$dir" ;;
    *.tar.bz2) run tar -xjf "$ar" -C "$dir" ;;
    *.tar) run tar -xf "$ar" -C "$dir" ;;
    *.zip)
      have unzip || {
        log_error "unzip is required to unpack $ar"
        return 1
      }
      run unzip -q -o "$ar" -d "$dir"
      ;;
    *)
      run cp -- "$ar" "$dir/"
      ;;
  esac
}

# gh_release_install REPO ASSET_PATTERN BIN VERSION [OPTS…]
#   Installs a binary from a GitHub release.
#     REPO           owner/name
#     ASSET_PATTERN  the release asset, using the token rule at the top of this file
#     BIN            the resulting command name (used for the version short-circuit)
#     VERSION        a pin from versions.env, or the sentinel `latest`
#   OPTS:
#     --checksum-asset NAME   asset holding `<sum>  <file>` lines (e.g. checksums.txt)
#     --checksum-url URL      the same, at an explicit URL
#     --sha256 SUM            the digest of THIS asset, verbatim
#     --no-verify             install without a checksum. Prints a loud warning.
#     --no-verify-reason TEXT why no checksum exists — REQUIRED with --no-verify so
#                             the exception is documented at the call site (F14/D14).
#     --archive-path GLOB     path of the binary inside the archive (default: BIN)
#     --strip N               tar --strip-components
#     --dest DIR              install directory (default /usr/local/bin)
#     --version-cmd 'ARGS'    arguments that make BIN print its version
#     --version-regex RE      how to find the version in that output
#     --tag-filter RE         passed to gh_latest_tag when VERSION is `latest`
#     --mode MODE             install mode (default 0755)
#     --base-url URL          download the asset (and a --checksum-asset) from
#                             URL/<asset> instead of the GitHub release. Tokens
#                             expand, so a release that does not live on GitHub
#                             is spelled 'https://releases.hashicorp.com/terraform/{version}'
#                             or '…/gitlab-org/cli/-/releases/{tag}/downloads'.
#                             REPO then only resolves `latest` and labels messages.
#   Behaviour:
#     0. resolve the tag; if BIN already reports that version -> return 0, NO download
#     1. download the asset (and its checksum) into $DEVENV_CACHE/dl, which survives
#        re-runs so a second install is offline
#     2. verify sha256; a MISSING checksum is a hard failure unless --no-verify
#     3. extract, locate the binary, install it (run_sudo when DEST needs root)
#     4. `changed "BIN VERSION"`
#   Returns 0 on success, 78 when the upstream publishes no asset for this
#   architecture (the module logs a skip — C4: never a silent no-op), 1 on failure.
#   Under --dry-run it resolves and reports, and downloads nothing.
gh_release_install() {
  local repo=${1:?gh_release_install: REPO required}
  local pattern=${2:?gh_release_install: ASSET_PATTERN required}
  local bin=${3:?gh_release_install: BIN required}
  local version=${4:?gh_release_install: VERSION required}
  shift 4
  local csum_asset='' csum_url='' sha='' no_verify=0 no_verify_reason='' base=''
  local apath='' strip='' dest=/usr/local/bin vcmd='--version' vre='' tagfilter='' mode=0755
  while [ $# -gt 0 ]; do
    case $1 in
      --base-url) base=$2 ;;
      --checksum-asset) csum_asset=$2 ;;
      --checksum-url) csum_url=$2 ;;
      --sha256) sha=$2 ;;
      --no-verify)
        no_verify=1
        shift
        continue
        ;;
      --no-verify-reason) no_verify_reason=$2 ;;
      --archive-path) apath=$2 ;;
      --strip) strip=$2 ;;
      --dest) dest=$2 ;;
      --version-cmd) vcmd=$2 ;;
      --version-regex) vre=$2 ;;
      --tag-filter) tagfilter=$2 ;;
      --mode) mode=$2 ;;
      *)
        log_error "gh_release_install: unknown option $1"
        return 1
        ;;
    esac
    shift 2
  done

  local tag ver asset url
  tag=$(gh_resolve_version "$repo" "$version" "$tagfilter") || {
    log_warn "could not resolve a release tag for $repo ($version) — skipping $bin"
    return 78
  }
  ver=$(tag_to_version "$tag")

  # 0. version gate — an already-correct install costs zero network.
  local cur
  if cur=$(bin_version "$bin" "$vcmd" "$vre"); then
    if [ "${cur#v}" = "$ver" ]; then
      log_skip "$bin is already $ver"
      return 0
    fi
    log_info "$bin $cur -> $ver"
  fi

  asset=$(expand_asset "$pattern" "$tag") || return 1
  if [ -n "$base" ]; then
    base=$(expand_asset "$base" "$tag") || return 1
  else
    base="https://github.com/$repo/releases/download/$tag"
  fi
  url="$base/$asset"

  if is_dry_run; then
    log_dryrun "install $bin $ver from $url -> $dest"
    changed "$bin $ver"
    return 0
  fi

  local hrc=0
  http_ok "$url" || hrc=$?
  case $hrc in
    0) ;;
    1)
      log_warn "no asset '$asset' in $repo $tag (architecture ${OS_ARCH_DPKG:-unknown}) — skipping $bin"
      return 78
      ;;
    *)
      log_error "$bin: could not reach $url (network or server error) — not installed this run"
      return 1
      ;;
  esac

  local dl="${DEVENV_CACHE:?}/dl" ar
  ensure_dir "$dl" || return 1
  ar=$(net_cache_path "$tag" "$asset")
  if [ ! -f "$ar" ]; then
    download "$url" "$ar" || return 1
    net_cache_prune "$ar" "$asset"
  fi

  # 2. checksum. A mismatch also drops the cached copy, so the next run downloads
  # again instead of re-verifying the same bad file for ever.
  if [ -n "$sha" ]; then
    verify_sha256 "$ar" "$sha" || {
      run rm -f -- "$ar" || true
      return 1
    }
  elif [ -n "$csum_asset" ] || [ -n "$csum_url" ]; then
    local cfile curl_target expected
    if [ -z "$csum_url" ]; then
      csum_asset=$(expand_asset "$csum_asset" "$tag") || return 1
      curl_target="$base/$csum_asset"
    else
      csum_asset=$(basename -- "$csum_url")
      curl_target=$(expand_asset "$csum_url" "$tag") || return 1
    fi
    cfile=$(net_cache_path "$tag" "$csum_asset")
    download "$curl_target" "$cfile" || {
      log_error "could not fetch the checksum file for $bin ($curl_target)"
      return 1
    }
    if expected=$(checksum_lookup "$cfile" "$asset"); then
      :
    elif [ "$(wc -w <"$cfile")" -le 2 ]; then
      expected=$(awk '{print $1; exit}' "$cfile")
    else
      log_error "$asset is not listed in $csum_asset"
      return 1
    fi
    verify_sha256 "$ar" "$expected" || {
      run rm -f -- "$ar" || true
      return 1
    }
  elif [ "$no_verify" = 1 ]; then
    log_warn "installing $bin $ver WITHOUT a checksum: ${no_verify_reason:-no reason given at the call site}"
    log_warn "  source: $url"
  else
    log_error "$bin: no checksum source given. Pass --checksum-asset/--checksum-url/--sha256,"
    log_error "  or --no-verify --no-verify-reason '<why this project publishes none>'."
    return 1
  fi

  # 3. extract + install, in a work directory that is removed as soon as this
  #    one tool is in place. The archive itself stays in $DEVENV_CACHE/dl (disk);
  #    the unpacked copy is on $TMPDIR, a tmpfs at half the RAM on Arch, Fedora and
  #    Debian 13, and kept until the module ended it filled it: the kubernetes
  #    module unpacks a dozen tools, velero alone 150 MB, into 980 MB (Arch lab
  #    guest, pipeline 65219).
  local work rc=0
  work=$(devenv_tmpdir) || return 1
  _net_place "$ar" "$asset" "$work" "$strip" "$apath" "$bin" "$dest" "$mode" "$ver" || rc=$?
  rm -rf -- "$work"
  return "$rc"
}

# _net_place ARCHIVE ASSET WORK STRIP APATH BIN DEST MODE VERSION   (private)
#   gh_release_install's last step: unpack ARCHIVE into WORK (or copy a bare
#   binary there), find BIN in it, install it to DEST/BIN with MODE, and record
#   the change. The caller owns WORK. Returns 1 on any failure.
_net_place() {
  local ar=$1 asset=$2 work=$3 strip=$4 apath=$5 bin=$6 dest=$7 mode=$8 ver=$9 found
  case $asset in
    *.tar.* | *.tgz | *.txz | *.tar | *.zip)
      if [ -n "$strip" ]; then
        case $asset in
          *.zip)
            log_error "--strip is not supported for zip assets ($asset)"
            return 1
            ;;
        esac
        run tar -xaf "$ar" -C "$work" --strip-components="$strip" || return 1
      else
        _net_extract "$ar" "$work" || return 1
      fi
      ;;
    *)
      run cp -- "$ar" "$work/$bin" || return 1
      ;;
  esac
  found=$(find "$work" -type f -name "${apath:-$bin}" -print -quit 2>/dev/null) || found=''
  if [ -z "$found" ] && [ -n "$apath" ]; then
    found=$(find "$work" -type f -path "*/$apath" -print -quit 2>/dev/null) || found=''
  fi
  if [ -z "$found" ]; then
    found=$(find "$work" -maxdepth 2 -type f -name "$bin*" -print -quit 2>/dev/null) || found=''
  fi
  [ -n "$found" ] || {
    log_error "could not find '${apath:-$bin}' inside $asset"
    return 1
  }

  ensure_dir "$dest" || return 1
  # fs_install: the same privilege gate as before, and the SELinux label of a bin
  # directory restored afterwards (plan D9) — a no-op where SELinux is not on.
  fs_install "$found" "$dest/$bin" "$mode" || return 1
  log_success "installed $bin $ver -> $dest/$bin"
  changed "$bin $ver"
  return 0
}

# installed_pkg_version PKG
#   Prints the version of PKG as this machine's package database records it:
#   dpkg's ${Version} on apt (epoch and revision included — exactly what
#   deb_release_install always compared), rpm's %{VERSION}-%{RELEASE} on dnf and
#   zypper. Returns 1 when PKG is not installed, and on pacman, where everything
#   this library installs from a release is an archive gated on the binary's own
#   version instead.
#   A query, so it lives here beside its callers rather than behind the pkg_*
#   backends, which own every command that changes the package set.
#   Read-only; runs under --dry-run.
installed_pkg_version() {
  local pkg=${1:?installed_pkg_version: PKG required} v
  case ${OS_PKG_MGR:-apt} in
    apt)
      have dpkg-query || return 1
      v=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null) || return 1
      ;;
    dnf | zypper)
      have rpm || return 1
      v=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# pkg_release_install REPO PKG VERSION --deb PAT [--rpm PAT] [--tarball PAT] [OPTS…]
#   Installs a tool that a release publishes as a distribution PACKAGE, through this
#   machine's own package mechanism (spec 002 FR-015, plan D7). It replaces
#   deb_release_install.
#     apt          the .deb (--deb), exactly as deb_release_install did (FR-008)
#     dnf, zypper  the .rpm (--rpm) through pkg_install_local
#     pacman       the archive (--tarball): pacman installs no foreign package
#   When the package asset this family takes is not in the release — no --rpm, or
#   a 404 — the archive is installed instead, IF the call site named one.
#   NOTHING ELSE IS EVER TRIED. The old fallbacks are gone, both of them: with no
#   dpkg the .deb itself went to gh_release_install and was installed as
#   /usr/local/bin/<tool> (spec 002 P3 — a "successful" run that leaves a binary
#   that cannot execute), and a 404'd .deb became a guessed `${pattern%.deb}.tar.gz`
#   that is wrong for grpcurl (its archive is linux_x86_64, its packages
#   linux_amd64) and for k9s (k9s_Linux_… against k9s_linux_…). Every archive name
#   is now written at the call site and checked against the pinned release.
#     REPO     owner/name on GitHub: tag resolution, and the default download base
#     PKG      the name the package database knows (openbao — not bao)
#     VERSION  a pin from versions.env, or `latest`
#   OPTS:
#     --deb PAT, --rpm PAT, --tarball PAT
#                       asset patterns, with the token rule at the top of this file
#     --bin NAME        the command, when it differs from PKG. MUST-FIX C7: OpenBao's
#                       package is `openbao` and its command `bao`; getting this
#                       wrong re-installs on every run. The archive installs it.
#     --base-url URL    as gh_release_install's: for a release not on GitHub (glab)
#     --checksum-asset, --checksum-url, --sha256, --no-verify, --no-verify-reason,
#     --tag-filter      as gh_release_install's; they apply to whichever asset is
#                       installed, so one checksum file must list all of them (each
#                       one used here was checked to)
#     --archive-path, --strip, --dest, --version-cmd, --version-regex, --mode
#                       passed to gh_release_install for the archive only
#   Package path: short-circuits on installed_pkg_version PKG matching {version},
#   so a converged box costs no network. idempotency F16: the package goes through
#   pkg_install_local — `apt-get install ./file.deb` on apt, which resolves
#   dependencies up front instead of `dpkg -i` + `apt-get -f install`.
#   Archive path: gh_release_install's own version gate on BIN.
#   Returns 0, 78 when the release has nothing this family can install (logged
#   here, with the reason — C4: never a silent no-op), or 1.
#   Under --dry-run it resolves and reports, and downloads nothing.
pkg_release_install() {
  local repo=${1:?pkg_release_install: REPO required}
  local pkg=${2:?pkg_release_install: PKG required}
  local version=${3:?pkg_release_install: VERSION required}
  shift 3
  local deb='' rpm='' tarball='' bin='' base='' tagfilter=''
  local sha='' csum_asset='' csum_url='' no_verify=0 no_verify_reason=''
  local verify=() archive=()
  while [ $# -gt 0 ]; do
    case $1 in
      --deb) deb=$2 ;;
      --rpm) rpm=$2 ;;
      --tarball) tarball=$2 ;;
      --bin) bin=$2 ;;
      --base-url) base=$2 ;;
      --tag-filter) tagfilter=$2 ;;
      --sha256)
        sha=$2
        verify+=("$1" "$2")
        ;;
      --checksum-asset)
        csum_asset=$2
        verify+=("$1" "$2")
        ;;
      --checksum-url)
        csum_url=$2
        verify+=("$1" "$2")
        ;;
      --no-verify)
        no_verify=1
        verify+=("$1")
        shift
        continue
        ;;
      --no-verify-reason)
        no_verify_reason=$2
        verify+=("$1" "$2")
        ;;
      --archive-path | --strip | --dest | --version-cmd | --version-regex | --mode)
        archive+=("$1" "$2")
        ;;
      *)
        log_error "pkg_release_install: unknown option $1"
        return 1
        ;;
    esac
    shift 2
  done
  [ -n "$deb" ] || {
    log_error "pkg_release_install: --deb is required (the asset the Debian family installs)"
    return 1
  }
  [ -n "$bin" ] || bin=$pkg

  local kind='' pattern=''
  case ${OS_PKG_MGR:-apt} in
    apt) kind=deb pattern=$deb ;;
    dnf | zypper) if [ -n "$rpm" ]; then kind=rpm pattern=$rpm; fi ;;
  esac

  local tag ver
  tag=$(gh_resolve_version "$repo" "$version" "$tagfilter") || {
    log_warn "could not resolve a release tag for $repo ($version) — skipping $pkg"
    return 78
  }
  ver=$(tag_to_version "$tag")
  if [ -n "$base" ]; then
    base=$(expand_asset "$base" "$tag") || return 1
  else
    base="https://github.com/$repo/releases/download/$tag"
  fi

  if [ -n "$kind" ]; then
    local installed asset url
    installed=$(installed_pkg_version "$pkg") || installed=''
    case $installed in
      "$ver" | "$ver"-* | *:"$ver" | *:"$ver"-*)
        log_skip "$pkg is already $ver"
        return 0
        ;;
    esac

    asset=$(expand_asset "$pattern" "$tag") || return 1
    url="$base/$asset"

    if is_dry_run; then
      if [ "$kind" = deb ]; then
        log_dryrun "install $pkg $ver from $url (dpkg)"
      else
        log_dryrun "install $pkg $ver from $url (rpm)"
      fi
      changed "$pkg $ver"
      return 0
    fi

    local hrc=0
    http_ok "$url" || hrc=$?
    if [ "$hrc" = 2 ]; then
      log_error "$pkg: could not reach $url (network or server error) — not installed this run"
      return 1
    fi
    if [ "$hrc" = 0 ]; then
      local prc=0
      _net_pkg_asset "$kind" "$pkg" "$ver" "$tag" "$base" "$asset" || prc=$?
      # 78 is pkg_install_local saying this family installs no package file at
      # all; the archive is then the install, as on pacman. Anything else stands.
      if [ "$prc" != 78 ] || [ -z "$tarball" ]; then return "$prc"; fi
      log_info "$pkg: this ${OS_PKG_MGR:-unknown} system takes no .$kind — installing the release archive"
    elif [ -n "$tarball" ]; then
      log_warn "no .$kind asset '$asset' in $repo $tag — falling back to the release archive"
    else
      log_warn "no .$kind asset '$asset' in $repo $tag, and no archive to fall back to — skipping $pkg"
      return 78
    fi
  fi

  if [ -z "$tarball" ]; then
    log_skip "$pkg: no asset of $repo $tag installs on ${OS_PKG_MGR:-this} systems (no package for it, and no usable archive)"
    return 78
  fi
  gh_release_install "$repo" "$tarball" "$bin" "$tag" --base-url "$base" \
    ${verify[0]+"${verify[@]}"} ${archive[0]+"${archive[@]}"}
}

# _net_pkg_asset KIND PKG VER TAG BASE ASSET   (private)
#   The package half of pkg_release_install, once the asset is known to exist:
#   download into the tag-keyed cache, verify with the caller's checksum options
#   (pkg_release_install's locals — sha, csum_asset, csum_url, no_verify,
#   no_verify_reason — read through bash's dynamic scope), install through
#   pkg_install_local, record the change. A digest mismatch drops the cached copy,
#   so the next run downloads again instead of re-verifying the same bad file.
#   Returns 0, 1, or 78 when pkg_install_local says this family takes no package
#   file at all (pacman) — the caller then installs the archive.
_net_pkg_asset() {
  local kind=$1 pkg=$2 ver=$3 tag=$4 base=$5 asset=$6
  local url="$base/$asset" dl="${DEVENV_CACHE:?}/dl" ar
  ensure_dir "$dl" || return 1
  # Keyed on the tag as well, for the reason at net_cache_path: k9s's packages, for
  # one, are k9s_linux_<arch>.{deb,rpm} in every release.
  ar=$(net_cache_path "$tag" "$asset")
  if [ ! -f "$ar" ]; then
    download "$url" "$ar" || return 1
    net_cache_prune "$ar" "$asset"
  fi

  if [ -n "$sha" ]; then
    verify_sha256 "$ar" "$sha" || {
      run rm -f -- "$ar" || true
      return 1
    }
  elif [ -n "$csum_asset" ] || [ -n "$csum_url" ]; then
    local cfile ctarget expected
    if [ -z "$csum_url" ]; then
      csum_asset=$(expand_asset "$csum_asset" "$tag") || return 1
      ctarget="$base/$csum_asset"
    else
      ctarget=$(expand_asset "$csum_url" "$tag") || return 1
      csum_asset=$(basename -- "$ctarget")
    fi
    cfile=$(net_cache_path "$tag" "$csum_asset")
    download "$ctarget" "$cfile" || return 1
    expected=$(checksum_lookup "$cfile" "$asset") || {
      log_error "$asset is not listed in $csum_asset"
      return 1
    }
    verify_sha256 "$ar" "$expected" || {
      run rm -f -- "$ar" || true
      return 1
    }
  elif [ "$no_verify" = 1 ]; then
    log_warn "installing $pkg $ver WITHOUT a checksum: ${no_verify_reason:-no reason given at the call site}"
    log_warn "  source: $url"
  else
    log_error "$pkg: no checksum source given (see gh_release_install's --no-verify contract)"
    return 1
  fi

  local irc=0
  pkg_install_local "$ar" || irc=$?
  case $irc in
    0) ;;
    78) return 78 ;;
    *) return 1 ;;
  esac
  log_success "installed $pkg $ver"
  changed "$pkg $ver"
  return 0
}

# sh_installer_run URL [OPTS…] [-- ARGS…]
#   Runs a vendor `curl | bash` installer as safely as it can be run (MUST-FIX F14).
#   OPTS:
#     --sha256 SUM     verify the SCRIPT's digest before executing it; refuse on
#                      mismatch. Use it whenever the vendor publishes a stable
#                      installer URL.
#     --reason TEXT    why a release binary + checksum is not used instead. Printed
#                      when no --sha256 is given, so every unpinned execution is
#                      documented at the call site.
#     --env K=V        exported into the installer's environment (repeatable)
#     --sudo           run the installer as root
#     --shell BIN      interpreter (default: bash)
#   ARGS after `--` are passed to the installer.
#   The script is fetched into `devenv_execdir` and the installer's own TMPDIR is
#   set to that directory, so a vendor script that downloads a binary and execs it
#   still works where /tmp is mounted noexec. A caller's own `--env TMPDIR=…`
#   overrides it.
#   Honours --dry-run: the script is neither fetched nor executed.
#   Returns the installer's exit status, or 1 on a download/verification failure.
sh_installer_run() {
  local url=${1:?sh_installer_run: URL required}
  shift
  local sha='' reason='' as_root_flag=0 shellbin=bash
  local envs=() iargs=()
  while [ $# -gt 0 ]; do
    case $1 in
      --sha256)
        sha=$2
        shift 2
        ;;
      --reason)
        reason=$2
        shift 2
        ;;
      --env)
        envs+=("$2")
        shift 2
        ;;
      --sudo)
        as_root_flag=1
        shift
        ;;
      --shell)
        shellbin=$2
        shift 2
        ;;
      --)
        shift
        iargs=("$@")
        break
        ;;
      *)
        log_error "sh_installer_run: unknown option $1"
        return 1
        ;;
    esac
  done

  if is_dry_run; then
    log_dryrun "run vendor installer $url ${iargs[*]:-}"
    return 0
  fi

  # devenv_execdir, NOT devenv_tmpdir, and the installer's own TMPDIR is pointed
  # at it as well. A vendor installer is rarely just a script: it downloads a
  # BINARY into `mktemp -d` and execs it. With /tmp mounted noexec — the fleet's
  # hardening role does exactly that — rustup's install.sh reports
  #     error: Cannot execute /tmp/tmp.XXXXXXXXXX/rustup-init
  #     (likely because of mounting /tmp as noexec)
  # and the module fails. Setting TMPDIR moves that mktemp onto a filesystem that
  # executes, which fixes every installer of that shape at once (uv, nvm, brew,
  # claude, opencode), not just the one that was reported.
  local work script
  work=$(devenv_execdir) || return 1
  script="$work/installer.sh"
  download "$url" "$script" || return 1
  if [ -n "$sha" ]; then
    verify_sha256 "$script" "$sha" || return 1
  else
    log_warn "running an unpinned vendor installer: $url"
    log_warn "  reason: ${reason:-none given at the call site}"
  fi
  run chmod 0755 -- "$script" || return 1
  # TMPDIR goes FIRST so a caller's own --env TMPDIR=… still wins: `env` applies
  # its assignments left to right.
  local envv=("TMPDIR=$work" ${envs[0]+"${envs[@]}"})
  if [ "$as_root_flag" = 1 ]; then
    run_sudo env "${envv[@]}" "$shellbin" "$script" "${iargs[@]}"
  else
    run env "${envv[@]}" "$shellbin" "$script" "${iargs[@]}"
  fi
}
