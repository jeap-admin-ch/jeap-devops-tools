# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-22

### Added
- Initial release of jeap-devops-tools.
- `cli-oauth2-login`: obtain a personal, traceable OAuth2 access token from the command line
  using oidc-agent and curl to call OIDC/OAuth2-protected endpoints.
- `cli-oauth2-login`: `oidc-discovery-override.sh` to adapt an OIDC discovery document for
  developer machines/VMs in split-horizon / WAF environments where the auth server's
  published discovery document is not directly usable.
