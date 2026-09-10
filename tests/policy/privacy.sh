#!/usr/bin/env bash
#
# tests/policy/privacy.sh — the public-repo gate.
#
# This repository is PUBLIC. Nothing belonging to a real estate may be committed:
# no internal hostname, no private address range, no realm, client id or client
# secret, no kubeconfig payload, no key material, no personal email address.
#
# THE GATE IS STRUCTURAL, ON PURPOSE. It matches on the SHAPE of a secret, never
# on a list of the real values — a denylist naming the things that must not leak
# is itself the leak, and it is public here. Consequently the gate knows nothing
# about any particular estate and works unchanged for a fork.
#
# Placeholders are the only accepted stand-ins, per RFC 2606 / RFC 5737:
#     example.com  example.org  sso.example.com  gitlab.example.internal
#     192.0.2.0/24  198.51.100.0/24  203.0.113.0/24
#     REALM_PLACEHOLDER  CLIENT_ID_PLACEHOLDER  ROLE_PLACEHOLDER  <your-cluster>
#
# Usage:
#     bash tests/policy/privacy.sh              # scan the checkout, exit 1 on a finding
#     bash tests/policy/privacy.sh --self-test  # prove every rule still fires
#     bash tests/policy/privacy.sh --list       # print the rules and exit
#
# This file EXCLUDES ITSELF from the scan: several patterns (a PEM header, a token
# prefix) necessarily appear here verbatim and would match themselves.

set -euo pipefail

