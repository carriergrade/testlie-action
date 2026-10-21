#!/usr/bin/env bash
# Implementation of the Testlie GitHub Action (see action.yml). Needs bash, curl and jq, which
# every GitHub-hosted runner has. Inputs arrive as INPUT_* environment variables; outputs go to
# $GITHUB_OUTPUT. Also runs locally: GITHUB_OUTPUT defaults to /dev/stdout.
set -euo pipefail

BASE_URL="${INPUT_BASE_URL:-https://testlie.com}"
BASE_URL="${BASE_URL%/}"
API_KEY="${INPUT_API_KEY:-${TESTLIE_API_KEY:-}}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "::error title=Testlie::$*" >&2; exit 1; }
[ -n "$API_KEY" ] || fail "api-key is required (a Testlie API key, tl_...)"
command -v jq >/dev/null || fail "jq is required"
echo "::add-mask::$API_KEY"

# Writes name=value to the step outputs; the heredoc form keeps odd characters and newlines safe.
output() {
  local delim="TESTLIE_$RANDOM$RANDOM"
  { printf '%s<<%s\n' "$1" "$delim"; printf '%s\n' "$2"; printf '%s\n' "$delim"; } >> "$OUT"
}

# api METHOD PATH [JSON]: prints the status code; the body is in $TMP/body. GET and DELETE are
# retried on 429, 5xx and connection failures with backoff. The long-poll's 408 is not retried.
api() {
  local method="$1" path="$2" data="${3:-}" status attempt=0 max=0 extra=()
  if [ "$method" = GET ] || [ "$method" = DELETE ]; then max=3; fi
  if [ -n "$data" ]; then extra=(-H "Content-Type: application/json" --data "$data"); fi
  while :; do
    status="$(curl -sS -o "$TMP/body" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $API_KEY" -H "Accept: application/json" -H "User-Agent: testlie-action/0.1.0" \
      --max-time "${CURL_MAX_TIME:-60}" ${extra[@]+"${extra[@]}"} "$BASE_URL$path" 2>"$TMP/err" || echo 000)"
    case "$status" in
      000|429|5??)
        if [ "$attempt" -lt "$max" ]; then
          attempt=$((attempt + 1))
          sleep $((attempt * 2))
          continue
        fi ;;
    esac
    echo "$status"
    return 0
  done
}

# Fails the step with the API's error message.
api_error() {
  local status="$1" what="$2" msg
  if [ "$status" = 000 ]; then msg="$(cat "$TMP/err" 2>/dev/null)"; else msg="$(jq -r '.error // empty' "$TMP/body" 2>/dev/null || true)"; fi
  [ -n "$msg" ] || msg="$(head -c 300 "$TMP/body" 2>/dev/null || true)"
  fail "$what failed (HTTP $status): $msg"
}

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

