#!/usr/bin/env bash
#
# oidc-discovery-override.sh — build a local OIDC discovery document with endpoint overrides.
#
# Why this exists:
#   In split-horizon / WAF environments the issuer of an auth server (e.g. a Keycloak
#   realm) is published under its EXTERNAL host name, while the endpoints that actually
#   work from a developer machine live on an INTERNAL host. Standard OIDC tooling using
#   the discovery document (/.well-known/openid-configuration) will not work in such an
#   environment.
#
#   This script downloads the real discovery document, overrides selected endpoint
#   properties with values from a small config file and writes the result to a local
#   file. That file can then be fed to OIDC tooling, e.g. oidc-gen via
#   --config-endpoint=file://<path>.
#
# Behaviour:
#   1. Read the config file (KEY=value lines, see usage()).
#   2. Determine the discovery URL: oidc_provider_configuration_endpoint if set,
#      otherwise derived from the issuer (<issuer>/.well-known/openid-configuration).
#   3. Download the discovery document; fails fast on network problems instead of
#      hanging, and prints the active proxy-related environment variables on failure.
#   4. Force "issuer" to the configured issuer (OIDC clients enforce an issuer match)
#      and replace every *_endpoint / *_uri property listed in the config file. Properties the
#      auth server does not publish itself are NOT added; a warning is printed instead.
#   5. Write the result atomically to <config-name>.discovery.json (or -o PATH).
#
# Proxy handling:
#   The script does not manage proxies itself. curl natively honors the standard
#   environment variables http_proxy, https_proxy, all_proxy and no_proxy (and their
#   upper-case variants, except HTTP_PROXY, which curl deliberately ignores) as well
#   as ~/.curlrc and CURL_CA_BUNDLE. Internal hosts that must bypass a corporate
#   proxy belong in no_proxy (comma-separated host suffixes).
#
# Dependencies: bash >= 3.2, curl, jq
# Exit codes:   0 success, 1 runtime/config error, 2 usage error

SCRIPT_NAME="oidc-discovery-override"

# Fail fast so users get a clear message instead of a hanging command.
CURL_CONNECT_TIMEOUT="${OIDC_DISCOVERY_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${OIDC_DISCOVERY_MAX_TIME:-15}"

# --- logging ----------------------------------------------------------------

log_info()  { printf '%s\n' "[$SCRIPT_NAME] $*" >&2; }
log_warn()  { printf '%s\n' "[$SCRIPT_NAME] WARNING: $*" >&2; }
log_error() { printf '%s\n' "[$SCRIPT_NAME] ERROR: $*" >&2; }

die() {
  log_error "$*"
  exit 1
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME}.sh [-o OUTPUT] CONFIG_FILE

Downloads the OIDC discovery document referenced by CONFIG_FILE, applies the
endpoint overrides defined there and writes the result to OUTPUT
(default: <CONFIG_FILE-directory>/<CONFIG_FILE-name>.discovery.json).

Options:
  -o OUTPUT   write the result to OUTPUT instead of the default path;
              '-o -' prints it to stdout
  -h, --help  show this help

Config file format: one KEY=value per line, parsed line by line (the file is
never sourced). '#' starts a comment line (inline comments after a value are
not supported); values may be double- or single-quoted. Keys:
  issuer                                  required; external issuer URL
  oidc_provider_configuration_endpoint    optional; explicit discovery URL
  <name>_endpoint / <name>_uri            optional; overrides the discovery
                                          property of the same name, e.g.
                                          token_endpoint, jwks_uri
EOF
}

usage_error() {
  log_error "$*"
  usage >&2
  exit 2
}

check_dependencies() {
  local tool
  for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 \
      || die "required tool '$tool' not found on PATH"
  done
}

