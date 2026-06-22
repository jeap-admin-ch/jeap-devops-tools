# cli-oauth2-login — maintainer notes

This folder holds the automated test suite for
[`oidc-discovery-override.sh`](../oidc-discovery-override.sh) and the script to run it. It
is aimed at **maintainers** of `cli-oauth2-login` — not at users of the `oidc-agent` /
`oidc-discovery-override.sh` workflow. Users should read the [user guide](../../docs/cli-oauth2-login.md).

## Running the tests

The tests use [bats-core](https://bats-core.readthedocs.io) (`apt install bats` or
`brew install bats-core`, ≥ 1.2):

```sh
./run-tests.sh        # from this tests/ directory — or, from anywhere: bats path/to/tests
```

`run-tests.sh` checks that `bats` is installed and runs every `*.bats` file in this
directory.

## Test layout

- `unit.bats` — unit tests: the script is sourced (its main guard prevents execution) and
  individual functions are exercised directly.
- `cli.bats` — end-to-end tests: the script runs as a black box; instead of network access,
  a `curl` stub placed on the `PATH` serves a sample response
  (`fixtures/keycloak-discovery.json`) or simulates failures.
- `helpers.bash` — shared setup/teardown and assertion helpers loaded by both `.bats`
  files. It locates the script under test as `../oidc-discovery-override.sh`, so the suite
  must stay one directory below the script.
- `fixtures/` — static fixtures (e.g. a sample Keycloak discovery document) used by the
  CLI tests.
