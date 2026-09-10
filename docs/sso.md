# Logging in from a box with no browser

This environment is **terminal-only**: no desktop, no compositor, no GUI browser. Browser-based
logins still work everywhere, because the repo installs one small opener, `open-url`, and points
every tool at it.

## How it works, in one table

Three different mechanisms are in play and they do **not** share configuration. This is the single
most useful thing on this page.

| Tool | Opens a browser via | Honours `$BROWSER`? | What actually rescues it |
|---|---|---|---|
| `kubectl oidc-login` | `github.com/pkg/browser` | **No** | our `~/.local/bin/xdg-open` symlink |
| `bao login -method=oidc` | `github.com/pkg/browser` | **No** | same |
| `argocd login --sso` | `skratchdot/open-golang` | **No** | same |
| `az login` | python `webbrowser` | **Yes** | `$BROWSER` |
| `gh auth login` | `cli/browser` | **Yes** (`GH_BROWSER` first) | `$BROWSER`, plus gh's own headless auto-detect |
| `glab auth login --web` | `cli/browser` | **Yes** | `$BROWSER`, plus `--device` |

So `export BROWSER=chrome` — the commented-out line in the old `~/.bashrc` — would have fixed
`az`/`gh`/`glab` and done **nothing** for `kubelogin`/`argocd`/`bao`, i.e. it would have missed the
priority case. The repo therefore owns `xdg-open` as well as `$BROWSER`.

## The three host modes

`open-url` picks one at runtime. Check which one you are in:

```bash
open-url --mode        # wsl | gui | print
open-url 'https://example.com/?a=1&b=2#f'
```

| mode | what happens |
|---|---|
| `wsl` | the URL is handed to the **Windows** browser — your real profile, your password manager, your live Keycloak session, your FIDO2 key |
| `gui` | a real graphical browser on this box (rare here) |
| `print` | the URL is printed in a copy-paste block and pushed to your **laptop's** clipboard over OSC 52. This is the SSH case. |

Force one with `DEVENV_BROWSER_MODE=wsl|gui|print|command` (and `DEVENV_BROWSER_CMD` for `command`).
`DEVENV_BROWSER_QR=1` also renders the URL as a QR code when `qrencode` is installed — the fastest
way to finish an SSH login from a phone.

`print` mode never writes to stdout — a URL there would corrupt the `ExecCredential` JSON that
`kubectl` parses from an exec plugin's stdout, and you would get `error: unable to parse
ExecCredential` instead of a login.

## First run

`devenv --only auth-sso` installs the shims and seeds `~/.config/devops-env/sso.env` from
`config/sso/sso.env.example` at mode 0600. It never overwrites an existing one, so the only thing
left to do is fill it in:

```bash
$EDITOR ~/.config/devops-env/sso.env       # fill in issuer, client id, hosts
exec bash -l
sso-login --status
```

If the file is not there — the module was skipped, or you are on a checkout without it — seed it by
hand from wherever the checkout lives (`devenv version` prints the path on its `checkout` line):

```bash
devenv_home=$(devenv version | awk '$1 == "checkout" { print $2 }')
install -D -m 600 "$devenv_home/config/sso/sso.env.example" ~/.config/devops-env/sso.env
```

`~/.config/devops-env/sso.env` is the **only** place a real hostname is written on this box. It is
gitignored and never overwritten by an install.

## The callback problem, and the one command that solves it

An authorization-code flow ends with the browser being redirected to `http://localhost:<port>/…`
**on the machine that started the flow**. On a headless box the flow starts here, but the browser is
on your laptop — so the redirect lands on the *laptop's* localhost, where nothing is listening.

Fix it with a **local** forward, from the laptop, before (or during) the flow:

```bash
ssh -o ExitOnForwardFailure=yes \
    -L 8000:localhost:8000 \
    -L 18000:localhost:18000 \
    you@devbox
```

Already connected? Use the ssh escape: press **Enter**, then **`~C`**, then type:

```
-L 8000:localhost:8000
```

Read the direction carefully, because getting it backwards is the classic mistake:

