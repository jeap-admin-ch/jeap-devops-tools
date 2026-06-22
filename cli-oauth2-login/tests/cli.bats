#!/usr/bin/env bats
# End-to-end tests: run the script as a black box. Network access is replaced
# by a curl stub placed on PATH, controlled via CURL_STUB_* variables:
#   CURL_STUB_ARGS_FILE  the stub records its arguments here (one per line)
#   CURL_STUB_BODY       file played back as the response body
#   CURL_STUB_EXIT       non-zero to simulate a curl failure

load helpers

EXT_BASE="https://auth.example.com/realms/example"
INT_BASE="https://auth.internal.example.com/realms/example"

setup() {
  common_setup
  STUB_DIR="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CURL_STUB_ARGS_FILE:?}"
if [[ ${CURL_STUB_EXIT:-0} -ne 0 ]]; then
  echo "curl: (${CURL_STUB_EXIT}) simulated failure" >&2
  exit "${CURL_STUB_EXIT}"
fi
cat "${CURL_STUB_BODY:?}"
EOF
  chmod +x "$STUB_DIR/curl"
  PATH="$STUB_DIR:$PATH"
  export CURL_STUB_ARGS_FILE="$TEST_TMPDIR/curl-args"
  export CURL_STUB_BODY="$FIXTURES/keycloak-discovery.json"

  CONF="$TEST_TMPDIR/example.conf"
  cat > "$CONF" <<EOF
issuer="$EXT_BASE"
oidc_provider_configuration_endpoint="$INT_BASE/.well-known/openid-configuration"
device_authorization_endpoint="$INT_BASE/protocol/openid-connect/auth/device"
token_endpoint="$INT_BASE/protocol/openid-connect/token"
revocation_endpoint="$INT_BASE/protocol/openid-connect/revoke"
EOF
  DEFAULT_OUT="$TEST_TMPDIR/example.discovery.json"
}

teardown() {
  common_teardown
}

@test "happy path: writes <name>.discovery.json with overridden endpoints" {
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  [ -f "$DEFAULT_OUT" ]
  assert_equal "$(jq -r '.issuer' "$DEFAULT_OUT")" "$EXT_BASE"
  assert_equal "$(jq -r '.token_endpoint' "$DEFAULT_OUT")" "$INT_BASE/protocol/openid-connect/token"
  assert_equal "$(jq -r '.device_authorization_endpoint' "$DEFAULT_OUT")" "$INT_BASE/protocol/openid-connect/auth/device"
  assert_equal "$(jq -r '.revocation_endpoint' "$DEFAULT_OUT")" "$INT_BASE/protocol/openid-connect/revoke"
  # properties not configured stay exactly as published by the auth server
  assert_equal "$(jq -r '.authorization_endpoint' "$DEFAULT_OUT")" "$EXT_BASE/protocol/openid-connect/auth"
  assert_equal "$(jq -r '.jwks_uri' "$DEFAULT_OUT")" "$EXT_BASE/protocol/openid-connect/certs"
  assert_contains "$output" "applied 3 override(s)"
}

@test "overrides *_uri properties such as jwks_uri" {
  printf 'jwks_uri="%s/protocol/openid-connect/certs"\n' "$INT_BASE" >> "$CONF"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  assert_equal "$(jq -r '.jwks_uri' "$DEFAULT_OUT")" "$INT_BASE/protocol/openid-connect/certs"
  assert_contains "$output" "applied 4 override(s)"
}

@test "uses the explicit oidc_provider_configuration_endpoint as download URL" {
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  grep -qxF "$INT_BASE/.well-known/openid-configuration" "$CURL_STUB_ARGS_FILE"
}

@test "derives the discovery URL from the issuer when no explicit endpoint is set" {
  grep -v '^oidc_provider_configuration_endpoint=' "$CONF" > "$CONF.tmp"
  mv "$CONF.tmp" "$CONF"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  grep -qxF "$EXT_BASE/.well-known/openid-configuration" "$CURL_STUB_ARGS_FILE"
}

@test "invokes curl with fail-fast options" {
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  grep -qx -- '--fail' "$CURL_STUB_ARGS_FILE"
  grep -qx -- '--connect-timeout' "$CURL_STUB_ARGS_FILE"
  grep -qx -- '--max-time' "$CURL_STUB_ARGS_FILE"
}

@test "override for a property the auth server does not publish is skipped with a warning" {
  printf 'end_sesion_endpoint="%s/typo"\n' "$INT_BASE" >> "$CONF"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  assert_contains "$output" "override skipped (typo?)"
  run jq -e 'has("end_sesion_endpoint") | not' "$DEFAULT_OUT"
  [ "$status" -eq 0 ]
}

@test "unknown non-endpoint keys are ignored with a warning" {
  printf 'client_id=some-client\n' >> "$CONF"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  assert_contains "$output" "ignoring unknown key 'client_id'"
  run jq -e 'has("client_id") | not' "$DEFAULT_OUT"
  [ "$status" -eq 0 ]
}

@test "fails fast with a clear message and proxy diagnostics when the download fails" {
  export CURL_STUB_EXIT=7
  export http_proxy="http://proxy.example.com:3128"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 1 ]
  assert_contains "$output" "could not download the discovery document"
  assert_contains "$output" "http_proxy=http://proxy.example.com:3128"
  [ ! -e "$DEFAULT_OUT" ]
}