# --- small string helpers ---------------------------------------------------

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# Strip one pair of surrounding double or single quotes, if present.
unquote() {
  local s=$1
  if [[ ${#s} -ge 2 ]]; then
    case $s in
      \"*\") s=${s%\"}; s=${s#\"} ;;
      \'*\') s=${s%\'}; s=${s#\'} ;;
    esac
  fi
  printf '%s' "$s"
}

# --- argument parsing -------------------------------------------------------

parse_args() {
  ARG_CONF_FILE=""
  ARG_OUTPUT=""
  local opt OPTIND=1

  # Recognize --help only as the first argument; after '--' or as an option
  # argument it keeps its literal meaning (e.g. a file named '--help').
  if [[ ${1:-} == "--help" ]]; then
    usage
    exit 0
  fi

  while getopts ":o:h" opt; do
    case $opt in
      o) ARG_OUTPUT=$OPTARG ;;
      h) usage; exit 0 ;;
      :) usage_error "option -$OPTARG requires an argument" ;;
      *) usage_error "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))

  [[ $# -eq 1 ]] || usage_error "exactly one CONFIG_FILE argument is required"
  ARG_CONF_FILE=$1
}

# --- configuration ----------------------------------------------------------

# Reads $1 and sets: CONF_ISSUER, CONF_DISCOVERY_ENDPOINT,
# OVERRIDE_KEYS[] / OVERRIDE_VALUES[] (parallel arrays; bash 3.2 has no
# associative arrays).
parse_config() {
  local conf=$1
  local line key value lineno=0 seen="|"
  local skip_re='^[[:space:]]*(#|$)'
  local kv_re='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$'

  CONF_ISSUER=""
  CONF_DISCOVERY_ENDPOINT=""
  OVERRIDE_KEYS=()
  OVERRIDE_VALUES=()

  [[ -f $conf ]] || die "config file not found: $conf"
  [[ -r $conf ]] || die "config file not readable: $conf"

  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    if [[ $line =~ $skip_re ]]; then
      continue
    fi
    if [[ ! $line =~ $kv_re ]]; then
      die "$conf:$lineno: expected KEY=value, got: $line"
    fi
    key=${BASH_REMATCH[1]}
    value=$(unquote "$(trim "${BASH_REMATCH[2]}")")
    [[ -n $value ]] || die "$conf:$lineno: empty value for key '$key'"
    if [[ $seen == *"|$key|"* ]]; then
      die "$conf:$lineno: duplicate key '$key'"
    fi
    seen="$seen$key|"

    case $key in
      issuer)
        CONF_ISSUER=$value
        ;;
      oidc_provider_configuration_endpoint)
        CONF_DISCOVERY_ENDPOINT=$value
        ;;
      *_endpoint|*_uri)
        OVERRIDE_KEYS+=("$key")
        OVERRIDE_VALUES+=("$value")
        ;;
      *)
        log_warn "$conf:$lineno: ignoring unknown key '$key' (only 'issuer', 'oidc_provider_configuration_endpoint', '*_endpoint' and '*_uri' keys are used)"
        ;;
    esac
  done < "$conf"
}

# $1 = description for messages, $2 = URL to check
check_url() {
  local what=$1 url=$2
  case $url in
    *[[:space:]]*) die "$what contains whitespace: $url" ;;
    *'#'*) die "$what contains '#' (inline comments are not supported): $url" ;;
  esac
  case $url in
    https://?*) ;;
    http://?*) log_warn "$what uses insecure http: $url" ;;
    *) die "$what is not a valid http(s) URL: $url" ;;
  esac
}

derive_discovery_url() {
  if [[ -n $CONF_DISCOVERY_ENDPOINT ]]; then
    printf '%s' "$CONF_DISCOVERY_ENDPOINT"
  else
    printf '%s' "${CONF_ISSUER%/}/.well-known/openid-configuration"
  fi
}

default_output_path() {
  local conf=$1 dir base
  dir=$(dirname "$conf")
  base=$(basename "$conf")
  base=${base%.*}
  printf '%s' "$dir/$base.discovery.json"
}

# --- download ---------------------------------------------------------------

print_proxy_diagnostics() {
  local vars=(http_proxy https_proxy all_proxy no_proxy HTTPS_PROXY ALL_PROXY NO_PROXY)
  local v val any=0
  for v in "${vars[@]}"; do
    val=${!v:-}
    if [[ -n $val ]]; then
      if [[ $any -eq 0 ]]; then
        log_info "proxy-related environment variables in effect:"
        any=1
      fi
      log_info "  $v=$val"
    fi
  done
  if [[ $any -eq 0 ]]; then
    log_info "no proxy-related environment variables are set"
  else
    log_info "note: curl ignores upper-case HTTP_PROXY; hosts that must bypass the proxy belong in no_proxy (comma-separated)"
  fi
}

# $1 = discovery URL, $2 = target file
download_discovery() {
  local url=$1 out=$2 curl_stderr
  log_info "downloading discovery document from $url"
  if ! curl_stderr=$(curl --fail --silent --show-error --location --proto-redir =https \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      "$url" 2>&1 >"$out"); then
    log_error "curl: ${curl_stderr:-unknown error}"
    print_proxy_diagnostics
    die "could not download the discovery document from $url"
  fi
}

