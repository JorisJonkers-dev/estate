# shellcheck shell=bash
# The provider registry and the key test behind ops/litellm-catalog-keys.sh. Sourced, never run.
#
# The registry (ops/litellm-providers.json, or LITELLM_PROVIDERS) names, per provider, its Vault
# fields, where to make the account and the key, the steps, and how to test the key the way the
# catalogue sync (JorisJonkers-dev/litellm catalog/sync.py) lists that provider's models.
#
# A key value lives only in shell variables and in 077 files under $LK_WORK that are removed right
# after use: curl reads its headers with `-H @file` and its body with `--data-binary @file`, so no
# key is ever in a process's arguments. Only fingerprints are printed.
#
# The caller sets LK_WORK (a 077 directory) and fills the associative array LK_VAL with the values
# to test, keyed by Vault field name.

LK_REGISTRY=${LITELLM_PROVIDERS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/litellm-providers.json}
declare -gA LK_VAL=()
LK_CLASS=""   # ok unproven rate-limited unauthorized no-credit wrong-base server-error network needs-extra-field missing
LK_DETAIL=""
LK_TIMEOUT=${LK_TIMEOUT:-20}

# lk_ids prints every provider id, in registry order.
lk_ids() { jq -r '.providers[].id' "$LK_REGISTRY"; }

# lk_provider ID prints the provider's registry entry as JSON, or fails.
lk_provider() {
  jq -ce --arg id "$1" '.providers[] | select(.id == $id)' "$LK_REGISTRY"
}

# lk_get ID JQ prints one value of a provider's entry (raw), empty when null.
lk_get() { jq -r --arg id "$1" ".providers[] | select(.id == \$id) | ($2) // empty" "$LK_REGISTRY"; }

# lk_fields ID prints the provider's Vault fields, the key first.
lk_fields() { lk_get "$1" '.fields[].name'; }

# lk_key_field ID prints the field that holds the provider's key.
lk_key_field() { lk_get "$1" '.fields[0].name'; }

# lk_field_owner FIELD prints the id of the provider that owns a Vault field.
lk_field_owner() {
  jq -r --arg f "$1" '[.providers[] | select(any(.fields[]; .name == $f)) | .id][0] // empty' "$LK_REGISTRY"
}

# lk_field_attr ID FIELD ATTR prints one attribute of a field (secret, required, prompt, hint, pattern).
lk_field_attr() {
  jq -r --arg id "$1" --arg f "$2" --arg a "$3" \
    '.providers[] | select(.id == $id) | .fields[] | select(.name == $f) | .[$a] | if . == null then empty else tostring end' "$LK_REGISTRY"
}

# lk_registry_check stops with the reason unless the registry is well formed.
lk_registry_check() {
  [[ -r "$LK_REGISTRY" ]] || { printf 'cannot read the provider registry %s\n' "$LK_REGISTRY" >&2; return 1; }
  jq -e '
    (.providers | type == "array" and length > 0)
    and all(.providers[]; (.id | type == "string") and (.name | type == "string")
      and (.fields | type == "array" and length > 0) and all(.fields[]; .name | type == "string")
      and (.test.kind | IN("bearer", "cloudflare", "watsonx", "github"))
      and (.steps | type == "array"))
    and ([.providers[].id] | length == (unique | length))
    and ([.providers[].fields[].name] | length == (unique | length))' "$LK_REGISTRY" >/dev/null \
    || { printf 'the provider registry %s is malformed (ids, fields, test.kind, steps)\n' "$LK_REGISTRY" >&2; return 1; }
}

# _lk_secret_file CONTENT writes CONTENT to a new 077 file under $LK_WORK and prints its path.
# printf is a builtin, so the content is in no process's arguments.
_lk_secret_file() {
  local f
  f=$(umask 077 && mktemp "$LK_WORK/h.XXXXXX")
  printf '%s' "$1" >"$f"
  printf '%s' "$f"
}

# _lk_http METHOD URL HEADERFILE [DATAFILE] runs one request, leaves the body in $LK_WORK/body and
# prints the HTTP status, or 000 when no answer came (DNS, TLS, refused, timeout).
_lk_http() {
  local method=$1 url=$2 hdr=$3 data=${4:-} code
  local args=(-sS -o "$LK_WORK/body" -w '%{http_code}' --max-time "$LK_TIMEOUT" -X "$method")
  [[ -n "$hdr" ]] && args+=(-H "@$hdr")
  [[ -n "$data" ]] && args+=(--data-binary "@$data")
  : >"$LK_WORK/body"
  code=$(curl "${args[@]}" "$url" 2>"$LK_WORK/curl.err") || true
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "$code"
}