@test "a failing run never destroys a previously generated file" {
  echo '{"marker":"keep-me"}' > "$DEFAULT_OUT"
  export CURL_STUB_EXIT=28
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 1 ]
  assert_equal "$(jq -r '.marker' "$DEFAULT_OUT")" "keep-me"
}

@test "a response failing validation never destroys a previously generated file" {
  echo '{"marker":"keep-me"}' > "$DEFAULT_OUT"
  echo 'this is not json' > "$TEST_TMPDIR/body"
  export CURL_STUB_BODY="$TEST_TMPDIR/body"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 1 ]
  assert_equal "$(jq -r '.marker' "$DEFAULT_OUT")" "keep-me"
}

@test "handles config and output paths containing spaces" {
  local dir="$TEST_TMPDIR/dir with spaces"
  mkdir -p "$dir"
  cp "$CONF" "$dir/my login.conf"
  run "$SCRIPT" "$dir/my login.conf"
  [ "$status" -eq 0 ]
  [ -f "$dir/my login.discovery.json" ]
  run "$SCRIPT" -o "$dir/out put.json" "$CONF"
  [ "$status" -eq 0 ]
  [ -f "$dir/out put.json" ]
}

@test "fails with a clear message when jq is missing" {
  local bindir="$TEST_TMPDIR/limited-bin" saved_path=$PATH
  mkdir -p "$bindir"
  ln -s "$(command -v bash)" "$bindir/bash"
  ln -s "$(command -v curl)" "$bindir/curl"
  PATH=$bindir
  run "$SCRIPT" "$CONF"
  PATH=$saved_path
  [ "$status" -eq 1 ]
  assert_contains "$output" "required tool 'jq' not found"
}

@test "fails with a clear message when curl is missing" {
  local bindir="$TEST_TMPDIR/limited-bin" saved_path=$PATH
  mkdir -p "$bindir"
  ln -s "$(command -v bash)" "$bindir/bash"
  ln -s "$(command -v jq)" "$bindir/jq"
  PATH=$bindir
  run "$SCRIPT" "$CONF"
  PATH=$saved_path
  [ "$status" -eq 1 ]
  assert_contains "$output" "required tool 'curl' not found"
}

@test "values with attempted inline comments are rejected" {
  printf 'userinfo_endpoint=%s/userinfo # internal host\n' "$INT_BASE" >> "$CONF"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 1 ]
  assert_contains "$output" "contains whitespace"
}

@test "rejects a response that is not valid JSON" {
  echo '<html>WAF says no</html>' > "$TEST_TMPDIR/body"
  export CURL_STUB_BODY="$TEST_TMPDIR/body"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not valid JSON"
  [ ! -e "$DEFAULT_OUT" ]
}

@test "rejects JSON without an issuer property" {
  echo '{"foo":"bar"}' > "$TEST_TMPDIR/body"
  export CURL_STUB_BODY="$TEST_TMPDIR/body"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not an OIDC discovery document"
}

@test "warns when the downloaded issuer differs and forces the configured issuer" {
  jq '.issuer = "https://somewhere.else.example.com/realms/other"' \
    "$FIXTURES/keycloak-discovery.json" > "$TEST_TMPDIR/body"
  export CURL_STUB_BODY="$TEST_TMPDIR/body"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  assert_contains "$output" "differs from the configured issuer"
  assert_equal "$(jq -r '.issuer' "$DEFAULT_OUT")" "$EXT_BASE"
}

@test "-o writes to a custom path" {
  run "$SCRIPT" -o "$TEST_TMPDIR/custom.json" "$CONF"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/custom.json" ]
  [ ! -e "$DEFAULT_OUT" ]
}

@test "-o - prints the result to stdout" {
  # pipefail so a script failure is not masked by jq's exit status
  run bash -c "set -o pipefail; '$SCRIPT' -o - '$CONF' 2>/dev/null | jq -r '.token_endpoint'"
  [ "$status" -eq 0 ]
  assert_equal "$output" "$INT_BASE/protocol/openid-connect/token"
}

@test "http (non-https) URLs are accepted with a warning" {
  printf 'issuer="http://localhost:8080/realms/dev"\n' > "$CONF"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 0 ]
  assert_contains "$output" "insecure http"
}

@test "--help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage:"
}

@test "--help after -- is treated as a filename, not as help" {
  run "$SCRIPT" -- --help
  [ "$status" -eq 1 ]
  assert_contains "$output" "config file not found: --help"
}

@test "missing arguments is a usage error (exit 2)" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  assert_contains "$output" "Usage:"
}

@test "missing config file fails with a clear message" {
  run "$SCRIPT" "$TEST_TMPDIR/nope.conf"
  [ "$status" -eq 1 ]
  assert_contains "$output" "config file not found"
}

@test "config without issuer fails" {
  printf 'token_endpoint="%s/protocol/openid-connect/token"\n' "$INT_BASE" > "$CONF"
  run "$SCRIPT" "$CONF"
  [ "$status" -eq 1 ]
  assert_contains "$output" "required key 'issuer' is missing"
}