# $1 = downloaded file, $2 = discovery URL (for messages)
validate_discovery() {
  local file=$1 url=$2 remote_issuer
  jq empty "$file" >/dev/null 2>&1 \
    || die "response from $url is not valid JSON"
  jq -e 'type == "object" and has("issuer")' "$file" >/dev/null 2>&1 \
    || die "response from $url is not an OIDC discovery document (no 'issuer' property)"
  remote_issuer=$(jq -r '.issuer' "$file")
  if [[ $remote_issuer != "$CONF_ISSUER" ]]; then
    log_warn "issuer in the downloaded document ('$remote_issuer') differs from the configured issuer ('$CONF_ISSUER'); the configured issuer is used"
  fi
}

# --- override application ---------------------------------------------------

# $1 = downloaded discovery file, $2 = result file
apply_overrides() {
  local in=$1 out=$2
  local overrides_json='{}' i key skipped=0 applied

  for ((i = 0; i < ${#OVERRIDE_KEYS[@]}; i++)); do
    overrides_json=$(jq --arg k "${OVERRIDE_KEYS[$i]}" --arg v "${OVERRIDE_VALUES[$i]}" \
        '. + {($k): $v}' <<<"$overrides_json") \
      || die "internal error: could not assemble the override list"
  done

  # Only replace properties the auth server itself publishes; everything else
  # is most likely a typo in the config file.
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    log_warn "the auth server does not publish '$key' in its discovery document — override skipped (typo?)"
    skipped=$((skipped + 1))
  done < <(jq -r --argjson ov "$overrides_json" \
      '. as $doc | $ov | keys[] | select(. as $k | ($doc | has($k)) | not)' "$in")

  jq --arg issuer "$CONF_ISSUER" --argjson ov "$overrides_json" '
      .issuer = $issuer
      | reduce ($ov | to_entries[]) as $e
          (.; if has($e.key) then .[$e.key] = $e.value else . end)
    ' "$in" >"$out" \
    || die "internal error: could not apply the overrides"

  applied=$((${#OVERRIDE_KEYS[@]} - skipped))
  log_info "applied $applied override(s), skipped $skipped"
}

# --- main -------------------------------------------------------------------

# Temp files removed by the EXIT trap; globals because the trap fires after
# main's locals are gone.
TMP_DOWNLOAD=""
TMP_RESULT=""

cleanup() {
  if [[ -n $TMP_DOWNLOAD ]]; then
    rm -f "$TMP_DOWNLOAD"
  fi
  if [[ -n $TMP_RESULT ]]; then
    rm -f "$TMP_RESULT"
  fi
}

main() {
  parse_args "$@"
  check_dependencies
  parse_config "$ARG_CONF_FILE"

  [[ -n $CONF_ISSUER ]] || die "required key 'issuer' is missing in $ARG_CONF_FILE"
  check_url "issuer" "$CONF_ISSUER"
  if [[ -n $CONF_DISCOVERY_ENDPOINT ]]; then
    check_url "oidc_provider_configuration_endpoint" "$CONF_DISCOVERY_ENDPOINT"
  fi
  local i
  for ((i = 0; i < ${#OVERRIDE_KEYS[@]}; i++)); do
    check_url "${OVERRIDE_KEYS[$i]}" "${OVERRIDE_VALUES[$i]}"
  done

  local output=$ARG_OUTPUT
  [[ -n $output ]] || output=$(default_output_path "$ARG_CONF_FILE")

  local url
  url=$(derive_discovery_url)

  # Download and transform via temp files; the final result is moved into
  # place only after everything succeeded, so a failing run never destroys a
  # previously generated file. The result temp file lives next to the output
  # to keep the final mv an atomic rename.
  trap cleanup EXIT
  TMP_DOWNLOAD=$(mktemp "${TMPDIR:-/tmp}/$SCRIPT_NAME.XXXXXX") \
    || die "could not create a temporary file"
  if [[ $output == - ]]; then
    TMP_RESULT=$(mktemp "${TMPDIR:-/tmp}/$SCRIPT_NAME.XXXXXX") \
      || die "could not create a temporary file"
  else
    TMP_RESULT=$(mktemp "$(dirname "$output")/.$SCRIPT_NAME.XXXXXX") \
      || die "could not create a temporary file next to $output"
  fi

  download_discovery "$url" "$TMP_DOWNLOAD"
  validate_discovery "$TMP_DOWNLOAD" "$url"
  apply_overrides "$TMP_DOWNLOAD" "$TMP_RESULT"

  if [[ $output == - ]]; then
    cat "$TMP_RESULT"
  else
    mv "$TMP_RESULT" "$output" || die "could not write $output"
    log_info "wrote $output"
  fi
}

# Run main only when executed, not when sourced (the test suite sources this
# file to unit-test individual functions).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