# lk_classify CODE BODYFILE COUNTEXPR prints "<class>\t<detail>": the pure part of a test.
#   ok              200 and the body counts models with COUNTEXPR (detail: the count)
#   wrong-base      200 with a body that is no model list, or 404/405: the URL is not the API
#   unauthorized    401/403 (detail: the provider's message, cut short)
#   no-credit       402, or a body that says the credit or quota is spent
#   rate-limited    429: the key was accepted, the allowance is used up for now
#   server-error    5xx
#   network         no HTTP answer at all
lk_classify() {
  local code=$1 body=$2 count_expr=${3:-.data | length} count msg
  msg=$(jq -r '[.error.message?, .error?, .message?, .detail?, .errors[0].message?, .errorMessage?]
                | map(select(type == "string")) | first // empty' "$body" 2>/dev/null \
        || head -c 200 "$body" | tr -d '\r' | tr '\n' ' ')
  msg=${msg:0:140}
  case "$code" in
    000) printf 'network\tno answer' ;;
    200)
      if count=$(jq -er "$count_expr | numbers" "$body" 2>/dev/null); then
        printf 'ok\t%s' "$count"
      else
        printf 'wrong-base\t200 but no model list in the answer'
      fi ;;
    401 | 403)
      if grep -qiE 'credit|balance|quota exceeded|insufficient|billing' <<<"$msg"; then
        printf 'no-credit\t%s %s' "$code" "$msg"
      else
        printf 'unauthorized\t%s %s' "$code" "$msg"
      fi ;;
    402) printf 'no-credit\t402 %s' "$msg" ;;
    404 | 405) printf 'wrong-base\t%s %s' "$code" "$msg" ;;
    429) printf 'rate-limited\t429 %s' "$msg" ;;
    5??) printf 'server-error\t%s %s' "$code" "$msg" ;;
    *) printf 'unauthorized\t%s %s' "$code" "$msg" ;;
  esac
}

# lk_passes CLASS succeeds for a test result that justifies writing the key: the provider took it.
lk_passes() { [[ "$1" == ok || "$1" == unproven || "$1" == rate-limited ]]; }

_lk_set() { LK_CLASS=${1%%$'\t'*}; LK_DETAIL=${1#*$'\t'}; }

# lk_test ID tests the provider's key in LK_VAL and sets LK_CLASS and LK_DETAIL.
lk_test() {
  local id=$1 kind key keyf f
  LK_CLASS=""; LK_DETAIL=""
  kind=$(lk_get "$id" '.test.kind')
  keyf=$(lk_key_field "$id")
  key=${LK_VAL[$keyf]:-}
  if [[ -z "$key" ]]; then LK_CLASS=missing; LK_DETAIL="no $keyf"; return 0; fi
  case "$kind" in
    bearer) _lk_test_bearer "$id" "$key" ;;
    cloudflare) _lk_test_cloudflare "$id" "$key" ;;
    watsonx) _lk_test_watsonx "$id" "$key" ;;
    github) _lk_test_github "$id" "$key" ;;
  esac
  # A key the provider accepts still serves nothing while a field the sync needs is empty.
  if lk_passes "$LK_CLASS"; then
    for f in $(lk_get "$id" '.fields[1:][] | select(.required == true) | .name'); do
      if [[ -z "${LK_VAL[$f]:-}" ]]; then
        LK_DETAIL="key accepted ($LK_DETAIL), but $f is empty: the sync skips the route"
        LK_CLASS=needs-extra-field
        return 0
      fi
    done
  fi
  return 0
}

# _lk_headers ID KEY prints the header file for an authenticated request (path), or with KEY empty,
# the provider's non-secret headers only.
_lk_headers() {
  local id=$1 key=$2 auth extra
  auth=$(lk_get "$id" '.test.auth // "bearer"')
  extra=$(lk_get "$id" '(.test.headers // {}) | to_entries[] | "\(.key): \(.value)"')
  local text="${extra:+$extra$'\n'}"
  if [[ -n "$key" ]]; then
    case "$auth" in
      x-api-key) text+="x-api-key: $key"$'\n' ;;
      *) text+="Authorization: Bearer $key"$'\n' ;;
    esac
  fi
  _lk_secret_file "$text"
}