* **`-L 8000:localhost:8000` (correct).** Opens a listener on **your laptop's** `localhost:8000` and
  forwards each connection to `localhost:8000` **as resolved on the box**. Laptop browser →
  laptop:8000 → ssh → box:8000 → the CLI's waiting listener. 
* **`-R 8000:localhost:8000` (wrong).** Opens a listener on the **box** forwarding to the laptop.
  That is the opposite direction, and it also collides with the CLI's own listener on the box —
  you get `bind: address already in use`. Never use `-R` for these flows.

`ExitOnForwardFailure=yes` makes a port clash on the laptop loud instead of silent.

### Port-forward table

Everything you might need to tunnel, with the redirect URI that must be registered on the IdP side.

| Tool | Listener on the box | Forward from the laptop | Redirect URI to register |
|---|---|---|---|
| `kubectl oidc-login` (authcode) | `127.0.0.1:8000` — **pinned** by the kubeconfig | `-L 8000:localhost:8000` | `http://localhost:8000/*` |
| `kubectl oidc-login` (fallback port) | `127.0.0.1:18000` | `-L 18000:localhost:18000` | `http://localhost:18000/*` |
| `kubectl oidc-login` (`authcode-keyboard`) | none | none needed | `urn:ietf:wg:oauth:2.0:oob` |
| `argocd login --sso` | `127.0.0.1:8085` (`--sso-port`) | `-L 8085:localhost:8085` | `http://localhost:8085/auth/callback` |
| `bao login -method=oidc` (`callbackmode=client`) | `127.0.0.1:8250` (`port=`) | `-L 127.0.0.1:8250:localhost:8250` | `http://localhost:8250/oidc/callback` |
| `bao login -method=oidc` (`callbackmode=device`) | none | none needed | **none** |
| `terraform login` | `localhost:10000` (+10001–10009) | `-L 10000:localhost:10000` | fixed by the host's registration |
| `az login` | an **ephemeral** 127.0.0.1 port | **not tunnelable** | — use `--use-device-code` |
| `gh auth login` | device code over SSH | not needed | — |
| `glab auth login --device` | none | not needed | — |

Two notes on that table:

* `az` only pins a port (8400) when the authority is ADFS. For normal Entra logins the port is
  random, so there is nothing to forward. Do not fight it — device code is mature and strictly less
  hassle.
