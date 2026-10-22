#!/usr/bin/env bash
# Starts a DropRedo run through POST /api/v1/triggers/{triggerId}/run, waits
# for its result through GET /api/v1/executions/{executionId}, writes it to
# the job summary and the pull request, and fails when the run fails.
#
# Reads its inputs from the DROPREDO_* variables action.yml sets.

set -uo pipefail

api_url="${DROPREDO_API_URL%/}"
browser="${DROPREDO_BROWSER:-chromium}"
timeout_minutes="${DROPREDO_TIMEOUT_MINUTES:-30}"
poll_interval="${DROPREDO_POLL_INTERVAL_SECONDS:-15}"
comment_marker="<!-- dropredo-action trigger=${DROPREDO_TRIGGER_ID:-} browser=${browser} -->"

fail() {
  echo "::error::$1"
  exit 1
}

output() {
  echo "$1=$2" >> "$GITHUB_OUTPUT"
}

is_true() {
  [ "$(echo "$1" | tr '[:upper:]' '[:lower:]')" = "true" ]
}

# Sends a request and prints the body, then the HTTP code on the last line.
request() {
  local method="$1" url="$2" token="$3" body="${4:-}"
  local args=(-sS -X "$method" -w '\n%{http_code}' -H "Authorization: Bearer $token" -H "Accept: application/json")

  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi

  curl "${args[@]}" "$url" || printf '\n000'
}

# The API's own error message, or the raw body when it sent none.
error_message() {
  echo "$1" | jq -r '.error.message // empty' 2>/dev/null || true
}

# Markdown for the job summary and the pull request comment.
result_markdown() {
  local heading="$1"

  echo "### DropRedo (${browser}): ${heading}"

  if [ -n "$status_response" ]; then
    echo ""
    echo "| Total | Passed | Failed | Not finished |"
    echo "| --- | --- | --- | --- |"
    echo "$status_response" | jq -r '.success.counts | "| \(.total) | \(.passed) | \(.failed) | \(.running) |"'
  fi

  echo ""
  echo "[View the run report](${report_url})"
}

# Posts the result on the pull request, or updates the comment an earlier run
# of this trigger and browser posted. A failure here only warns: the result
# is still in the job summary and the job's status.
comment_on_pr() {
  local markdown="$1"

  if ! is_true "${DROPREDO_COMMENT_ON_PR:-true}" || [ -z "${DROPREDO_PR_NUMBER:-}" ]; then
    return 0
  fi

  local github_api="${DROPREDO_GITHUB_API_URL%/}"
  local comments_url="${github_api}/repos/${GITHUB_REPOSITORY}/issues/${DROPREDO_PR_NUMBER}/comments"
  local body comment_id="" page response code

  body=$(jq -n --arg body "${comment_marker}"$'\n'"${markdown}" '{body: $body}')

  for page in 1 2 3 4 5 6 7 8 9 10; do
    response=$(request GET "${comments_url}?per_page=100&page=${page}" "$DROPREDO_GITHUB_TOKEN")
    code=$(echo "$response" | tail -n 1)
    response=$(echo "$response" | sed '$d')

    if [ "$code" != "200" ]; then
      echo "::warning::Could not read the pull request's comments (HTTP $code), so the report link is only in the job summary."
      return 0
    fi

    comment_id=$(echo "$response" | jq -r --arg marker "$comment_marker" 'map(select(.body | contains($marker))) | first | .id // empty')

    if [ -n "$comment_id" ] || [ "$(echo "$response" | jq 'length')" -lt 100 ]; then
      break
    fi
  done

  if [ -n "$comment_id" ]; then
    code=$(request PATCH "${github_api}/repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" "$DROPREDO_GITHUB_TOKEN" "$body" | tail -n 1)
  else
    code=$(request POST "$comments_url" "$DROPREDO_GITHUB_TOKEN" "$body" | tail -n 1)
  fi

  case "$code" in
    200|201) echo "Posted the result on pull request #${DROPREDO_PR_NUMBER}." ;;
    *) echo "::warning::Could not comment on the pull request (HTTP $code). Give the job the pull-requests: write permission, or set comment-on-pr to false." ;;
  esac
}

# Ends the action with the result in the summary, the outputs and the PR.
finish() {
  local heading="$1" exit_code="$2"
  local markdown

  output status "$status"
  markdown=$(result_markdown "$heading")
  echo "$markdown" >> "$GITHUB_STEP_SUMMARY"
  comment_on_pr "$markdown"
  exit "$exit_code"
}

