# WSL notes

There is no "WSL edition" of this repository. The same modules run on WSL2, a VM, a cloud instance
and a container; the `wsl` module is a no-op unless `os_is_wsl` is true, and the rest of the tree
gates on the same detection. This page collects the parts that are genuinely WSL-specific, plus a
Windows-side `wsl.exe` reference worth keeping around.

## What the `wsl` module does

| it does | it does **not** |
|---|---|
| install `wslu` when the archive has it (jammy/noble universe) | add the upstream third-party `wslu` repository — it is dead and now serves an HTML page, which breaks `apt update` |
| offer to set `[boot] systemd=true` when the key is **absent** | overwrite a key you already set |
| add a `[boot] command` to start Docker on a sysvinit distro | assume WSL means no systemd |
| print the restart hint (`wsl --shutdown` from Windows) when a change needs one | restart anything itself |
| leave `/etc/wsl.conf` untouched by default | ever write `[automount]` or `[interop]` — those two are refused outright |

Any write to `/etc/wsl.conf` needs `--allow-wsl-conf` (or `DEVENV_ALLOW_WSL_CONF=1`). `--yes` alone
is not enough: it is a system-wide, reboot-scoped file, and it is not this tool's to reshape.

## Interop, and why nothing is called by bare name

Two independent settings are easy to confuse:

* **`[interop] enabled`** controls whether Linux can *launch* Windows processes at all. When this is
  on, `/proc/sys/fs/binfmt_misc/WSLInterop` says `enabled` and an absolute path such as
  `/mnt/c/Windows/System32/…/powershell.exe` works.
* **`[interop] appendWindowsPath`** only controls whether the Windows `PATH` is appended to yours.

So `powershell.exe`, `clip.exe`, `cmd.exe` and `explorer.exe` can all be unresolvable *by name*
while interop itself is perfectly healthy. This is a very common state, and it is exactly why the
shims here never invoke a Windows executable by bare name and never assume `/mnt/c`:

* the Windows mount prefix is resolved at runtime by reading `[automount] root` out of
  `/etc/wsl.conf`, so a box with `C:` at `/c` keeps working;
* `wslview` is preferred when it exists;
* PowerShell is reached through its absolute path, quoted for PowerShell's single-quote rules;
* `cmd.exe /c start` is not used — an unquoted `&` splits the command line and it complains about
  UNC paths on every call from a Linux directory;
* `explorer.exe` is not used — it exits `1` even on success.

No module "repairs" `appendWindowsPath`.

## Browser and clipboard

```bash
open-url --mode         # on WSL with interop: prints `wsl`
open-url https://example.com
echo hello | clip       # -> the Windows clipboard
clip-paste              # <- the Windows clipboard
```

`open-url` hands URLs to the **Windows** browser, which is what you want: it has your profile, your
password manager, your live SSO session cookies and your FIDO2 key. `pbcopy`/`pbpaste` are symlinks
to `clip`/`clip-paste`, so the macOS muscle memory works.

If your `~/.bashrc` still has the old `alias pbcopy='clip.exe'` line, it is already dead (see above)
— [docs/migration.md](migration.md) covers replacing it.

WSL2 also forwards Windows `localhost` into the distro, which is why the Keycloak → kubectl flow
needs **no tunnel here**: the browser on Windows redirects to `localhost:8000` and the listener
inside the distro receives it. That is the whole reason one kubeconfig works on both a WSL box and
an SSH box — see [docs/sso.md](sso.md).

## Docker

After the `containers` module adds you to the `docker` group (which needs `--allow-docker-group`,
because that group is root-equivalent), the change does not apply to running shells. Under WSL the
reliable way to pick it up is from Windows:

```powershell
wsl --shutdown
```

Then start the distro again. `newgrp docker` works for one shell if you are in a hurry.

## tmux and `$DISPLAY`

A `~/.tmux.conf` that carries

```tmux
set-environment -g DISPLAY :1
```

makes every process inside tmux believe there is an X display. That single line breaks graphical-
session detection everywhere: tools start trying to launch a browser that does not exist, and
`open-url` would pick the wrong backend. The shims here therefore require a real display **socket**,
not just `$DISPLAY`, so they stay correct inside tmux.

If the line is yours to remove, remove it upstream. This repository does not edit `~/.tmux.conf` in
place — it ships a sourceable snippet and the doctor reports what it found.

## Clock skew

A WSL2 distro's clock can drift after the Windows host sleeps. Keycloak's default allowable skew is
**0 seconds**, so the symptom is a login that succeeds and is then rejected with `invalid_grant` or
`Token is not active`. Check and fix:

```bash
date -u
curl -sI https://example.com | grep -i '^date'
sudo hwclock -s
```

`devenv doctor` compares the two and warns when they differ by more than 30 seconds.

---

## Windows-side reference (`wsl.exe`)

Run these in PowerShell or Command Prompt on the Windows host, not inside the distro.

### Basics

```powershell
wsl --list --verbose            # every distro, its version and state
wsl -d <DistroName>             # start / enter one
wsl --terminate <DistroName>    # stop one
wsl --set-default <DistroName>
wsl --status
wsl --version
```

### Install and update

```powershell
wsl --install -d <DistroName>   # e.g. Debian, Ubuntu-24.04
wsl --list --online             # what is available
wsl --update                    # update the WSL platform itself
```

### Backup, clone and remove

```powershell
wsl --export <DistroName> D:\backups\<DistroName>.tar
wsl --import <NewName> D:\WSL\<NewName> D:\backups\<DistroName>.tar
wsl --unregister <DistroName>   # DESTRUCTIVE: deletes the distro and its disk
```

Export/import is the cheapest way to try a risky change: snapshot, run
`devenv --profile full`, and roll back by re-importing if you hate it.

### Configuration

```powershell
wsl --set-version <DistroName> 2
wsl -d <DistroName> --user root
```

Per-distro settings live in `/etc/wsl.conf` **inside** the distro; global settings live in
`%UserProfile%\.wslconfig` on Windows (memory, processors, swap, `networkingMode`). Neither is
written by this repository unless you explicitly allow it.

### When things are wedged

```powershell
wsl --shutdown                  # stop every distro and the VM; the usual first move
wsl --status
```

`wsl --shutdown` is also what makes a new `/etc/wsl.conf`, a new group membership or a
`systemd=true` change take effect.
