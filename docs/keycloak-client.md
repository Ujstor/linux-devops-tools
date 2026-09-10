# Keycloak client checklist (the identity-provider side)

[docs/sso.md](sso.md) is the box side: shims, tunnels and commands. This page is the other half —
what has to be true in Keycloak and on the API server before any of it works. Hand it to whoever
administers the realm.

**Everything here is a placeholder.** This repository is public: `sso.example.com`,
`REALM_PLACEHOLDER`, `CLIENT_ID_PLACEHOLDER`, `ROLE_PLACEHOLDER` and `<your-group>` are literal
placeholders, and the only place a real value is ever written on a workstation is
`~/.config/devops-env/sso.env` (mode 0600, gitignored).

Throughout:

```sh
OIDC_ISSUER_URL="https://sso.example.com/realms/REALM_PLACEHOLDER"
OIDC_CLIENT_ID="CLIENT_ID_PLACEHOLDER"     # e.g. `kubernetes`
```

---

## 1. The kubectl client

One **public** client, shared by every cluster. This is what makes "one login, every cluster" true:
the kubelogin token cache is keyed on issuer + client id + scopes + redirect URL, so a single client
and a single kubeconfig user stanza mean a single cached token.

| Setting | Value | Why |
|---|---|---|
| Client ID | `CLIENT_ID_PLACEHOLDER` | must match `--oidc-client-id` exactly |
| Client authentication | **Off** (public client) | a secret in `users[].user.exec.args` is plaintext in `~/.kube/config` and visible in `ps` on every `kubectl` call |
| Standard flow | **On** | this is the authorization-code flow |
| Direct access grants | **Off** | password grant; nothing here uses it and it weakens the client |
| Implicit flow | **Off** | deprecated |
| Service accounts roles | **Off** | not a machine client |
| Proof Key for Code Exchange (PKCE) | **`S256`, required** | a public client without PKCE is interceptable. kubelogin's default is `--oidc-pkce-method=auto`, which negotiates S256 |
| Front channel logout | optional | irrelevant to a CLI |
| Access token lifespan | 5–15 min | short is fine: the refresh token is what the cache keeps |
| SSO session idle / max | your policy | this is what decides how often you actually log in |

### Valid redirect URIs

Register **all three** on the kubectl client, so one client covers a workstation with a tunnel, a
workstation without one, and the 18000 fallback port:

```
http://localhost:8000/*
http://localhost:18000/*
urn:ietf:wg:oauth:2.0:oob
```

* `8000` is what `sso-kubeconfig-add` pins with `--listen-address=127.0.0.1:8000`. Pinning it is
  what makes the redirect URL — and therefore the token-cache key — deterministic.
* `18000` is kubelogin's own fallback when 8000 is taken. Register it or a busy port turns into a
  confusing failure.
* The `urn:` value is the out-of-band, paste-the-code flow (`--grant-type=authcode-keyboard`), used
  on any host where no `ssh -L` tunnel is possible.

Keycloak also needs **Web origins** set (`+` is enough to mirror the redirect URIs) if you ever open
the account console from the same client.

### The `groups` mapper — the one that is always missing

Kubernetes RBAC binds to group *names*. Without this mapper you authenticate successfully and then
get `Unauthorized` or `forbidden` on everything, which reads like a broken login but is not one.

Client scopes → the client's dedicated scope → **Add mapper** → **By configuration** →
**Group Membership**:

| Field | Value |
|---|---|
| Name | `groups` |
| Token Claim Name | `groups` |
| Full group path | **Off** |
| Add to ID token | **On** |
| Add to access token | On (harmless) |
| Add to userinfo | On (harmless) |

**Full group path off** matters: with it on, the claim is `/platform/admins` and RBAC `Group`
subjects — which have no leading slash — will never match.

If you serve the claim through a non-default scope, add that scope's name to `OIDC_GROUPS_SCOPE` in
`sso.env`; the kubeconfig requests it as `--oidc-extra-scope=<name>`. Keep the extra-scope list
**identical on every host**: the list, including its order, is part of the token-cache key.

### API server flags

The cluster must trust the same issuer. Structured `AuthenticationConfiguration` is the modern form;
the flag form is equivalent and shown here because it is what `kubectl oidc-login setup` prints:

```
--oidc-issuer-url=https://sso.example.com/realms/REALM_PLACEHOLDER
--oidc-client-id=CLIENT_ID_PLACEHOLDER
--oidc-username-claim=preferred_username
--oidc-username-prefix=oidc:
--oidc-groups-claim=groups
```

`--oidc-username-prefix=oidc:` keeps OIDC identities in their own namespace so they can never
collide with a certificate or service-account subject. Remember it when writing bindings —
the user is `oidc:alice`, not `alice`.

If the IdP's certificate is not signed by a public CA, the API server needs
`--oidc-ca-file=/path/to/idp-ca.pem`, and each workstation needs
`--certificate-authority=~/.kube/idp-ca.pem` in the exec args. That flag *does* expand `~`.
**Never** reach for `--insecure-skip-tls-verify`.

### A binding to prove it works

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-cluster-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: <your-group>          # exactly as it appears in the `groups` claim
```

Verify from the workstation:

```bash
kubectl oidc-login setup \
  --oidc-issuer-url="$OIDC_ISSUER_URL" \
  --oidc-client-id="$OIDC_CLIENT_ID"    # prints the decoded claims — look for `groups`

kubectl auth whoami                     # the mapped username and groups
kubectl auth can-i --list               # proves the binding landed
```

---

## 2. The other clients

Argo CD and OpenBao each need their **own** client — different redirect URI, different audience,
different lifetime policy. Do not reuse the kubectl client for them.

| Client | Type | Redirect URI(s) | Notes |
|---|---|---|---|
| Argo CD | public or confidential (Argo CD supports both) | `http://localhost:8085/auth/callback` for the CLI, plus `https://argocd.example.com/auth/callback` for the web UI | the CLI port is `--sso-port`; register whatever you standardise on |
| OpenBao — `callbackmode=device` | public | **none at all** | the device flow has no redirect. This is the cleanest headless path there is |
| OpenBao — `callbackmode=client` | public | `http://localhost:8250/oidc/callback` | register `127.0.0.1`, not `localhost`, if your users are on Chromium — it resolves `localhost` to `::1` first |
| OpenBao — `callbackmode=direct` | public | `https://openbao.example.com:8200/v1/auth/oidc/oidc/callback` | the server receives the callback; it shows an anti-phishing confirmation page with the requester's IP |
| Terraform (`terraform login`) | as the host requires | `http://localhost:10000` … `10009` | the login protocol asks hosts to register ten consecutive ports |

GitHub and GitLab are not Keycloak clients at all — `gh` uses GitHub's device flow, and `glab` has a
first-class `--device`. Nothing to configure on the IdP.

---

## 3. Why there is no client secret

A confidential client would have to put its secret somewhere the exec plugin can read it:

* `users[].user.exec.args` — plaintext in `~/.kube/config`, **and** visible in `ps` output on every
  single `kubectl` invocation, to every user on the box.
* `users[].user.exec.env` — plaintext in `~/.kube/config`, marginally better, still a shared secret
  distributed to every workstation.

Neither is a secret in any meaningful sense: it is shipped to every client, so it authenticates
nothing. That is exactly the case OAuth 2.1 marks as *public client + PKCE*. Push for the public
client. If realm policy truly forbids it, use `env:` rather than `args:` and treat the value as
public anyway.

`devenv doctor` warns when it finds `--oidc-client-secret` in a kubeconfig exec stanza, and fails on
`--oidc-use-pkce`, a flag that no longer exists (the current one is
`--oidc-pkce-method (auto|no|S256)`).

---

## 4. Checklist

Before handing the realm back:

- [ ] Client is **public**, standard flow on, direct access grants off, PKCE `S256` required.
- [ ] All three kubectl redirect URIs registered (`8000`, `18000`, `urn:…:oob`).
- [ ] Group Membership mapper: claim `groups`, **Add to ID token on**, **Full group path off**.
- [ ] API server has issuer, client id, `--oidc-groups-claim=groups`, a username prefix.
- [ ] At least one `ClusterRoleBinding` to a real group in the claim.
- [ ] Argo CD and OpenBao have their **own** clients with their own redirect URIs.
- [ ] IdP certificate chains to a CA the API server and the workstations trust.
- [ ] Clock sync is real on every party — Keycloak's default allowable skew is **0 seconds**, and a
      WSL2 box whose Windows host slept is the classic source of `invalid_grant` immediately after a
      successful login.

Everything on the workstation side, including the tunnels and the per-provider commands, is in
[docs/sso.md](sso.md).