* For OpenBao's client mode, forward `127.0.0.1:8250` explicitly and register the redirect URI with
  `127.0.0.1`, not `localhost`: Chromium resolves `localhost` to `::1` first and the callback can
  hang in Chromium while working in Firefox (openbao#2926).

## Keycloak → kubectl

This is the important one. One login covers **all** your contexts.

### 1. Validate the IdP before touching any kubeconfig

```bash
kubectl oidc-login setup \
  --oidc-issuer-url="$OIDC_ISSUER_URL" \
  --oidc-client-id="$OIDC_CLIENT_ID"
# on a box with no tunnel, add:
#   --grant-type=authcode-keyboard --oidc-redirect-url=urn:ietf:wg:oauth:2.0:oob
```

It runs the whole flow, dumps the ID token claims — look for `groups`, this is the #1 real-world
failure — and prints the `clusterrolebinding`, the API-server flags and the
`kubectl config set-credentials` line.

### 2. Wire the kubeconfig

```bash
sso-kubeconfig-add --context ctx-one --context ctx-two          # tunnelable host (default)
sso-kubeconfig-add --headless --context ctx-one --context ctx-two   # no tunnel possible
```

It backs up `~/.kube/config`, shows a diff, and asks before writing. `--dry-run` prints the stanza
only.

**Default (tunnelable):** grant type `authcode`, listener pinned to `127.0.0.1:8000`, redirect URL
therefore deterministically `http://localhost:8000`. Works unchanged on WSL2 (Windows forwards
`localhost` into the distro) and over SSH with the `-L` tunnel above. One kubeconfig, both machines.

**`--headless`:** grant type `authcode-keyboard` with redirect URI `urn:ietf:wg:oauth:2.0:oob`. No
listener, no callback, no free port. Keycloak renders the code in the page title and in a box on the
page, and you paste it back into the terminal. Use this on a bastion, behind a `ProxyJump` chain, or
anywhere you cannot open a local forward.

Choose one **per host** and leave it in the kubeconfig. The redirect URL is part of the token-cache
key, so mixing the two modes on one host silently produces two cache entries and a second login.

### 3. Log in and verify

```bash
sso-login k8s                # warms the cache via the kubeconfig's own exec args
kubectl auth whoami          # the mapped username and groups — the best debugging command here
kubectl auth can-i --list    # proves the RBAC binding landed
```

`sso-login k8s` deliberately runs `kubectl auth whoami`, not `kubectl oidc-login get-token`: the raw
`ExecCredential` JSON contains your ID token, and it has no business in scrollback or a clipboard.

### One login, every cluster

The token cache lives at `~/.kube/cache/oidc-login/<sha256>`, mode 0600, and the filename is a hash
of issuer URL + client id + client secret + **extra scopes (order included)** + redirect URL + PKCE
method + TLS config + username. So:

* Every context that shares one `oidc` user shares one cache entry. **One login, every cluster.**
  That is the payoff for a single user stanza instead of one per context.
* Adding an extra scope, or reordering the list, invalidates the cache once. Harmless, but keep the
  list identical everywhere.
* Changing `--certificate-authority` also invalidates it — the TLS config is inside the key.
* Grant type is **not** in the key; redirect URL **is**. That is why the mode belongs in the
  kubeconfig.

```bash
kubectl oidc-login clean            # drop the cache
kubectl oidc-login get-token … --force-refresh   # refresh regardless of expiry
```

On this box `--token-cache-storage=keyring` is not usable: there is no Secret Service on a
terminal-only host. `disk` at 0600 is the default and the right answer.

### k9s

k9s spawns the exec plugin without an interactive TTY, so it cannot service a paste-back prompt.
Run `sso-login k8s` first; k9s then finds a valid token and never needs to prompt. Also make sure
`~/.krew/bin` is on `PATH` from a fragment k9s's parent shell actually loads (`~/.bashrc.d/30-k8s.sh`
does this).

## Azure, and AKS

```bash
az login                       # WSL2: opens the Windows browser
az login --use-device-code     # headless: this shell adds it for you automatically
az account show
```

`~/.bashrc.d/55-sso.sh` appends `--use-device-code` to a bare `az login` whenever `open-url --mode`
says `print`. This exists because setting `$BROWSER` defeats az's own headless fallback:
`can_launch_browser()` returns true as soon as `webbrowser.get()` succeeds, so az would start an
authcode flow on a random loopback port that nothing can tunnel.

AKS clusters, after `az login`:

```bash
AKS_CONTEXT=my-aks-context
kubelogin convert-kubeconfig -l azurecli --context "$AKS_CONTEXT"
kubectl --context "$AKS_CONTEXT" get nodes
```

**Always pass `--context`.** Without it, `convert-kubeconfig` rewrites *every* context that uses
azure auth or an exec plugin.

`-l azurecli` reuses the token `az login` already obtained, so it inherits whatever flow worked. The
default `-l devicecode` also works headless, but Entra does not return `verification_uri_complete`
(so the code must be typed by hand) and it fails under Conditional Access.

Two WSL gotchas:

* If the Windows default browser is **Edge**, `az login` often fails with *"The connection for this
  site isn't secure"* because Edge HSTS-pins `localhost`. Open `edge://net-internals/#hsts`, put
  `localhost` under *Delete domain security policy*, Delete.
* WAM (`core.enable_broker_on_windows`) is a Windows-native broker and is irrelevant inside WSL —
  `az` there is a Linux process and always takes the browser or device-code path.

Cached at `~/.azure/` (`msal_token_cache.json`, `azureProfile.json`). Relocate with
`AZURE_CONFIG_DIR`; if you do, `kubelogin` needs `--azure-config-dir` to match.

## GitHub

```bash
gh auth login
gh auth status
```

