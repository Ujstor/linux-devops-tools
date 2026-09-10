# devops-env-config :: point one k9s config at a skin (and optionally lock it)
#
#   awk -v skin=danger-prod [-v readonly=true] -f lib/awk/k9s-set-skin.awk \
#       <config.yaml> > <config.yaml>.new
#
# Works on either k9s config file, because both are a single `k9s:` map:
#   ~/.config/k9s/config.yaml                                   (global)
#   $XDG_DATA_HOME/k9s/clusters/<cluster>/<context>/config.yaml (per context)
#
# It rewrites nothing else - the per-context file also holds the namespace
# favourites k9s maintains, and those must survive untouched.
#
# Idempotent: an existing two-space `skin:` (and `readOnly:`, when readonly is
# given) is dropped and re-inserted directly under `k9s:`, so re-running it
# produces the same bytes. Leaving readonly empty leaves that key alone.
/^  skin:[[:space:]]/ { next }
readonly != "" && /^  readOnly:[[:space:]]/ { next }
{ print }
/^k9s:[[:space:]]*$/ {
  print "  skin: " skin
  if (readonly != "") print "  readOnly: " readonly
}