case "${INPUT_MODE:-}" in
  create-inbox)
    name="${INPUT_NAME:-}"
    [ -n "$name" ] || name="${GITHUB_REPOSITORY:-ci}#${GITHUB_RUN_ID:-local}${GITHUB_JOB:+ $GITHUB_JOB}"
    minutes="${INPUT_DISPOSABLE_MINUTES:-60}"
    body="$(jq -cn --arg name "${name:0:80}" --arg m "$minutes" '{name: $name} + (if ($m|length) > 0 and $m != "0" then {expiresInMinutes: ($m|tonumber)} else {} end)')"
    since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    status="$(api POST /api/inboxes "$body")"
    [ "$status" = 201 ] || api_error "$status" "Creating the inbox"
    password="$(jq -r '.inbox.smtp.password' "$TMP/body")"
    echo "::add-mask::$password"
    id="$(jq -r '.inbox.id' "$TMP/body")"
    tag="$(printf '%s' "${INPUT_ADDRESS_TAG:-}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^[-.]+|[-.]+$//g')"
    address="$(jq -r --arg tag "$tag" '
      .inbox as $i | (if $tag == "" then "" else "+" + $tag end) as $s
      | if $i.inboundAddress then ($i.inboundAddress | split("@")) as $p | $p[0] + $s + "@" + $p[1]
        else $i.emailAlias + $s + "@example.com" end' "$TMP/body")"
    port="$(jq -r '[.inbox.smtp.ports[] | select(. != 465)][0] // .inbox.smtp.ports[0]' "$TMP/body")"
    output inbox-id "$id"
    output smtp-host "$(jq -r '.inbox.smtp.host' "$TMP/body")"
    output smtp-port "$port"
    output smtp-username "$(jq -r '.inbox.smtp.username' "$TMP/body")"
    output smtp-password "$password"
    output address "$address"
    output since "$since"
    output expires-at "$(jq -r '.inbox.expiresAt // ""' "$TMP/body")"
    echo "Created inbox $id ($address)${minutes:+, deleted after $minutes minutes}" >&2
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "Testlie inbox: [$id]($BASE_URL/inboxes/$id) ($address)" >> "$GITHUB_STEP_SUMMARY"; fi
    ;;

  wait)
    inbox="${INPUT_INBOX_ID:-}"
    [ -n "$inbox" ] || fail "inbox-id is required for mode: wait"
    timeout="${INPUT_TIMEOUT:-60}"
    case "$timeout" in ''|*[!0-9]*) fail "timeout must be a whole number of seconds" ;; esac
    query=""
    [ -z "${INPUT_TO:-}" ] || query="$query&to=$(urlencode "$(printf '%s' "$INPUT_TO" | tr '[:upper:]' '[:lower:]')")"
    [ -z "${INPUT_SUBJECT:-}" ] || query="$query&subject=$(urlencode "$INPUT_SUBJECT")"
    [ -z "${INPUT_SINCE:-}" ] || query="$query&since=$(urlencode "$INPUT_SINCE")"
    deadline=$(( $(date +%s) + timeout ))
    found=""
    while :; do
      left=$(( deadline - $(date +%s) ))
      [ "$left" -ge 1 ] || left=1
      [ "$left" -le 120 ] || left=120
      started=$(date +%s)
      status="$(CURL_MAX_TIME=$((left + 30)) api GET "/api/inboxes/$inbox/messages/wait?timeout=$left$query")"
      if [ "$status" = 200 ]; then found=1; break; fi
      [ "$status" = 408 ] || api_error "$status" "Waiting for email"
      [ $(( deadline - $(date +%s) )) -ge 1 ] || break
      [ $(( $(date +%s) - started )) -ge 1 ] || sleep 1
    done
    [ -n "$found" ] || fail "No email${INPUT_TO:+ to $INPUT_TO}${INPUT_SUBJECT:+ with subject containing \"$INPUT_SUBJECT\"} arrived within ${timeout}s"
    id="$(jq -r '.message.id' "$TMP/body")"
    output message-id "$id"
    output subject "$(jq -r '.message.subject' "$TMP/body")"
    output from "$(jq -r '.message.from.address // ""' "$TMP/body")"
    status="$(api GET "/api/messages/$id/extract")"
    [ "$status" = 200 ] || api_error "$status" "Extracting from the message"
    output otp "$(jq -r '.codes[0].value // ""' "$TMP/body")"
    output link "$(jq -r --arg p "${INPUT_LINK_PATTERN:-}" '
      if $p == "" then (.magicLinks[0].url // "")
      else ([.magicLinks[], .links[] | select((.url | test($p; "i")) or (.text | test($p; "i")))][0].url // "") end' "$TMP/body")"
    output extract "$(jq -c '{codes, magicLinks, links}' "$TMP/body")"
    echo "Received message $id: $(jq -r '.subject' "$TMP/body")" >&2
    ;;

  delete-inbox)
    inbox="${INPUT_INBOX_ID:-}"
    [ -n "$inbox" ] || fail "inbox-id is required for mode: delete-inbox"
    status="$(api DELETE "/api/inboxes/$inbox")"
    case "$status" in
      204|404) echo "Deleted inbox $inbox" >&2 ;;
      *) api_error "$status" "Deleting the inbox" ;;
    esac
    ;;

  *) fail "mode must be create-inbox, wait or delete-inbox (got \"${INPUT_MODE:-}\")" ;;
esac