Over SSH, gh detects the remote environment and switches to the device-code flow by itself — a
one-time code and `https://github.com/login/device`. On WSL2 it does **not** detect headless and
opens a browser, which is exactly what the shim is for. There is no flag to force device code; if
detection ever misfires use `gh auth login --with-token < token.txt` or `GH_TOKEN`.

Storage: the system credential store when one exists, otherwise **plaintext** in
`~/.config/gh/hosts.yml` at 0600. On a terminal-only box there is normally no Secret Service, so
expect the file. It is a real secret — treat it like one.

Git credential helper: `gh auth setup-git` writes `credential.https://github.com.helper` into
`~/.gitconfig`. It is per-host, so it does not touch the internal GitLab. `15-git.sh` adds it only
when absent.

## GitLab

```bash
glab auth login --hostname "$GITLAB_HOST" --device            # headless — a first-class flag
glab auth login --hostname "$GITLAB_HOST" --web --git-protocol ssh   # browser available
glab auth login --hostname "$GITLAB_HOST" --stdin < token.txt # a PAT, works anywhere
glab auth status
```

Prefer `--stdin` over `--token` so the PAT never reaches shell history or `ps`.

`GITLAB_HOST` comes from `sso.env` and selects the instance when you are not inside a repo with a
matching remote — essential when running `glab` from an arbitrary directory. `GITLAB_TOKEN` /
`GITLAB_ACCESS_TOKEN` override stored credentials.

Storage: `~/.config/glab-cli/config.yml` (or `GLAB_CONFIG_DIR`), or the OS keyring with
`--use-keyring` — same caveat as gh: no Secret Service here, so expect the file.

For a self-signed internal CA, install it properly:

```bash
sudo cp internal-ca.crt /usr/local/share/ca-certificates/internal-ca.crt
sudo update-ca-certificates
```

That is also the correct fix for a global `git http.sslVerify=false`, which disables TLS
verification for **github.com** too and is a surprisingly common leftover. `devenv doctor` reports
it; it will not change it for you.

## Argo CD

The neatest answer needs no Argo CD login at all:

```bash
argocd login "$ARGOCD_SERVER" --core       # talks to Kubernetes directly, via your kubeconfig
argocd app list
```

Since the kubeconfig is already Keycloak-backed, `--core` inherits that login and skips the API
server entirely. This is the recommended default.

When you do need the API server:

```bash
argocd login "$ARGOCD_SERVER" --sso --grpc-web                          # browser available
argocd login "$ARGOCD_SERVER" --sso --grpc-web --sso-launch-browser=false   # headless
```

The second prints the auth URL for you to open elsewhere, but the callback still lands on
`localhost:8085` **on this box** — so pair it with `ssh -L 8085:localhost:8085`. Change the port with
`--sso-port` and register the matching redirect URI on the Argo CD OIDC client, or the IdP rejects
it. `--grpc-web` is needed when the Argo CD server sits behind an ingress that does not do HTTP/2.
Config lands in `~/.config/argocd/config`.

## OpenBao

The cleanest headless flow on this page — a device flow with **no callback and no redirect URI to
register**:

```bash
export BAO_ADDR="$BAO_ADDR"
bao login -method=oidc role="$BAO_ROLE" callbackmode=device
```

Parameters are `key=value` positional arguments (Vault style), not `--flags`. The useful ones:

| param | default | meaning |
|---|---|---|
| `callbackmode` | `client` | `client` \| `direct` \| `device` |
| `port` | `8250` | client mode only |
| `listenaddress` | `localhost` | client mode only — set `127.0.0.1` for Chromium |
| `role` | — | the OIDC role |
| `skip_browser` | `false` | print the URL instead of launching |
| `show_qr` | `false` | render the URL as a terminal QR code |
| `mount` | `oidc` | the auth mount (also `-path=`) |

Fallbacks, in order of preference after `callbackmode=device`:

```bash
bao login -method=oidc role="$BAO_ROLE" skip_browser=true show_qr=true   # + ssh -L 8250:...
bao login -method=oidc role="$BAO_ROLE" callbackmode=direct             # server receives the callback
```

