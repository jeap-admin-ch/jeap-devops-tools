# cli-oauth2-login

Obtain a **personal, traceable OAuth2 access token** on the command line and use it to
call an OIDC/OAuth2-protected REST endpoint (for example an administrative endpoint of a
microservice that has no UI of its own) — straight from a developer machine/VM.

**Audience:** DevOps engineers and developers.

**Tooling:** the [`oidc-agent`](https://indigo-dc.github.io/oidc-agent/) command-line
tools (`oidc-gen`, `oidc-token`, `oidc-add`, `oidc-keychain`) together with `curl`. We
 **delegate the OIDC/OAuth2 aspects** — the interactive login, the device
flow, encrypted refresh-token storage, automatic token refresh and token revocation — to
the oidc-agent cli tools; this guide shows how to drive those tools and hand the resulting token
to `curl`. For environments where the authorization server's published OIDC discovery
document is not directly usable from a developer machine/VM, this module also provides
[`oidc-discovery-override.sh`](../cli-oauth2-login/oidc-discovery-override.sh) (see
[section 7](#7-oidc-agent-without-direct-oidc-discovery)).

---

## 1. Overview

To call an endpoint protected with OIDC/OAuth2 you need a valid **access token**. This
guide shows how to obtain a *personal* access token (issued for **your** user, so the call is
attributable to you) on the command line and hand it to `curl`.

There are two cases:

1. **The standard case** — install `oidc-agent`, log in once, fetch a token and call the
   endpoint. This works directly against any standard, well-behaved OIDC provider.
2. **The OIDC discovery override case** — some environments publish an OIDC discovery
   document whose endpoints are not reachable from a developer machine/VM (split-horizon /
   WAF setups). There you havet to point `oidc-agent` at a local, adapted discovery
   document via the `--config-endpoint` option.

Apart from that one extra option at login time, **both cases use exactly the same
commands**: obtaining a token ([section 3](#3-obtaining-a-personal-token)), calling the
endpoint ([section 4](#4-calling-a-protected-endpoint-with-curl)), repeated use
([section 5](#5-repeated-use-oidc-keychain-oidc-add-oidc-token)) and re-login
([section 6](#6-re-login-and-logout)) are identical. The override option is introduced
in [section 3.2](#32-initial-login-oidc-gen); the background and the helper tool
that produces the local discovery document in
[sections 7–8](#7-oidc-agent-without-direct-oidc-discovery).

This guide uses the OAuth 2.0 **Device Authorization Grant** ("device flow", RFC 8628) as
the primary login method. Unlike the browser-based authorization code flow (oidc-agent's
default), the device flow needs **no local browser and no redirect** on the machine/VM
running `oidc-agent`: `oidc-gen` prints a URL and a short code, you open the URL in a
browser on *any* device, authenticate there, and `oidc-agent` keeps a refresh token so
later token requests are non-interactive and scriptable. That makes it the reliable choice
on remote or headless developer machines/VMs. If a local browser is available, the
authorization code flow can work as well (`--flow=code`) if the user is able to authenticate
to the authorization server from within the local browser.

---

## 2. Prerequisites

Requirements differ between the standard case and the OIDC discovery override case. Install only
what your situation needs.

| Scope | Requirements |
|---|---|
| **Standard case** | `oidc-agent` from your OS package manager; `curl`; direct network reachability of the authorization server and the target API host; an OAuth2 client with the device grant enabled (see [section 9](#9-creating-a-suitable-client-in-the-authorization-server)). |
| **Secure `curl` form** | `bash` and `curl` ≥ 7.55 (for `-H @file`). The recommended `oidc-token --auth-header` form additionally needs `oidc-token` ≥ 5; otherwise use the documented fallback (see [section 4](#4-calling-a-protected-endpoint-with-curl)). |
| **OIDC discovery override** | `bash` ≥ 3.2, `curl`, `jq`, and an `oidc-agent` that supports `--config-endpoint` (see [section 7](#7-oidc-agent-without-direct-oidc-discovery)). |

The standard case does not need a special `oidc-agent` build. The `oidc-agent` shipped by
your OS package manager should be able to support it. A current build is only
required for the OIDC discovery override case.

### 2.1 Installing oidc-agent

On a standard Ubuntu Linux, install `oidc-agent` from the distribution's package
repository:

```bash
sudo apt-get update
sudo apt-get install oidc-agent
```

This provides the command-line tools (`oidc-gen`, `oidc-token`, `oidc-add`,
`oidc-keychain`, `oidc-agent`) and usually is sufficient for the **standard case**. For other
operating systems, see the
[oidc-agent installation docs](https://indigo-dc.github.io/oidc-agent/installation/install.html).

If you need the **OIDC discovery override** (`--config-endpoint`) and your distribution
ships an older `oidc-agent` — Ubuntu 22.04 LTS, for example, ships 4.x — install a current
5.x build from the KIT package repository instead; see
[section 7.1](#71-installing-a-current-oidc-agent-from-the-kit-repository).

### 2.2 Keeping the oidc-agent alive across shells

Add this to your `~/.bashrc` so a single persistent agent is started/reused for every shell
(token and password caches survive between sessions):

```bash
eval "$(oidc-keychain)"
```

---

## 3. Obtaining a personal token

This is standard `oidc-agent`. For the full command and option reference see the
[oidc-agent documentation](https://indigo-dc.github.io/oidc-agent/) (or `man oidc-gen` /
`oidc-gen --help`). The steps below apply to **both** cases but in the **OIDC discovery
override** case you add the option (`--config-endpoint`) to the initial login, shown
in [section 3.2](#32-initial-login-oidc-gen).

### 3.1 The account concept

In `oidc-agent` terminology an **account** (or *account configuration*) is a named, locally
stored login profile: it bundles the issuer, client, scope and flow together with the
encrypted refresh token under a short name — the **account shortname** — that you choose.
That shortname is the **first argument** to `oidc-gen`, and **every later command
addresses the login by exactly this name** (`oidc-add <name>`, `oidc-token <name>`,
`oidc-gen <name> --reauthenticate`, `oidc-gen -d <name>`). Pick it deliberately; this guide
uses `myservice`.

### 3.2 Initial login (`oidc-gen`)

Make sure the agent is running (`oidc-gen` talks to it), then create the account once:

```bash
eval "$(oidc-keychain)"     # ensure the agent is running (skip if it is in your ~/.bashrc)
oidc-gen myservice \
  --flow=device \
  --issuer="https://auth.example.com/realms/example" \
  --client-id="devops-cli" \
  --scope="openid profile" \
  --redirect-uri=""
```

`oidc-gen` will then:

- print a **URL and a user code** (and a QR code you can ignore) — open the URL in any
  browser, enter the code, and authenticate with your personal account;
- finally ask you to set an **encryption password** under which the account (including its
  refresh token) is stored locally.

After `oidc-gen` succeeds, the account is **already loaded** into the agent — you can fetch
a token right away with `oidc-token myservice`.

A few notes on the options:

- **Scopes — `openid profile`.** This guide deliberately does **not** request
  `offline_access`. The refresh token is bound to the online SSO session rather than
  issued as a long-lived offline token; when it expires, re-authenticate (see
  [section 6](#6-re-login-and-logout)). Add scopes only if the target resource server
  needs them in the token.
- **`--redirect-uri=""`** stops `oidc-gen` from interactively asking for redirect URIs —
  the device flow does not use them.
- **Client secret (confidential clients).** If your client is confidential, `oidc-gen` will
  prompts for the secret interactively. A **confidential** device-flow client relies on a
  statically distributed client secret — share it only with authorized engineers. A **public**
  client has no secret at all.

#### OIDC discovery override
If the authorization server's published discovery document is not directly usable from your
developer machine/VM because it advertises unreachable endpoints, point `oidc-gen` at an
adapted discovery document by adding a single extra option (`--config-endpoint`) — everything
else stays the same:

```bash
oidc-gen myservice \
  --flow=device \
  --issuer="https://auth.example.com/realms/example" \
  --client-id="devops-cli" \
  --scope="openid profile" \
  --redirect-uri="" \
  --config-endpoint="file://$HOME/.config/oidc-agent/myservice.discovery.json"
```

- You provide a JSON file that stands in for the server's discovery document, with
  unreachable endpoint URLs rewritten to a reachable host.
- Generate the file once with [`oidc-discovery-override.sh`](../cli-oauth2-login/oidc-discovery-override.sh) and keep it at a **stable,
  persistent** path (this guide uses `~/.config/oidc-agent/<name>.discovery.json`) —
  `oidc-agent` stores the `file://` path in the account and re-reads it on every token
  refresh. See [section 8](#8-the-oidc-discovery-overridesh-tool) for the tool and
  [section 7](#7-oidc-agent-without-direct-oidc-discovery) for the background.

---

## 4. Calling a protected endpoint with curl

Fetch an access token with `oidc-token` and pass it to `curl` as a Bearer header. The token must
never appear on `curl`'s command line (where it would show up in `ps` 
`/proc/<pid>/cmdline`).

### Recommended form
`oidc-token --auth-header` (alias `--auth`) prints a complete
`Authorization: Bearer <token>` header line; `-H @<file>` makes `curl` (≥ 7.55) read the
header from a file, and bash process substitution `<(…)` exposes that line as a file
descriptor. The token stays out of the process list, and `oidc-agent` formats the header
for you:

```bash
curl -H @<(oidc-token --auth-header myservice) \
  https://api.example.com/<service>/<path>
```

### Fallback
For an older `oidc-token` without `--auth-header` — same security property,
just formatting the header yourself:

```bash
curl -H @<(printf 'Authorization: Bearer %s\n' "$(oidc-token myservice)") \
  https://api.example.com/<service>/<path>
```

### Result
Right after the initial login the account is **already loaded**
([section 3.2](#32-initial-login-oidc-gen)), so `oidc-token` works immediately and
non-interactively. In a later shell session, load it first (see
[section 5](#5-repeated-use-oidc-keychain-oidc-add-oidc-token)).

**Note: an `oidc-token` failure does not fail the `curl`.** Because `oidc-token` runs inside
the process substitution `<(…)`, its exit code never reaches `curl`: if no token can be
obtained (agent not running, refresh token expired), `curl` simply sends an empty/broken
`Authorization` header and you get a confusing `401`. In scripts, obtain (and thereby
verify) the token in a separate step first:

```bash
oidc-token myservice >/dev/null || { echo "no access token — re-login needed?" >&2; exit 1; }
curl -H @<(oidc-token --auth-header myservice) https://api.example.com/<service>/<path>
```

**Troubleshooting:**  If your network requires a proxy, remember that `curl` honors
`http_proxy` / `https_proxy` / `no_proxy`; hosts that must be reached directly belong
in `no_proxy` (or pass `--noproxy`).

---

## 5. Repeated use (oidc-keychain, oidc-add, oidc-token)

When you need a token after the initial login but the account is **not currently loaded in a
running agent** — typically in a **new shell session** or after a **reboot** — execute the
command flow below. It requires **no re-login**: as long as the stored refresh token is still
valid, the three commands (re)start or reuse the agent, load the account, and get a valid
access token. (Right after `oidc-gen` the account is already loaded into the agent, so
the first call in [section 4](#4-calling-a-protected-endpoint-with-curl) needs none of these
steps.) 

```bash
eval "$(oidc-keychain)"     # start or reuse the persistent agent (also fine in ~/.bashrc)
oidc-add myservice          # load the account into the agent (optional — see note below)
oidc-token myservice        # print a valid access token to stdout (auto-refresh)
```

- `oidc-add` is **optional**: if you skip it, the first `oidc-token` for an unloaded
  account **autoloads** it and prompts once for the encryption password. Running `oidc-add`
  explicitly (optionally with `--pw-store` to cache the password) just makes that prompt
  predictable — useful before non-interactive scripted calls.
- `oidc-token` returns the cached access token, transparently refreshing it via the stored
  refresh token when necessary. To require a minimum remaining lifetime, use `-t` — e.g.
  `oidc-token myservice -t 180` guarantees the token is valid for at least another 3
  minutes (refreshing it early if necessary).
- Once the account is loaded, `oidc-token` is **non-interactive** — safe in scripts.

If the refresh token has expired, re-authenticate instead — see
[section 6](#6-re-login-and-logout). And if you added `eval "$(oidc-keychain)"` to your
`~/.bashrc` ([section 2.2](#22-keeping-the-oidc-agent-alive-across-shells)), the agent and its
loaded account already persist across shells, in which case usually only the final
`oidc-token myservice` is left to run.

---

## 6. Re-login and logout

| Goal | Command |
|---|---|
| Re-authenticate (refresh token expired) | `oidc-gen myservice --reauthenticate --flow=device` |
| Remove the login (tokens no longer on the machine/VM) | `oidc-gen -d myservice` |

`oidc-gen -d` deletes the encrypted account file (including the refresh token) and attempts
a server-side revocation via the `revocation_endpoint`. Note that `oidc-add -r myservice`
only **unloads** the account from the running agent — the refresh token stays on disk and a
later `oidc-token` would reload it; use `oidc-gen -d` to actually remove it.

---

## 7. oidc-agent without direct OIDC discovery

In some environments the standard flow fails because of how the authorization server
publishes its OIDC **discovery document** (`/.well-known/openid-configuration`).

A common case is a **split-horizon / WAF** setup: the server publishes its `issuer` under
an **external** host name, but the OIDC endpoints that actually work from a developer
machine/VM live on an **internal** host — and the discovery document advertises the
*external* endpoint URLs even when fetched from the internal host.

`oidc-agent` then does two things that make this fail:

1. it takes the endpoints (device authorization, token, revocation, …) straight from the
   discovery document — i.e. the unreachable URLs; and
2. it **enforces** that the `issuer` in the discovery document matches the configured
   `--issuer`.

The fix is a **local discovery document** that keeps `issuer` at its published value (to
satisfy the issuer match and because tokens must carry that issuer) but rewrites the
relevant endpoints to the reachable host. You hand this file to `oidc-gen` via
`--config-endpoint=file://<path>` ([section 3.2](#32-initial-login-oidc-gen)) and generate
it with the [`oidc-discovery-override.sh`](#8-the-oidc-discovery-overridesh-tool) tool.

**Important: keep the local discovery document! ** `oidc-agent` stores
the `config_endpoint` (the `file://` path) in the account and **re-reads the file on every
token refresh**. Therefore, put the discovery document file at a stable, persistent path
(this guide uses `~/.config/oidc-agent/<name>.discovery.json`). A temporary file that gets
cleaned up would break the next refresh.

The discovery document describes the **realm / authorization server** (its `issuer` and
endpoint URLs), not any single OAuth2 client. The client id, secret, scope and flow are
supplied to `oidc-gen` at login time and never appear in the override file
([section 8](#8-the-oidc-discovery-overridesh-tool)). So you create the override **once for
a realm** and then reuse the very same `file://` path for **as many `oidc-gen` logins as
you need** — one per client defined in that realm — each under its own account shortname.
For example, a single `~/.config/oidc-agent/example-realm.discovery.json` can back both an
`oidc-gen serviceA --client-id=devops-cli-a …` and an
`oidc-gen serviceB --client-id=devops-cli-b …`, as long as both clients live in the same
realm and thus share the same issuer and endpoints. You only have to regenerate the file
when the **realm's** endpoints themselves change — not when you add another client or
create another account.

### 7.1 Installing a current oidc-agent from the KIT repository

The `--config-endpoint` option requires a recent `oidc-agent` version (v5+). Check your
installation:

```bash
oidc-gen --help 2>&1 | grep -q -- --config-endpoint \
  && echo "config-endpoint supported" \
  || echo "oidc-agent too old for the discovery override"
```

If your distribution ships an older version (Ubuntu 22.04 LTS, for example, ships
`oidc-agent` 4.x), install a current build from the package repository provided by the
**Karlsruhe Institute of Technology (KIT)**, which builds and signs `oidc-agent` packages
for many distributions:

```bash
# 1. Trust the KIT package-signing key
sudo curl -fsSL https://repo.data.kit.edu/repo-data-kit-edu-key.asc \
  -o /etc/apt/trusted.gpg.d/kitrepo-archive.asc

# 2. Add the KIT repository (example: Ubuntu 22.04 "jammy")
echo "deb [signed-by=/etc/apt/trusted.gpg.d/kitrepo-archive.asc] https://repo.data.kit.edu/ubuntu/jammy ./" \
  | sudo tee /etc/apt/sources.list.d/kit-repo.list

# 3. Install the command-line tools (no desktop/GUI dependencies)
sudo apt-get update
sudo apt-get install oidc-agent-cli
```

`oidc-agent-cli` installs exactly the five command-line programs and no GUI dependencies —
the correct choice for a (possibly headless) developer machine/VM.

---

## 8. The oidc-discovery-override.sh tool

You do not have to craft the local discovery document by hand.
[`oidc-discovery-override.sh`](../cli-oauth2-login/oidc-discovery-override.sh) downloads the discovery document published by an auth server,
forces the configured `issuer`, overrides the endpoints you list in a configuration file and writes
the result to a local file.

Note: The configuration file only addresses values in the discovery document (endpoint overrides). It is
not an OAuth2 client configuration — the client id, secret, scope and flow are passed to `oidc-gen`, not set here.

**Dependencies:** `bash` ≥ 3.2, `curl`, `jq`.

### 8.1 Configuration model

One `KEY=value` per line. `#` starts a comment line (inline comments after a value are
**not** supported). Values may be double- or single-quoted. The file is parsed line by line
and never sourced. Keys correspond to the property names of the OIDC discovery document
(snake_case):

| Key | Required | Meaning |
|---|---|---|
| `issuer` | **yes** | The published issuer URL. Always written into the result (issuer match). |
| `oidc_provider_configuration_endpoint` | no | Explicit discovery URL to download the base document from (typically the reachable host). If absent, `<issuer>/.well-known/openid-configuration` is used. |
| `<name>_endpoint` / `<name>_uri` | no | Any number of endpoint overrides, e.g. `device_authorization_endpoint`, `token_endpoint`, `revocation_endpoint`, `jwks_uri`. Each replaces the property of the same name. |

Notes:

- Setting `oidc_provider_configuration_endpoint` only controls **where the base document is
  fetched**; it does not change the endpoint *values* inside it. If the server returns
  external URLs even on the internal host, list the endpoints you need explicitly as
  overrides.
- Only properties the auth server actually publishes are replaced; anything else is skipped
  with a warning (typo protection). Unknown non-endpoint keys are ignored with a notice.
- Writing is **atomic** and idempotent: a failed run never destroys a previously generated
  file.

See [`override-example.conf`](../cli-oauth2-login/override-example.conf) for a
complete starting point.

### 8.2 Generating the discovery document

This example keeps the config file and the generated discovery document under the persistent
path ~/.config/oidc-agent:

```bash
mkdir -p ~/.config/oidc-agent
cp override-example.conf ~/.config/oidc-agent/myservice.conf   # then edit it
./oidc-discovery-override.sh \
  -o ~/.config/oidc-agent/myservice.discovery.json \
  ~/.config/oidc-agent/myservice.conf
```

Without `-o`, the script writes `<config-name>.discovery.json` next to the config file —
with the config at `~/.config/oidc-agent/myservice.conf` that is exactly the path above, so
`-o` is optional here; `-o -` prints the result to stdout. Exit codes: `0` success, `1` runtime/config error,
`2` usage error. Run `./oidc-discovery-override.sh --help` for the full usage.

### 8.3 Logging in with the overridden discovery document

Log in exactly as in [section 3.2](#32-initial-login-oidc-gen) but add the option `--config-endpoint`:

```bash
eval "$(oidc-keychain)"     # start/reuse the agent FIRST — oidc-gen talks to it (skip if in ~/.bashrc)
oidc-gen myservice \
  --flow=device \
  --issuer="https://auth.example.com/realms/example" \
  --client-id="devops-cli" \
  --scope="openid profile" \
  --redirect-uri="" \
  --config-endpoint="file://$HOME/.config/oidc-agent/myservice.discovery.json"
```

### 8.5 Proxies and timeouts

- The script does not manage proxies itself — `curl` natively honors `http_proxy`
  (lowercase only; `curl` deliberately ignores upper-case `HTTP_PROXY`),
  `https_proxy` / `HTTPS_PROXY`, `all_proxy`, and `no_proxy` / `NO_PROXY` (comma-separated
  host suffixes contacted directly), plus `~/.curlrc` and `CURL_CA_BUNDLE`. Internal hosts
  that must bypass a corporate proxy belong in `no_proxy`. On a failed download the script
  prints the active proxy variables as a diagnostic.
- The download fails fast instead of hanging. Override the timeouts via
  `OIDC_DISCOVERY_CONNECT_TIMEOUT` (default 5 s) and `OIDC_DISCOVERY_MAX_TIME` (default
  15 s).

---

## 9. Creating a suitable client in the authorization server

Personal access tokens are fetched from an authorization-server client (e.g. a Keycloak client) with
the **device grant** enabled. Create such a client with the following properties:

**Client type:**
   - **Confidential (recommended).** The server generates a **client secret**; pass it as
     described in [section 3.2](#32-initial-login-oidc-gen). Requiring the secret to redeem
     the device code protects against the device-code *phishing* attack vector.
   - **Public.** No secret; simpler, but without the phishing protection above.

**Capability config:** enable the **OAuth 2.0 Device Authorization Grant**. Other flows are not required.

**Refresh tokens:** enable issuing refresh tokens on the client, so an access token can be renewed with a refresh token.
Silent-renew is not available for the device flow.

**Client session maximum lifespan:** keep the client's maximum session lifespan short for security reasons (e.g. 1h).

**Redirect URIs:** none needed (the device flow uses no redirect).

Because login is interactive (the user authenticates in the browser during the device
flow), every call made with the resulting token is attributable to the individual.

---

## 10. Reference

- oidc-agent documentation (commands, options, concepts): [https://indigo-dc.github.io/oidc-agent/](https://indigo-dc.github.io/oidc-agent/)
- OAuth 2.0 Device Authorization Grant (RFC 8628): [https://www.rfc-editor.org/rfc/rfc8628](https://www.rfc-editor.org/rfc/rfc8628)

Maintainers of this tool: see [`tests/README.md`](../cli-oauth2-login/tests/README.md) for how to run the
test suite.
