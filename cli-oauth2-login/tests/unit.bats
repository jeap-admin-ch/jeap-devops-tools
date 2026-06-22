#!/usr/bin/env bats
# Unit tests: source the script (its main guard keeps it from running) and
# exercise the individual functions directly.

load helpers

setup() {
  common_setup
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

teardown() {
  common_teardown
}

# --- string helpers ----------------------------------------------------------

@test "trim removes surrounding whitespace" {
  assert_equal "$(trim '  hello world  ')" "hello world"
  assert_equal "$(trim 'nochange')" "nochange"
  assert_equal "$(trim '   ')" ""
}

@test "unquote strips one pair of surrounding quotes" {
  assert_equal "$(unquote '"https://x"')" "https://x"
  assert_equal "$(unquote "'https://x'")" "https://x"
  assert_equal "$(unquote 'https://x')" "https://x"
  assert_equal "$(unquote '"unbalanced')" '"unbalanced'
}

# --- parse_config ------------------------------------------------------------

@test "parse_config reads issuer, discovery endpoint and endpoint overrides" {
  local conf="$TEST_TMPDIR/t.conf"
  cat > "$conf" <<'EOF'
# a comment

issuer="https://auth.example.com/realms/demo"
oidc_provider_configuration_endpoint = "https://internal.example.com/realms/demo/.well-known/openid-configuration"
token_endpoint='https://internal.example.com/token'
revocation_endpoint=https://internal.example.com/revoke
jwks_uri="https://internal.example.com/certs"
EOF
  parse_config "$conf"
  assert_equal "$CONF_ISSUER" "https://auth.example.com/realms/demo"
  assert_equal "$CONF_DISCOVERY_ENDPOINT" "https://internal.example.com/realms/demo/.well-known/openid-configuration"
  [ "${#OVERRIDE_KEYS[@]}" -eq 3 ]
  assert_equal "${OVERRIDE_KEYS[0]}" "token_endpoint"
  assert_equal "${OVERRIDE_VALUES[0]}" "https://internal.example.com/token"
  assert_equal "${OVERRIDE_KEYS[1]}" "revocation_endpoint"
  assert_equal "${OVERRIDE_VALUES[1]}" "https://internal.example.com/revoke"
  assert_equal "${OVERRIDE_KEYS[2]}" "jwks_uri"
  assert_equal "${OVERRIDE_VALUES[2]}" "https://internal.example.com/certs"
}

@test "parse_config tolerates CRLF line endings" {
  printf 'issuer="https://auth.example.com/realms/demo"\r\n' > "$TEST_TMPDIR/t.conf"
  parse_config "$TEST_TMPDIR/t.conf"
  assert_equal "$CONF_ISSUER" "https://auth.example.com/realms/demo"
}

@test "parse_config rejects malformed lines" {
  printf 'issuer https://no-equals-sign\n' > "$TEST_TMPDIR/t.conf"
  run parse_config "$TEST_TMPDIR/t.conf"
  [ "$status" -eq 1 ]
  assert_contains "$output" "expected KEY=value"
}

@test "parse_config rejects duplicate keys" {
  printf 'issuer=https://a.example.com\nissuer=https://b.example.com\n' > "$TEST_TMPDIR/t.conf"
  run parse_config "$TEST_TMPDIR/t.conf"
  [ "$status" -eq 1 ]
  assert_contains "$output" "duplicate key 'issuer'"
}

@test "parse_config rejects empty values" {
  printf 'token_endpoint=\n' > "$TEST_TMPDIR/t.conf"
  run parse_config "$TEST_TMPDIR/t.conf"
  [ "$status" -eq 1 ]
  assert_contains "$output" "empty value for key 'token_endpoint'"
}

@test "parse_config warns about unknown keys but continues" {
  printf 'issuer=https://a.example.com\nclient_id=foo\n' > "$TEST_TMPDIR/t.conf"
  run parse_config "$TEST_TMPDIR/t.conf"
  [ "$status" -eq 0 ]
  assert_contains "$output" "ignoring unknown key 'client_id'"
}

@test "parse_config fails on a missing file" {
  run parse_config "$TEST_TMPDIR/does-not-exist.conf"
  [ "$status" -eq 1 ]
  assert_contains "$output" "config file not found"
}

# --- URL handling ------------------------------------------------------------

@test "derive_discovery_url prefers the explicit endpoint" {
  CONF_ISSUER="https://auth.example.com/realms/demo"
  CONF_DISCOVERY_ENDPOINT="https://internal.example.com/disco"
  assert_equal "$(derive_discovery_url)" "https://internal.example.com/disco"
}

@test "derive_discovery_url derives from the issuer, trailing-slash safe" {
  CONF_DISCOVERY_ENDPOINT=""
  CONF_ISSUER="https://auth.example.com/realms/demo"
  assert_equal "$(derive_discovery_url)" "https://auth.example.com/realms/demo/.well-known/openid-configuration"
  CONF_ISSUER="https://auth.example.com/realms/demo/"
  assert_equal "$(derive_discovery_url)" "https://auth.example.com/realms/demo/.well-known/openid-configuration"
}

@test "check_url accepts https, warns on http, rejects anything else" {
  run check_url issuer "https://ok.example.com"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run check_url issuer "http://insecure.example.com"
  [ "$status" -eq 0 ]
  assert_contains "$output" "insecure http"
  run check_url issuer "ftp://nope.example.com"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not a valid http(s) URL"
}

@test "check_url rejects values with whitespace or attempted inline comments" {
  run check_url issuer "https://example.com/x # comment"
  [ "$status" -eq 1 ]
  assert_contains "$output" "contains whitespace"
  run check_url issuer "https://example.com/x#comment"
  [ "$status" -eq 1 ]
  assert_contains "$output" "inline comments are not supported"
}

@test "default_output_path derives from the config file name" {
  assert_equal "$(default_output_path '/some/dir/example.conf')" "/some/dir/example.discovery.json"
  assert_equal "$(default_output_path 'plain')" "./plain.discovery.json"
}

# --- apply_overrides ---------------------------------------------------------

@test "apply_overrides replaces published endpoints and forces the issuer" {
  CONF_ISSUER="https://auth.example.com/realms/demo"
  OVERRIDE_KEYS=(token_endpoint)
  OVERRIDE_VALUES=("https://internal.example.com/token")
  local out="$TEST_TMPDIR/out.json"
  apply_overrides "$FIXTURES/keycloak-discovery.json" "$out"
  assert_equal "$(jq -r '.token_endpoint' "$out")" "https://internal.example.com/token"
  assert_equal "$(jq -r '.issuer' "$out")" "https://auth.example.com/realms/demo"
  assert_equal "$(jq -r '.jwks_uri' "$out")" "$(jq -r '.jwks_uri' "$FIXTURES/keycloak-discovery.json")"
}

@test "apply_overrides skips properties the auth server does not publish" {
  CONF_ISSUER="https://auth.example.com/realms/demo"
  OVERRIDE_KEYS=(tokn_endpoint)
  OVERRIDE_VALUES=("https://internal.example.com/typo")
  local out="$TEST_TMPDIR/out.json"
  run apply_overrides "$FIXTURES/keycloak-discovery.json" "$out"
  [ "$status" -eq 0 ]
  assert_contains "$output" "override skipped (typo?)"
  assert_contains "$output" "applied 0 override(s), skipped 1"
  run jq -e 'has("tokn_endpoint") | not' "$out"
  [ "$status" -eq 0 ]
}
