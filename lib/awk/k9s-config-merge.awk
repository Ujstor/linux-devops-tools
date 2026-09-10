# linux-devops-tools :: merge the repo's k9s settings into an existing config.yaml
#
#   awk -f lib/awk/k9s-config-merge.awk config/k9s/config.yaml ~/.config/k9s/config.yaml >new
#        ^ PAYLOAD (repo-owned, wins)      ^ TARGET (k9s-owned, preserved)
#
# WHY (MUST-FIX C4): k9s rewrites ~/.config/k9s/config.yaml in full every time it
# exits, so the file already exists on any machine k9s has ever run on, with every
# key present at its default. A create-if-absent install would never land a single
# setting, and a whole-file overwrite would throw away the keys a newer k9s added.
#
# CONTRACT
#   * every LEAF of the payload (a "key: value" line) is forced onto the target,
#   * a key the payload does not mention is left exactly as it was - line, order,
#     comment and all,
#   * a payload key the target lacks is inserted at the end of its parent's block,
#     creating the intermediate maps it needs,
#   * a type clash (payload leaf vs target map, or a parent that is a scalar or a
#     sequence in the target) is REPORTED on stderr and skipped, never forced,
#   * idempotent: merging an already-merged file reproduces it byte for byte.
#
# It understands the YAML subset k9s writes: two-space indented maps of scalars,
# `#` comments and blank lines. Anything else it does not recognise is copied
# through untouched, and is only ever a reason to skip an insertion.
#
# Exit status is 0 even when keys were skipped; the caller decides. Every warning
# is prefixed "k9s-config-merge:" on stderr.

function indent(lvl,   i, s) {
  s = ""
  for (i = 0; i < lvl; i++) s = s "  "
  return s
}

# first KEEP path segments of PATH, re-joined
function joinfirst(path, keep,   n, a, i, s) {
  n = split(path, a, SUBSEP)
  if (keep <= 0) return ""
  if (keep > n) keep = n
  s = a[1]
  for (i = 2; i <= keep; i++) s = s SUBSEP a[i]
  return s
}

function ppathof(d,   i, p) {
  if (d < 0) return ""
  p = pstack[0]
  for (i = 1; i <= d; i++) p = p SUBSEP pstack[i]
  return p
}

function tpathof(d,   i, p) {
  if (d < 0) return ""
  p = tstack[0]
  for (i = 1; i <= d; i++) p = p SUBSEP tstack[i]
  return p
}

function warn(msg) {
  print "k9s-config-merge: " msg > "/dev/stderr"
}

# human-readable path for a message
function pretty(path,   n, a, i, s) {
  n = split(path, a, SUBSEP)
  s = a[1]
  for (i = 2; i <= n; i++) s = s "." a[i]
  return s
}

BEGIN {
  lastd = -1
  pn = 0    # payload leaves, in document order
  gn = 0    # insertion groups, in document order
  bn = 0    # output buffers
  nl = 0    # target line count
}

