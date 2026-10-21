# Shortcuts

Every key, alias and helper this repository sets up, on one page.

Source of truth: `config/k9s/plugins/*.yaml`, `config/k9s/hotkeys.yaml`, `config/bashrc.d/*.sh`,
`config/tmux/`. `tests/k9s-keys.sh` fails when a k9s plugin or hotkey is missing from this page.

## k9s

Press **`?`** in any view: the help screen lists what that view offers, plugins included. A plugin
shows only in the views in its *in view* column (`all` = everywhere). Destructive ones ask first,
and every `dangerous` one is hidden on a `readOnly` context.

### At a glance

| view | keys |
|---|---|
| **every view** | `Shift-Y` clean YAML, `Shift-E` watch events, `Shift-T` ownership tree, `Shift-B` copy ref, `Shift-I` describe in `$EDITOR`, `Shift-G` owning Helm release, `Shift-W` shell in this context/namespace, `Shift-Q` strip finalizers |
| **pods** | `Ctrl-T` stern logs, `Shift-D` debug container (netshoot), `Shift-K` force delete, `Shift-M` Cilium endpoint + policy, `Shift-V` Kyverno verdicts |
| **containers** | `Ctrl-T` stern this container, `Shift-D` debug this container, `Shift-C` image config (crane) |
| **deployments / statefulsets / daemonsets** | `Ctrl-T` stern whole workload, `Shift-R` rollout status, `Shift-U` rollout undo |
| **nodes** | `Shift-D` root shell on node, `Shift-K` cordon + drain, `Shift-C` Cilium agent status, `Shift-H` shell in Cilium agent, `Shift-Z` pods on this node |
| **secrets** | `Shift-D` decode all keys, `Shift-C` show one key, `Shift-M` edit decoded |
| **helm** | `Shift-D` diff vs previous revision, `Shift-U` all values, `Shift-M` rendered manifest |
| **Argo CD apps** | `Shift-R` hard refresh, `Shift-M` sync + health detail, `Shift-U` toggle auto-sync |
| **ExternalSecrets** | `Shift-R` force sync, `Shift-M` status + target keys |
| **rook-ceph, KubeVirt, CrunchyData Postgres, cert-manager** | `Shift-C`/`H`/`M`/`R`/`U`/`K`/`Z` — ceph status, VM console, start/stop VM, live migrate, psql on primary, cert expiry, force renew; full list below |
| **anywhere (hotkeys)** | `F2` context, `F3` workloads, `F4` pods, `F5` nodes, `F6` events, `F7` Helm, `F8` Argo CD, `F9` ExternalSecrets, `F12` Kyverno reports, `Shift-L` Cilium policies |

The tables below are the complete list, one row per binding, and the one `tests/k9s-keys.sh` checks.

### Keys tmux takes first