command -v jq > /dev/null || fail "This action needs jq on the runner."

[ -n "${DROPREDO_API_TOKEN:-}" ] || fail "Set the api-token input, for example api-token: \${{ secrets.DROPREDO_API_TOKEN }}, and add that repository secret (Settings > Secrets and variables > Actions)."
[ -n "${DROPREDO_TRIGGER_ID:-}" ] || fail "Set the trigger-id input to a trigger ID from the API tab of a Triggers page in DropRedo."

case "$browser" in
  chromium|firefox|webkit) ;;
  *) fail "browser must be chromium, firefox or webkit, not \"$browser\"." ;;
esac

[[ "$timeout_minutes" =~ ^[0-9]+$ ]] || fail "timeout-minutes must be a whole number of minutes."
[[ "$poll_interval" =~ ^[1-9][0-9]*$ ]] || fail "poll-interval-seconds must be a whole number above 0."

# Commas, spaces or new lines between IDs; none runs every environment.
environments=$(echo "${DROPREDO_ENVIRONMENTS:-}" | tr ',' ' ' | tr -s '[:space:]' '\n' | jq -R 'select(length > 0)' | jq -s -c '.')

run_body=$(jq -n -c \
  --arg browser "$browser" \
  --argjson public_report "$(is_true "${DROPREDO_PUBLIC_REPORT:-true}" && echo true || echo false)" \
  --argjson environments "$environments" \
  '{browser: $browser, public_report: $public_report} + (if ($environments | length) > 0 then {environments: $environments} else {} end)')

echo "Starting the DropRedo run for trigger ${DROPREDO_TRIGGER_ID} in ${browser}."

response=$(request POST "${api_url}/api/v1/triggers/${DROPREDO_TRIGGER_ID}/run" "$DROPREDO_API_TOKEN" "$run_body")
code=$(echo "$response" | tail -n 1)
response=$(echo "$response" | sed '$d')

if [ "$code" != "201" ]; then
  message=$(error_message "$response")
  fail "DropRedo did not start the run (HTTP $code): ${message:-$response}"
fi

execution_id=$(echo "$response" | jq -r '.success.execution_id')
app_url=$(echo "$response" | jq -r '.success.app_url // empty')
report_url=$(echo "$response" | jq -r '.success.report_url // .success.app_url // empty')
status=$(echo "$response" | jq -r '.success.status')
status_response=""

output execution-id "$execution_id"
output app-url "$app_url"
output report-url "$report_url"

echo "Run started: ${report_url}"

if ! is_true "${DROPREDO_WAIT:-true}"; then
  finish "started" 0
fi

deadline=$(( $(date +%s) + timeout_minutes * 60 ))

while true; do
  response=$(request GET "${api_url}/api/v1/executions/${execution_id}" "$DROPREDO_API_TOKEN")
  code=$(echo "$response" | tail -n 1)
  response=$(echo "$response" | sed '$d')

  case "$code" in
    200)
      status_response="$response"
      status=$(echo "$response" | jq -r '.success.status')

      if [ "$(echo "$response" | jq -r '.success.finished')" = "true" ]; then
        break
      fi

      if [ "$status" = "waiting for manual action" ]; then
        echo "::error::The DropRedo run is paused for manual action, so it needs a person. Finish or stop it in DropRedo: ${app_url}"
        finish "waiting for manual action" 1
      fi

      echo "Status: ${status} ($(echo "$response" | jq -r '.success.counts | "\(.passed) passed, \(.failed) failed, \(.running) not finished"'))"
      ;;
    401|404)
      message=$(error_message "$response")
      fail "DropRedo did not return the run's status (HTTP $code): ${message:-$response}"
      ;;
    *)
      # Rate limited, a network error or a server error: try again.
      echo "::warning::Could not read the run's status (HTTP $code), retrying."
      ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::The DropRedo run did not finish within ${timeout_minutes} minutes. It is still running: ${app_url}"
    finish "timed out" 1
  fi

  sleep "$poll_interval"
done

counts=$(echo "$status_response" | jq -r '.success.counts | "\(.failed) of \(.total) tests failed, \(.passed) passed"')

if [ "$(echo "$status_response" | jq -r '.success.passed')" = "true" ]; then
  output passed true
  echo "DropRedo run passed: ${counts}. Report: ${report_url}"
  finish "passed" 0
fi

output passed false
echo "::error::DropRedo run ${status}: ${counts}. Report: ${report_url}"
finish "$status" 1