# _lk_base ID prints the provider's base: the test's literal base, or the Vault field it names.
_lk_base() {
  local id=$1 field
  field=$(lk_get "$id" '.test.base_field')
  if [[ -n "$field" ]]; then
    printf '%s' "${LK_VAL[$field]:-}" | sed 's:/*$::'
  else
    lk_get "$id" '.test.base' | sed 's:/*$::'
  fi
}

_lk_test_bearer() {
  local id=$1 key=$2 base path count_expr hdr code result auth_path probe data
  base=$(_lk_base "$id")
  if [[ -z "$base" ]]; then
    _lk_set "needs-extra-field	$(lk_get "$id" '.test.base_field') is empty: no base URL to test against"
    return 0
  fi
  path=$(lk_get "$id" '.test.path // "/models"')
  count_expr=$(lk_get "$id" '.test.count // ".data | length"')
  hdr=$(_lk_headers "$id" "$key")
  code=$(_lk_http GET "$base$path" "$hdr")
  result=$(lk_classify "$code" "$LK_WORK/body" "$count_expr")
  _lk_set "$result"
  if [[ "$LK_CLASS" == ok ]]; then
    LK_DETAIL="$LK_DETAIL models"
    # A list that answers without a key proves nothing about the key: ask an endpoint that needs it.
    auth_path=$(lk_get "$id" '.test.auth_path')
    probe=$(lk_get "$id" '.test.probe_model')
    if [[ -n "$auth_path" ]]; then
      code=$(_lk_http GET "$base$auth_path" "$hdr")
      [[ "$code" == 200 ]] || { _lk_set "$(lk_classify "$code" "$LK_WORK/body" '.')"; LK_DETAIL="$base$auth_path: $LK_DETAIL"; }
    elif [[ -n "$probe" ]]; then
      data=$(_lk_secret_file "$(jq -cn --arg m "$probe" '{model: $m, messages: [{role: "user", content: "ping"}], max_tokens: 1}')")
      printf 'Content-Type: application/json\n' >>"$hdr"
      code=$(_lk_http POST "$base/chat/completions" "$hdr" "$data")
      rm -f "$data"
      if [[ "$code" != 200 ]]; then
        _lk_set "$(lk_classify "$code" "$LK_WORK/body" '.')"
        LK_DETAIL="list answers without a key; a 1-token probe of $probe: $LK_DETAIL"
      else
        LK_DETAIL="$LK_DETAIL; a 1-token probe of $probe answered"
      fi
    else
      local anon
      anon=$(_lk_headers "$id" "")
      code=$(_lk_http GET "$base$path" "$anon")
      rm -f "$anon"
      if [[ "$code" == 200 ]] && jq -e "$count_expr | numbers" "$LK_WORK/body" >/dev/null 2>&1; then
        _lk_set "unproven	$LK_DETAIL, but the list answers without a key too: the key is not proven"
      fi
    fi
  fi
  rm -f "$hdr"
}

# Cloudflare: the base holds the account id. With cloudflare_account_id empty, the sync takes the
# token's one account from GET /accounts, so the test does the same.
_lk_test_cloudflare() {
  local id=$1 key=$2 api account hdr code result accounts
  api=$(lk_get "$id" '.test.base' | sed 's:/*$::')
  account=${LK_VAL[cloudflare_account_id]:-}
  hdr=$(_lk_headers "$id" "$key")
  if [[ -z "$account" ]]; then
    code=$(_lk_http GET "$api/accounts" "$hdr")
    result=$(lk_classify "$code" "$LK_WORK/body" '.result | length')
    _lk_set "$result"
    if [[ "$LK_CLASS" == ok ]]; then
      accounts=$LK_DETAIL
      if [[ "$accounts" == 1 ]]; then
        account=$(jq -r '.result[0].id' "$LK_WORK/body")
      else
        _lk_set "needs-extra-field	cloudflare_account_id is empty and the token sees $accounts accounts, so the sync cannot pick one"
        rm -f "$hdr"; return 0
      fi
    else
      LK_DETAIL="GET /accounts: $LK_DETAIL"; rm -f "$hdr"; return 0
    fi
  fi
  code=$(_lk_http GET "$api/accounts/$account/ai/models/search?per_page=100" "$hdr")
  result=$(lk_classify "$code" "$LK_WORK/body" '.result_info.total_count // (.result | length)')
  _lk_set "$result"
  [[ "$LK_CLASS" != ok ]] || LK_DETAIL="$LK_DETAIL models"
  rm -f "$hdr"
}

