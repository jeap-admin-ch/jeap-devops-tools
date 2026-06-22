# jeap-devops-tools

A home for tools and documentation that help developers and DevOps engineers **develop,
maintain and operate** jEAP-based applications.

## Contents

| Entry | Type | Description |
|---|---|---|
| [`cli-oauth2-login`](./docs/cli-oauth2-login.md) | Tool + guide | Obtain a personal, traceable OAuth2 access token on the command line (oidc-agent + curl) and call OIDC/OAuth2-protected endpoints. Includes `oidc-discovery-override.sh` for environments where the authorization server's published OIDC discovery document is not directly usable from a developer machine/VM. |

Detailed documentation for each entry lives in [`docs/`](./docs) under the entry's name
(for example [`docs/cli-oauth2-login.md`](./docs/cli-oauth2-login.md)). New tools and
documentation supporting the development, maintenance and operation of jEAP-based
applications may be added over time.

## Changes

This repository is versioned using [Semantic Versioning](https://semver.org/) and all
changes are documented in [CHANGELOG.md](./CHANGELOG.md), following the format defined in
[Keep a Changelog](https://keepachangelog.com/).

## Note

This repository is part of the open source distribution of jEAP. See
[github.com/jeap-admin-ch/jeap](https://github.com/jeap-admin-ch/jeap) for more
information.

## License

This repository is Open Source Software licensed under the
[Apache License 2.0](./LICENSE).