`direct` mode needs `https://<host:port>/v1/auth/<path>/oidc/callback` registered, and the server
shows a confirmation page displaying the requester's IP (anti-phishing, on by default).

Token goes to `~/.vault-token` (OpenBao keeps the Vault-compatible path). `BAO_TOKEN`/`VAULT_TOKEN`
override it. If the fleet is on HashiCorp Vault rather than OpenBao, every command here is identical
with `vault` substituted and `VAULT_ADDR` instead of `BAO_ADDR`.

## Where credentials live

| Tool | Path | Encrypted? |
|---|---|---|
| kubelogin (Keycloak) | `~/.kube/cache/oidc-login/<sha256>` | no — 0600 |
| Azure CLI | `~/.azure/msal_token_cache.json` | no — 0600 |
| gh | credential store, else `~/.config/gh/hosts.yml` | usually **no** here |
| glab | keyring with `--use-keyring`, else `~/.config/glab-cli/config.yml` | usually **no** here |
| Argo CD | `~/.config/argocd/config` | no |
| OpenBao | `~/.vault-token` | no |
| docker / crane / helm registry | `~/.docker/config.json` | **base64, not encrypted** |

A terminal-only box has no Secret Service, so several of these are plaintext at 0600. That is the
honest situation; `devenv doctor` checks the modes rather than pretending a keyring saves you.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| hangs ~3 min, then `authentication timeout` | headless host on the `authcode` grant with no tunnel | open the `-L` tunnel, or `sso-kubeconfig-add --headless`. The default timeout is 180 s; the template raises it to 600 |
| `error: unable to parse ExecCredential` | something wrote to **stdout** — a broken shim, or an rc file that `echo`s | the shim writes to `/dev/tty`/stderr only; never `echo` from a file a non-interactive `kubectl` might source |
| `bind: address already in use` | 8000 and 18000 both taken | pin a free port with `--listen-address` **and** register the matching redirect URI in Keycloak |
| `invalid_grant` / `Token is not active` right after logging in | **clock skew** — WSL2's clock drifts after the Windows host sleeps, and Keycloak's default allowable skew is 0 s | `sudo hwclock -s` on WSL, or fix `systemd-timesyncd`/`chrony` on the VM. Compare `date -u` with `curl -sI https://sso.example.com \| grep -i ^date` |
| authenticates, then `Unauthorized` / `forbidden` | the `groups` claim is absent or unmapped | `kubectl oidc-login setup …` prints the claims. Add a Group Membership mapper, *Add to ID token* on, *Full group path* off. Confirm the API server has `--oidc-groups-claim=groups` |
| `x509: certificate signed by unknown authority` against the **IdP** | self-signed Keycloak CA | `--certificate-authority=~/.kube/idp-ca.pem`. **Never** `--insecure-skip-tls-verify` |
| the same error against the **API server** | a different trust store entirely | that is `clusters[].cluster.certificate-authority-data`; kubelogin's TLS flags do not touch it |
| a browser opens `lynx` and eats the terminal | `xdg-open`'s generic chain ends at `www-browser` → `/usr/bin/lynx` | the shim shadows `www-browser`; check `command -v xdg-open` resolves under `$HOME` |
| inside tmux everything thinks there is a display | `set-environment -g DISPLAY :1` in `~/.tmux.conf` | delete that line; see `config/tmux/devenv-clipboard.conf` |
| `unknown command "convert-kubeconfig"` | `go install github.com/int128/kubelogin` overwrote Azure's `~/go/bin/kubelogin` | reinstall Azure's: `go install github.com/Azure/kubelogin@latest`. Never `go install` int128's — use krew |
| behind a corporate proxy | | `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` are honoured by all the Go CLIs |

## X11 forwarding (`ssh -X`) — don't

It forwards a *client*, and this box deliberately has no GUI browser to forward. Installing one plus
the X libraries re-creates the desktop we removed. It is slow over a WAN, needs `xauth` here and
`X11Forwarding yes` in the remote `sshd_config`, and it makes `$DISPLAY` look graphical so tools
start trying to launch a browser that does not exist. The print shim plus `ssh -L` gets the same job
done with a local, fast, already-logged-in browser.