PROG=${0##*/}
SELF_REL='tests/policy/privacy.sh'

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

repo_root() {
  local d
  d=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
  printf '%s\n' "$d"
}

# collect_files ROOT
#   Fills ALL_FILES with every regular file worth considering — tracked plus
#   not-yet-ignored, never .git, never a symlink, never this file — and FILES
#   with the text subset of those, which is what the content rules grep.
collect_files() {
  local root=$1 f
  FILES=()
  ALL_FILES=()
  local -a names=()
  # `git rev-parse`, NOT `[ -d .git ]`. In a `git worktree` checkout .git is a
  # FILE, so the -d test is false and this silently drops into the find fallback
  # — a different enumerator, over a different set of files (it does not honour
  # .gitignore), in the branch nobody ever runs. Two implementations of "which
  # files count", one of them untested, is the shape that let the old-name rule
  # scan a tree it could not see. Ask git whether this is a work tree instead.
  if command -v git >/dev/null 2>&1 \
    && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mapfile -t names < <(git -C "$root" ls-files --cached --others --exclude-standard)
  else
    mapfile -t names < <(cd "$root" && find . -type f -printf '%P\n' | sort)
  fi
  for f in ${names[0]+"${names[@]}"}; do
    [ -n "$f" ] || continue
    case $f in
      .git/* | */.git/* | "$SELF_REL") continue ;;
    esac
    [ -f "$root/$f" ] || continue
    if [ -L "$root/$f" ]; then continue; fi
    # Every regular file is a candidate for the name-based rule, including an
    # empty one — a committed empty `sso.env` is still a committed `sso.env`.
    ALL_FILES+=("$root/$f")
    # -I in grep skips binaries per-match; this skips them per-file, so a binary
    # never even reaches a content rule.
    grep -Iq . "$root/$f" 2>/dev/null || continue
    FILES+=("$root/$f")
  done
}

FOUND_TOTAL=0
FOUND_RULES=''

report() {
  local rule=$1 loc=$2 text=$3
  printf 'PRIVACY [%s] %s\n    %s\n' "$rule" "$loc" "$text" >&2
  FOUND_TOTAL=$((FOUND_TOTAL + 1))
  case " $FOUND_RULES " in
    *" $rule "*) ;;
    *) FOUND_RULES="$FOUND_RULES $rule" ;;
  esac
}

# scan RULE PATTERN [ALLOW_PATTERN] [PATH_SKIP_PATTERN]
#   Greps every collected file for PATTERN (ERE). A hit whose PATH matches
#   PATH_SKIP_PATTERN is not a finding.
#
#   ALLOW_PATTERN is applied to the MATCHED TEXT, never to the whole line. That
#   distinction is the difference between a gate and a decoration: with a
#   line-wide allow, one `example.com` or one `localhost` anywhere on a line
#   excuses every other value on it, so
#       go install gitlab.corp.example-not.internal/g/t@v1  # like gitlab.example.com
#   would sail through. Each match is judged on its own text instead, and the
#   first one that is not excused is what gets reported.
scan() {
  local rule=$1 pat=$2 allow=${3:-} skip=${4:-}
  local hit file rest line text bad
  [ ${#FILES[@]} -gt 0 ] || return 0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file=${hit%%:*}
    rest=${hit#*:}
    line=${rest%%:*}
    text=${rest#*:}
    if [ -n "$skip" ] && printf '%s' "$file" | grep -qE -- "$skip"; then
      continue
    fi
    if [ -n "$allow" ]; then
      bad=$(printf '%s\n' "$text" | grep -oE -- "$pat" 2>/dev/null \
        | grep -vE -- "$allow" 2>/dev/null | head -n 1) || bad=''
      [ -n "$bad" ] || continue
      text=$bad
    fi
    # Trim to something readable, and never echo more than the offending line.
    text=${text#"${text%%[![:space:]]*}"}
    if [ ${#text} -gt 160 ]; then text="${text:0:157}..."; fi
    report "$rule" "${file#"$ROOT/"}:$line" "$text"
  done < <(grep -nIHE -- "$pat" "${FILES[@]}" 2>/dev/null || true)
  return 0
}

# ---------------------------------------------------------------------------
# The rules
# ---------------------------------------------------------------------------
#
# Each is one shape that must never appear. Keep the list additive: a rule that
# has to be relaxed for a legitimate case gets an ALLOW pattern, never a deletion.

RULES_DOC='
  internal-host      a hostname under an internal-looking TLD (.local .lan .internal
                     .intranet .corp), other than an *.example.* placeholder
  private-ip         an RFC1918 literal (10/8, 172.16/12, 192.168/16). Use the
                     RFC5737 documentation ranges instead
  oidc-realm         a Keycloak realm path that is not REALM_PLACEHOLDER or a variable
  client-secret      an OIDC/OAuth client secret with a literal value
  kubeconfig-payload base64 cluster CA / client key / token material, or a real
                     current-context value
  key-material       a PEM private key or certificate block
  token-shape        a credential that looks like a real token (GitHub, GitLab, AWS,
                     Slack, a JWT)
  email              an email address that is not an example.com placeholder
  secret-file        a file that must never be committed at all (sso.env, private.env,
                     a kubeconfig, a vault token, an ssh private key)
'

rule_internal_host() {
  # The allow list is deliberately END-ANCHORED. An earlier version excused any
  # match containing `.local/`, which excused every URL and every Go module path
  # under an internal host — `https://gitlab.ops.<estate>.local/x` and
  # `go install gitlab.ops.<estate>.local/g/t@v1` both passed. Those are the two
  # shapes most likely to be pasted into this repository by accident, so the only
  # thing that may be excused now is a host that ENDS in a placeholder domain.
  scan internal-host \
    '(^|[^A-Za-z0-9._%+-])[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*\.(local|lan|internal|intranet|corp|localdomain)([^A-Za-z0-9.-]|$)' \
    'example\.(com|org|net|internal|intranet|local|lan|corp|localdomain)([^A-Za-z0-9.-]|$)|cluster\.local([^A-Za-z0-9.-]|$)|localhost\.localdomain|\$|(^|[^A-Za-z0-9])[A-Z][A-Z0-9_]+\.(local|lan|internal|intranet|corp|localdomain)'
}

rule_private_ip() {
  scan private-ip \
    '(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9.]|$)'
}

rule_oidc_realm() {
  scan oidc-realm \
    'realms/[A-Za-z0-9_.%-]+' \
    'realms/(REALM_PLACEHOLDER|\$|<|\{|%s|REALM\b)'
}

rule_client_secret() {
  # The value is captured whole, not one character of it: the allow list has to be
  # able to see `PLACEHOLDER` / `CHANGEME` / an empty pair of quotes to excuse it.
  scan client-secret \
    '(--oidc-client-secret=|client_secret[[:space:]]*[:=][[:space:]]*|CLIENT_SECRET[[:space:]]*=)[^[:space:]]+' \
    '(\$|<|PLACEHOLDER|CHANGEME|""|'\'''\''|%s|\{\{)'
}

rule_kubeconfig_payload() {
  scan kubeconfig-payload \
    '((certificate-authority|client-key|client-certificate)-data|id-token|refresh-token)[[:space:]]*:[[:space:]]*[A-Za-z0-9+/=]{24,}' \
    '(\$|<|PLACEHOLDER|REDACTED|\.\.\.)'
  # Again the whole value, so `my-cluster` / `your-context` / `ctx-example` can be
  # recognised. A `<placeholder>` never matches at all: the pattern requires an
  # alphanumeric immediately after the colon.
  scan kubeconfig-payload \
    'current-context[[:space:]]*:[[:space:]]*[A-Za-z0-9][A-Za-z0-9._-]*' \
    '(\$|<|PLACEHOLDER|example|ctx-|my-|your-)'
}

rule_key_material() {
  scan key-material \
    '-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE|OPENSSH PRIVATE KEY)-----'
}

rule_token_shape() {
  scan token-shape \
    '(gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{12,}|eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.)'
}

rule_email() {
  scan email \
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' \
    '@example\.|git@github\.com|@github\.com|@gitlab\.com|noreply@|@localhost|@\$|@<|@v?[0-9]|@(latest|main|master|stable)'
}

rule_secret_file() {
  local f base
  for f in ${ALL_FILES[0]+"${ALL_FILES[@]}"}; do
    base=${f##*/}
    case $base in
      sso.env | private.env | .env | *.kubeconfig | kubeconfig | .vault-token | id_rsa | id_ed25519 | *.pem | *.p12 | *.pfx | *.jks)
        report secret-file "${f#"$ROOT/"}:0" "this file must never be committed"
        ;;
    esac
  done
  return 0
}