# ---------------------------------------------------------------------------
# pass 1 - the payload: collect every leaf path and its value
# ---------------------------------------------------------------------------
FNR == NR {
  if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) next
  match($0, /^ */)
  ind = RLENGTH
  rest = substr($0, ind + 1)
  if (rest !~ /^[^ \t#-][^:]*:/) next
  cpos = index(rest, ":")
  key = substr(rest, 1, cpos - 1)
  val = substr(rest, cpos + 1)
  sub(/^[ \t]+/, "", val)
  sub(/[ \t]+$/, "", val)
  d = int(ind / 2)
  pstack[d] = key
  path = ppathof(d)
  if (val == "") {
    pmap[path] = 1
    next
  }
  if (!(path in pleaf)) {
    porder[++pn] = path
    pkey[path] = key
    pparent[path] = ppathof(d - 1)
    plevel[path] = d + 1        # a leaf at depth d sits at indent level d
  }
  pleaf[path] = val
  next
}

# ---------------------------------------------------------------------------
# pass 2 - the target: remember every line, path and block end
# ---------------------------------------------------------------------------
{
  L[++nl] = $0
  if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) next
  match($0, /^ */)
  ind = RLENGTH
  rest = substr($0, ind + 1)
  if (rest ~ /^-([ \t]|$)/ || rest !~ /^[^ \t#][^:]*:/) {
    # a block sequence item, or a line this subset does not model. It still
    # belongs to the innermost open block, so it has to move that block's end
    # marker - otherwise an insertion would land in front of it and orphan it.
    if (rest ~ /^-([ \t]|$)/ && lastpath != "") tseq[lastpath] = 1
    for (i = 0; i <= lastd; i++) blockend[tpathof(i)] = nl
    next
  }
  cpos = index(rest, ":")
  key = substr(rest, 1, cpos - 1)
  val = substr(rest, cpos + 1)
  sub(/^[ \t]+/, "", val)
  sub(/[ \t]+$/, "", val)
  d = int(ind / 2)
  tstack[d] = key
  path = tpathof(d)
  lastpath = path
  lastd = d
  tdepth[path] = d
  if (val == "") {
    torigmap[path] = 1
  } else {
    torigleaf[path] = 1
    tleafline[path] = nl
  }
  for (i = 0; i <= d; i++) blockend[tpathof(i)] = nl
}

END {
  # --- 1. force every payload leaf the target already has -------------------
  for (i = 1; i <= pn; i++) {
    p = porder[i]
    if (p in tleafline) {
      L[tleafline[p]] = indent(plevel[p] - 1) pkey[p] ": " pleaf[p]
      done[p] = 1
      continue
    }
    if (p in torigmap) {
      warn(pretty(p) " is a map in the target but a value here - left alone")
      done[p] = 1
    }
  }

  # --- 2. group the leaves that are still missing, by parent ----------------
  for (i = 1; i <= pn; i++) {
    p = porder[i]
    if (p in done) continue
    par = pparent[p]
    if (!(par in gseen)) {
      gseen[par] = 1
      gorder[++gn] = par
    }
    glist[par] = glist[par] (glist[par] == "" ? "" : SUBSEP SUBSEP) p
  }

  # --- 3. turn each group into text anchored at an existing block -----------
  for (g = 1; g <= gn; g++) {
    par = gorder[g]
    n = split(par, parts, SUBSEP)

    # deepest ancestor that is a map in the ORIGINAL target ('' == file root)
    ak = 0
    A = ""
    for (k = n; k >= 1; k--) {
      c = joinfirst(par, k)
      if (c in torigmap) {
        ak = k
        A = c
        break
      }
    }

    skip = ""
    for (k = ak + 1; k <= n; k++) {
      if (joinfirst(par, k) in torigleaf) skip = pretty(joinfirst(par, k)) " is a value in the target, not a map"
    }
    if (skip == "" && A != "" && (A in tseq)) skip = pretty(A) " holds a list in the target"
    if (skip != "") {
      warn(skip " - skipping " pretty(par))
      continue
    }

    anchor = (ak == 0) ? nl : blockend[A]
    bufkey = anchor SUBSEP A
    if (!(bufkey in bufidx)) {
      bufidx[bufkey] = ++bn
      bufanchor[bn] = anchor
      bufdepth[bn] = ak
    }
    b = bufidx[bufkey]

    # open only the levels this buffer has not opened already: the payload is
    # read depth-first, so a parent block is always still the one we are in
    txt = ""
    for (k = ak + 1; k <= n; k++) {
      lp = joinfirst(par, k)
      if ((bufkey SUBSEP lp) in made) continue
      made[bufkey SUBSEP lp] = 1
      txt = txt indent(k - 1) parts[k] ":\n"
    }
    nleaf = split(glist[par], leaves, SUBSEP SUBSEP)
    for (k = 1; k <= nleaf; k++) {
      p = leaves[k]
      txt = txt indent(n) pkey[p] ": " pleaf[p] "\n"
    }

    buf[b] = buf[b] txt
  }

  # --- 4. print, emitting each anchor's buffers deepest-first ---------------
  flush(0)
  for (i = 1; i <= nl; i++) {
    print L[i]
    flush(i)
  }
}

# every buffer anchored at line I, deepest insertion point first: a nested block
# has to close before a shallower sibling key can open
function flush(i,   d, b) {
  for (d = 99; d >= 0; d--) {
    for (b = 1; b <= bn; b++) {
      if (bufanchor[b] == i && bufdepth[b] == d && !(b in flushed)) {
        flushed[b] = 1
        printf "%s", buf[b]
      }
    }
  }
}