Inside tmux, vim-tmux-navigator binds **`Ctrl-H` `Ctrl-J` `Ctrl-K` `Ctrl-L` `Ctrl-\`** with no prefix
to move between panes and nvim splits, so k9s never receives them. No plugin here uses one —
`tests/k9s-keys.sh` rejects them — but three of k9s's own keys are lost in tmux:

| k9s key | does | inside tmux |
|---|---|---|
| `Ctrl-K` | kill pod (pods) | `Ctrl-D` delete, this repo's `Shift-K` force delete, or the pass-through below |
| `Ctrl-L` | rollback (replicasets) | prefix `C-l` — the navigator plugin passes it through (also bash's clear-screen) |
| `Ctrl-\` | clear marks | `Space` on each marked row |

For `Ctrl-K` as prefix `C-k`, add `bind C-k send-keys C-k` to `~/.tmux.conf` — prefix `C-k` is free in
tmux-config.

nvim adds nothing: neither config maps terminal mode, and its `C-h/j/k/l` are the same navigator moves.

### hotkeys (every view)

| key | does |
|---|---|
| `F2` | Switch context |
| `F3` | Workloads (all ns) |
| `F4` | Pods (all ns) |
| `F5` | Nodes |
| `F6` | Events (all ns) |
| `F7` | Helm releases |
| `F8` | Argo CD applications |
| `F9` | ExternalSecrets (all ns) |
| `F12` | Kyverno policy reports |
| `Shift-L` | Cilium network policies |

### core

| key | in view | does |
|---|---|---|
| `Shift-Y` | all | YAML (neat) |
| `Shift-E` | all | Events (watch) |
| `Shift-T` | all | Ownership tree |
| `Shift-B` | all | Copy ref to clipboard |
| `Shift-I` | all | Describe in $EDITOR |
| `Shift-G` | all | Owning Helm release |
| `Shift-W` | all | Shell in this ctx/ns |
| `Shift-Q` | all | Strip finalizers |

### pods

| key | in view | does |
|---|---|---|
| `Ctrl-T` | pods | Stern (pod + all containers) |
| `Ctrl-T` | containers | Stern (this container) |
| `Shift-D` | pods | Debug (ephemeral netshoot) |
| `Shift-D` | containers | Debug (target this container) |
| `Shift-K` | pods | Force delete (grace 0) |
| `Shift-M` | pods | Cilium endpoint + policy |
| `Shift-C` | containers | Image config (crane) |

### workloads

| key | in view | does |
|---|---|---|
| `Ctrl-T` | deployments, statefulsets, daemonsets, jobs, cronjobs | Stern (whole workload) |
| `Shift-R` | deployments, statefulsets, daemonsets | Rollout status (watch) |
| `Shift-U` | deployments, statefulsets, daemonsets | Rollout undo |

### nodes

| key | in view | does |
|---|---|---|
| `Shift-D` | nodes | Root shell on node |
| `Shift-K` | nodes | Cordon + drain |
| `Shift-C` | nodes | Cilium agent status |
| `Shift-H` | nodes | Shell in cilium agent |
| `Shift-Z` | nodes | Pods on this node |

### secrets

| key | in view | does |
|---|---|---|
| `Shift-D` | secrets | Decode all keys (pager) |
| `Shift-M` | secrets | Edit decoded (modify-secret) |
| `Shift-C` | secrets | Show one key (pager) |

### helm

| key | in view | does |
|---|---|---|
| `Shift-D` | helm | Diff vs previous revision |
| `Shift-U` | helm | All values (incl. defaults) |
| `Shift-M` | helm | Rendered manifest |
| `Shift-D` | history | Diff this revision vs deployed |

### cilium

| key | in view | does |
|---|---|---|
| `Shift-M` | ciliumnetworkpolicies, ciliumclusterwidenetworkpolicies | Endpoints matched by policy |
| `Shift-C` | ciliumendpoints | Endpoint identity + policy |
| `Shift-C` | ciliumnodes | Cilium node IPAM / health |

### kyverno

| key | in view | does |
|---|---|---|
| `Shift-M` | clusterpolicies, policies | Reports for this policy |
| `Shift-M` | policyreports, clusterpolicyreports | Failing results in report |
| `Shift-V` | pods, deployments, statefulsets, daemonsets, ingresses, services, configmaps | Kyverno verdicts for this resource |

### rook-ceph

| key | in view | does |
|---|---|---|
| `Shift-C` | cephclusters | ceph status |
| `Shift-H` | cephclusters | rook-ceph health check |
| `Shift-M` | cephclusters | mon endpoints + operator cfg |
| `Shift-C` | cephblockpools, cephfilesystems, cephobjectstores | pool stats |

### kubevirt

| key | in view | does |
|---|---|---|
| `Shift-C` | virtualmachines, virtualmachineinstances | Serial console |
| `Shift-K` | virtualmachines, virtualmachineinstances | VNC console |
| `Shift-H` | virtualmachines, virtualmachineinstances | Guest agent info |
| `Shift-U` | virtualmachines | Start / stop VM |
| `Shift-R` | virtualmachines | Restart VM |
| `Shift-M` | virtualmachines, virtualmachineinstances | Live migrate |
| `Shift-Z` | virtualmachineinstances | Pause / unpause |

### gitops

| key | in view | does |
|---|---|---|
| `Shift-R` | applications | Hard refresh app |
| `Shift-M` | applications | Sync + health detail |
| `Shift-U` | applications | Toggle automated sync |
| `Shift-R` | externalsecrets, pushsecrets | Force sync ExternalSecret |
| `Shift-M` | externalsecrets, secretstores, clustersecretstores | ESO status + target keys |

### data-certs

| key | in view | does |
|---|---|---|
| `Shift-C` | postgresclusters | psql on primary |
| `Shift-M` | postgresclusters | Cluster status + instances |
| `Shift-H` | postgresclusters | pgBackRest info |
| `Shift-M` | certificates, certificaterequests | Cert status + expiry |
| `Shift-R` | certificates | Force renew (needs cmctl) |

## Shell

Loaded from `~/.bashrc.d/` — open a new shell (`exec bash -l`) after an install.

| key / command | does |
|---|---|
| `Ctrl-R` | fzf history search |
| `Ctrl-T` | fzf: insert a file path |
| `Alt-C` | fzf: `cd` into a directory |
| `z <part>` / `zi` | zoxide: jump to a visited directory / pick one with fzf |
| `Ctrl-O` · `kc [name\|-]` | pick a cluster from `~/.kube/clusters` for THIS shell (`kc -` unsets `KUBECONFIG`) |
| `Ctrl-X n` · `kn` | pick a namespace (kubens) |
| `kx` | pick a context (kubectx) |
| `k` | `kubectl` (through kubecolor when installed) |
| `kwatch <cmd>` | `watch` with kubecolor's colours kept |
| `tf` · `t` | `terraform`, with completion |
| `rgh` | `rg --hidden --no-ignore` — ripgrep that acts like `grep -r` |
| `grepr` | `grep -rn --color=auto` |
| `c` | `clear` |
| `docker-clean` | `docker system prune -f` |
| `nvmetemp` | NVMe temperatures |
| `run_in_all_dirs <cmd>` | run a command in every immediate subdirectory |
| `apt` · `apt-get` | `nala` — only with `ENABLE_NALA_ALIAS=1` |

`DEVENV_KUBE_GUARD=1` makes `kubectl delete/drain/apply/…` on a context matching
`KUBE_PROD_PATTERN` (default `prod`) ask you to retype the context name.

## Helpers on PATH

| command | does |
|---|---|
| `clip` · `clip-paste` | copy / paste through whatever clipboard this box has (WSL, Wayland, X11, OSC 52) |
| `open-url <url>` | open a URL in a real browser, or print it on a headless box — never a TTY browser |
| `web <name\|url>` · `web --list` | open a bookmark from `~/.config/devops-env/bookmarks` |
| `sso-login …` · `sso-kubeconfig-add …` | browser logins from a browser-less box — [sso.md](sso.md) |
| `w3m <url>` | read a page in the terminal |

## tmux

| key | does |
|---|---|
| `C-Space` | prefix, with [tmux-config](https://github.com/Ujstor/tmux-config) (the default) |
| `C-a` | prefix of `config/tmux/minimal.tmux.conf` — the fallback written only when no tmux config was linked and `~/.tmux.conf` does not exist |
| prefix `r` · prefix `I` | reload the config · install the TPM plugins (tmux-config) |
| copy mode `v` … `y` | select, then copy through `clip` |
| prefix `P` | paste from `clip-paste` |
| prefix `\|` · prefix `-` | split side by side · split top and bottom (minimal config) |
| prefix `[` in an OpenCode pane | OC-SCROLL: `C-f`/`C-b` `C-d`/`C-u` `j`/`k` `g`/`G` scroll OpenCode's chat, `v` copy mode, `p` paste, `q` leave (tmux-config) |

The `y` / `P` clipboard keys need one line in `~/.tmux.conf`, which this repository never edits:
`source-file ~/.config/devops-env/tmux/devenv-clipboard.conf`. The minimal config has them built in.

OC-SCROLL needs OpenCode's own mouse capture off, so drags and the wheel reach tmux: the `ai` module
installs `~/.config/opencode/cli.json` with `"mouse": false` (merged into an existing file).

tmux-config's own bindings and [nvim-config](https://github.com/Ujstor/nvim-config)'s keymaps live in
those repositories' READMEs — they are their keys, not this one's.