# watsonx: the IBM Cloud API key is exchanged at IAM for a bearer token, which lists the region's
# foundation models. The base is the Vault field watsonx_api_base.
_lk_test_watsonx() {
  local id=$1 key=$2 iam base data hdr code token result
  iam=$(lk_get "$id" '.test.iam')
  data=$(_lk_secret_file "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=$(jq -rn --arg k "$key" '$k | @uri')")
  hdr=$(_lk_secret_file $'Content-Type: application/x-www-form-urlencoded\nAccept: application/json\n')
  code=$(_lk_http POST "$iam" "$hdr" "$data")
  rm -f "$data" "$hdr"
  if [[ "$code" != 200 ]]; then
    # IAM answers 400 BXNIM0415E for a key it does not know.
    [[ "$code" == 400 ]] && code=401
    _lk_set "$(lk_classify "$code" "$LK_WORK/body" '.')"; LK_DETAIL="IAM token exchange: $LK_DETAIL"
    return 0
  fi
  token=$(jq -r '.access_token // empty' "$LK_WORK/body")
  : >"$LK_WORK/body"
  base=$(_lk_base "$id")
  if [[ -z "$base" ]]; then
    _lk_set "needs-extra-field	key accepted by IAM, but watsonx_api_base is empty: no region to list"
    return 0
  fi
  hdr=$(_lk_secret_file "Authorization: Bearer $token"$'\n')
  unset token
  code=$(_lk_http GET "$base$(lk_get "$id" '.test.path')" "$hdr")
  rm -f "$hdr"
  result=$(lk_classify "$code" "$LK_WORK/body" "$(lk_get "$id" '.test.count')")
  _lk_set "$result"
  [[ "$LK_CLASS" != ok ]] || LK_DETAIL="$LK_DETAIL models"
}

# GitHub: the token must see the repository it writes to.
_lk_test_github() {
  local id=$1 key=$2 repo hdr code
  repo=$(lk_get "$id" '.test.repo')
  hdr=$(_lk_secret_file "Authorization: Bearer $key"$'\nAccept: application/vnd.github+json\n')
  code=$(_lk_http GET "$(lk_get "$id" '.test.base // "https://api.github.com"')/repos/$repo" "$hdr")
  rm -f "$hdr"
  # A token that cannot see a private repository gets 404, not 403.
  [[ "$code" == 404 ]] && code=403
  _lk_set "$(lk_classify "$code" "$LK_WORK/body" '1')"
  [[ "$LK_CLASS" != ok ]] || LK_DETAIL="sees $repo"
}

# lk_show_steps ID prints where and how to make the account and the key.
lk_show_steps() {
  local id=$1 i=0 line verified
  printf '\n  %s%s%s\n' "${BOLD:-}" "$(lk_get "$id" '.name')" "${RESET:-}"
  line=$(lk_get "$id" '.requirements'); [[ -z "$line" ]] || printf '  %s\n' "$line"
  line=$(lk_get "$id" '.signup_url'); [[ -z "$line" ]] || printf '  account: %s\n' "$line"
  line=$(lk_get "$id" '.key_url'); [[ -z "$line" ]] || printf '  key:     %s\n' "$line"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    i=$((i + 1)); printf '  %2d. %s\n' "$i" "$line"
  done < <(lk_get "$id" '.steps[]')
  verified=$(lk_get "$id" '.verified | tostring')
  line=$(lk_get "$id" '.verified_note')
  case "$verified" in
    true) printf '  %s(steps checked on the provider site, %s)%s\n' "${DIM:-}" "$(lk_get "$id" '.checked // "date unknown"')" "${RESET:-}" ;;
    partial) printf '  %s(partly checked on the provider site: %s)%s\n' "${DIM:-}" "$line" "${RESET:-}" ;;
    *) printf '  %s(not checked on the provider site: %s)%s\n' "${DIM:-}" "${line:-the site could not be read}" "${RESET:-}" ;;
  esac
}

# lk_show_fix ID CLASS prints what to do about a test result: the provider's own hints for the
# class first, then the general ones.
lk_show_fix() {
  local id=$1 class=$2 line
  while IFS= read -r line; do
    [[ -n "$line" ]] && printf '    - %s\n' "$line"
  done < <(lk_get "$id" ".fix[\"$class\"][]?"; jq -r --arg c "$class" '.class_help[$c][]? // empty' "$LK_REGISTRY")
}