# scan_tree ROOT — collect the files, refuse an empty collection, run every rule.
#
# The refusal is the point. "scanning 0 file(s)" followed by "clean" is a gate
# that cleared this repository for publication without opening a single file,
# and it exits 0 exactly like a real pass. Factored out of main() so the
# self-test can aim it at an empty tree and prove it still refuses.
scan_tree() {
  local root=$1
  collect_files "$root"
  printf '%s: scanning %d file(s) under %s\n' "$PROG" "${#FILES[@]}" "$root"
  if [ "${#FILES[@]}" -eq 0 ]; then
    printf '%s: not one file was collected, so not one rule read anything.\n' "$PROG" >&2
    printf 'This is a public repository and the gate has not cleared it. Refusing to pass.\n' >&2
    return 1
  fi
  run_rules
  return 0
}

run_rules() {
  rule_internal_host
  rule_private_ip
  rule_oidc_realm
  rule_client_secret
  rule_kubeconfig_payload
  rule_key_material
  rule_token_shape
  rule_email
  rule_secret_file
}

# ---------------------------------------------------------------------------
# Self-test — MUST-FIX S2: prove the gate fires, using SYNTHETIC values that
# match the patterns. Never a real one, and never inside the checkout.
# ---------------------------------------------------------------------------

self_test() {
  local dir rc=0 rule
  dir=$(mktemp -d "${TMPDIR:-/tmp}/privacy-selftest.XXXXXXXX")
  # shellcheck disable=SC2064  # expand $dir now: it is a fresh mktemp path
  trap "rm -rf -- '$dir'" EXIT

  mkdir -p "$dir/docs"
  cat >"$dir/violations.txt" <<'EOF'
issuer https://sso.corp-placeholder-name.internal/realms/notaplaceholder
apiserver 10.11.12.13 and 192.168.4.5 and 172.20.0.7
--oidc-client-secret=abcdefghijklmnop
certificate-authority-data: QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5
current-context: prodcluster-admin
maintainer person.name@somecompany.example-not.tld
EOF
  # The three shapes an earlier, line-wide allow list let through. Each carries a
  # decoy that used to excuse the whole line, so a regression to line-wide allow
  # matching fails the self-test instead of shipping silently.
  cat >"$dir/docs/leaky.md" <<'EOF'
browse https://platform.ops.corp-placeholder-name.internal/api (not example.com)
go install gitlab.ops.corp-placeholder-name.internal/group/tool@v1.2.3
listen on localhost, then reach registry.corp-placeholder-name.lan for the image
contact real.person@somecompany.example-not.tld or team@example.com
EOF
  printf -- '-----BEGIN RSA PRIVATE %s-----\n' KEY >>"$dir/violations.txt"
  # Token shapes, assembled so this file's own text cannot match them.
  {
    printf 'gh%s_%s\n' p AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    printf 'glpat-%s\n' AAAAAAAAAAAAAAAAAAAA
    printf 'AKIA%s\n' ABCDEFGHIJKLMNOP
  } >>"$dir/violations.txt"
  : >"$dir/sso.env"

  cat >"$dir/docs/clean.md" <<'EOF'
Issuer https://sso.example.com/realms/REALM_PLACEHOLDER, client CLIENT_ID_PLACEHOLDER.
Documentation ranges only: 192.0.2.10, 198.51.100.7, 203.0.113.9. Loopback 127.0.0.1:8000.
Paths like $HOME/.local/bin and svc.cluster.local are fine. Mail us at team@example.com.
Clone git@github.com:owner/repo.git. Version 1.10.0.1 is not an address.
current-context: <your-context>
EOF

  ROOT=$dir
  collect_files "$dir"
  FOUND_TOTAL=0
  FOUND_RULES=''
  printf '%s: self-test — the findings below are SYNTHETIC and expected\n' "$PROG" >&2
  run_rules 2>/dev/null

  for rule in internal-host private-ip oidc-realm client-secret kubeconfig-payload \
    key-material token-shape email secret-file; do
    case " $FOUND_RULES " in
      *" $rule "*) printf '  ok    %s fires\n' "$rule" ;;
      *)
        printf '  FAIL  %s did not fire on a synthetic violation\n' "$rule"
        rc=1
        ;;
    esac
  done

  # The decoy file, on its own: three internal hosts and one real address, each on
  # a line that also carries something the allow list recognises. All four must be
  # reported. If this drops below four, the allow list has gone line-wide again.
  FILES=("$dir/docs/leaky.md")
  ALL_FILES=("$dir/docs/leaky.md")
  FOUND_TOTAL=0
  FOUND_RULES=''
  run_rules 2>/dev/null
  if [ "$FOUND_TOTAL" -ge 4 ]; then
    printf '  ok    a placeholder elsewhere on the line does not excuse a real value\n'
  else
    printf '  FAIL  %d of 4 decoyed violations fired; the allow list is matching whole lines\n' \
      "$FOUND_TOTAL"
    rc=1
  fi

  # And the clean file must be clean: re-scan it alone.
  FILES=("$dir/docs/clean.md")
  ALL_FILES=("$dir/docs/clean.md")
  FOUND_TOTAL=0
  FOUND_RULES=''
  run_rules
  if [ "$FOUND_TOTAL" -eq 0 ]; then
    printf '  ok    the placeholder-only document is accepted\n'
  else
    printf '  FAIL  %d false positive(s) on the placeholder-only document\n' "$FOUND_TOTAL"
    rc=1
  fi

  # And a tree with nothing in it must FAIL. A privacy gate that reports clean
  # having opened no file is the failure this whole exercise is about, and it is
  # indistinguishable from a real pass by exit status alone.
  mkdir -p "$dir/empty"
  if (scan_tree "$dir/empty") >/dev/null 2>&1; then
    printf '  FAIL  scanning an empty tree reported success\n'
    rc=1
  else
    printf '  ok    scanning nothing fails instead of passing\n'
  fi

  [ "$rc" -eq 0 ] && printf '%s: self-test passed\n' "$PROG"
  return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  case ${1:-} in
    --list)
      printf 'privacy rules:\n%s\n' "$RULES_DOC"
      return 0
      ;;
    --self-test)
      self_test
      return
      ;;
    '') ;;
    *)
      printf 'usage: %s [--self-test|--list]\n' "$PROG" >&2
      return 64
      ;;
  esac

  ROOT=$(repo_root)
  scan_tree "$ROOT" || return 1

  if [ "$FOUND_TOTAL" -gt 0 ]; then
    printf '\n%s: %d finding(s) in rules:%s\n' "$PROG" "$FOUND_TOTAL" "$FOUND_RULES" >&2
    printf 'This repository is public. Replace every value above with a placeholder\n' >&2
    printf 'and keep the real one in ~/.config/devops-env/ (gitignored, mode 0600).\n' >&2
    printf 'Run "%s --list" for what each rule means.\n' "$PROG" >&2
    return 1
  fi
  printf '%s: clean\n' "$PROG"
  return 0
}

main "$@"
