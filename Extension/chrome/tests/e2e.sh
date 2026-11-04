#!/bin/bash
# End-to-end check of the browser bridge with a real browser, isolated from the user's own browsers and OpenClicky.
#
#   Extension/chrome/tests/e2e.sh [output-dir]
#
# Builds occtl and the native host, starts `occtl browser mcp-serve` with a throwaway bridge folder
# (OPENCLICKY_BRIDGE_DIR), installs the host manifest into a throwaway Chrome profile (Chrome reads
# <user-data-dir>/NativeMessagingHosts), launches Playwright's Chrome for Testing headless with the unpacked
# extension, serves tests/page.html on 127.0.0.1, then drives the page through the MCP `browser` tool. The toolbar
# popup's Stop / Resume button is pressed through the DevTools protocol (tests/popup.mjs).
# Needs node and Playwright's Chromium (npx playwright install chromium). CHROME=/path/to/binary overrides it;
# HOST=/path/to/OpenClickyBrowserHost tests another host build (e.g. the one inside dist/OpenClicky.app).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TESTS="$ROOT/Extension/chrome/tests"
WORK=$(mktemp -d /tmp/ocb-e2e.XXXXXX)
OUT=${1:-$WORK/out}
PORT=${PORT:-8765}
mkdir -p "$OUT" "$WORK/bridge" "$WORK/site"
OUT=$(cd "$OUT" && pwd)
cp "$TESTS"/page*.html "$WORK/site/"

if [[ -z "${CHROME:-}" ]]; then
  APP=$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium-*/chrome-mac*/"Google Chrome for Testing.app" 2>/dev/null | sort -V | tail -1)
  [[ -n "$APP" ]] || { echo "No Playwright Chromium found; run: npx playwright install chromium" >&2; exit 1; }
  CHROME="$APP/Contents/MacOS/Google Chrome for Testing"
fi

swift build --jobs 2 --package-path "$ROOT" --product occtl >/dev/null
swift build --jobs 2 --package-path "$ROOT" --product OpenClickyBrowserHost >/dev/null
BIN=$(swift build --jobs 2 --package-path "$ROOT" --show-bin-path)
OCCTL="$BIN/occtl"

export OPENCLICKY_BRIDGE_DIR="$WORK/bridge"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$WORK/support" "$WORK/site" "$WORK/bridge"
}
trap cleanup EXIT

node "$TESTS/serve.js" "$WORK/site" "$PORT" >"$OUT/http.log" 2>&1 &
PIDS+=($!)
mkdir -p "$WORK/job"
# A test job ("Compare plan prices") with a turn the script ends and restarts by signal.
python3 "$TESTS/approve-fixture-browser.py" "$OCCTL" browser mcp-serve --confirm-writes --save-dir "$WORK/job" --turn "e2e-job:Compare plan prices" >"$OUT/mcp-serve.log" 2>&1 &
SERVE=$!
PIDS+=($SERVE)

PROFILE="$WORK/support/Google/Chrome for Testing"
"$OCCTL" browser install-host --support "$WORK/support" --all ${HOST:+--host "$HOST"} >"$OUT/install-host.log"
"$CHROME" --headless=new --user-data-dir="$PROFILE" --load-extension="$ROOT/Extension/chrome" \
  --remote-debugging-port=0 --no-first-run --no-default-browser-check --window-size=1200,800 \
  "http://127.0.0.1:$PORT/page.html" >"$OUT/chrome.log" 2>&1 &
PIDS+=($!)

for _ in $(seq 1 60); do
  grep -q "connected browsers: Chrome" "$OUT/mcp-serve.log" 2>/dev/null && break
  sleep 0.5
done
grep -q "connected browsers: Chrome" "$OUT/mcp-serve.log" || { echo "The extension never connected; see $OUT" >&2; exit 1; }

cd "$OUT"
TRANSCRIPT="$OUT/transcript.txt"
: >"$TRANSCRIPT"
FAILED=0
# step <expect: ok|error> <args…>
step() {
  local expect=$1
  shift
  echo "\$ occtl browser call $*" >>"$TRANSCRIPT"
  local status=0
  "$OCCTL" browser call "$@" >>"$TRANSCRIPT" 2>&1 || status=$?
  echo >>"$TRANSCRIPT"
  if [[ $expect == ok && $status -ne 0 ]] || [[ $expect == error && $status -eq 0 ]]; then
    echo "UNEXPECTED (exit $status): $*" | tee -a "$TRANSCRIPT" >&2
    FAILED=1
  fi
}

"$OCCTL" browser status --support "$WORK/support" >"$OUT/status.txt" 2>&1
EXTENSION_ID=$(sed -n 's/^Extension ID: \([a-p]*\).*/\1/p' "$OUT/status.txt")
# popup <stop|resume>: press the popup's button, as the user would.
popup() {
  echo "\$ (toolbar popup) $1" >>"$TRANSCRIPT"
  if ! node "$TESTS/popup.mjs" "$PROFILE" "$EXTENSION_ID" "$1" >>"$TRANSCRIPT" 2>&1; then
    echo "UNEXPECTED: popup $1 failed" | tee -a "$TRANSCRIPT" >&2
    FAILED=1
  fi
  echo >>"$TRANSCRIPT"
}
# expect_in <file> <text>: fail unless the file contains the text.
expect_in() {
  grep -qF -- "$2" "$1" || { echo "UNEXPECTED: \"$2\" not in $(basename "$1")" | tee -a "$TRANSCRIPT" >&2; FAILED=1; }
}
step ok status
step ok tabs
step ok read
step ok type ref=e1 text=Jeff
step ok select ref=e2 value=green
step error type ref=e3 text=not-a-real-password
step ok click ref=e4
step ok wait_for "text=Hello, Jeff" timeout=5
step ok read query=hello
step ok screenshot --image-out screenshot.jpg
step ok scroll direction=bottom
step ok click ref=e6
step ok wait_for "text=Far button was clicked" timeout=5
step error select ref=e7 value=02
step ok click ref=e5
step error click ref=e4
step ok read
step ok back
step ok wait_for "text=You followed the link" gone=true timeout=5
step ok read query=hello
step ok snapshot
step ok snapshot query=details
step ok extract
expect_in "$TRANSCRIPT" "Table 1: Plans"
expect_in "$TRANSCRIPT" "| Pro | \$12 |"
step ok fill ref=e1 text=Ada
expect_in "$TRANSCRIPT" "~ [e1] textbox \"Your name\" value=\"Ada\""
step ok fill ref=e8 "text=Notes from the agent"
expect_in "$TRANSCRIPT" "(rich editor"
step ok click ref=e9
expect_in "$TRANSCRIPT" "+ [e10] button \"Hide details\""
step ok batch '{"steps":[{"operation":"fill","ref":"e1","text":"Grace"},{"operation":"select","ref":"e2","value":"Blue"},{"operation":"click","ref":"e4"},{"operation":"wait_for","text":"Hello, Grace! You picked Blue.","timeout":5}]}'
expect_in "$TRANSCRIPT" "Changes: 0 new, 0 gone, 2 changed."
expect_in "$TRANSCRIPT" "4. wait_for: Found"
step error batch '{"steps":[{"operation":"click","ref":"e4"},{"operation":"click","ref":"e99"}]}'
expect_in "$TRANSCRIPT" "Stopped at step 2 of 2"
step error batch '{"steps":[{"operation":"screenshot"}]}'
expect_in "$TRANSCRIPT" "Nothing ran."
step ok open "url=http://127.0.0.1:$PORT/page2.html"
SECOND=$(sed -n 's/^Opened tab \([0-9]*\)\..*/\1/p' "$TRANSCRIPT" | tail -1)
FOCUSED=$(sed -n 's/^tab \([0-9]*\) (focused.*/\1/p' "$TRANSCRIPT" | head -1)
step ok tabs
step error navigate url=file:///etc/hosts
# Unbound (no job): close only what these calls opened; keep; a saved screenshot.
step error close "tabId=$FOCUSED"
expect_in "$TRANSCRIPT" "isn't one of them"
step ok keep "tabId=$SECOND" why=result
step ok screenshot "tabId=$SECOND" save=true
expect_in "$TRANSCRIPT" "Saved to $WORK/job/output/127-0-0-1-"
ls "$WORK/job/output/"*.jpg >/dev/null 2>&1 || { echo "UNEXPECTED: no saved screenshot" | tee -a "$TRANSCRIPT" >&2; FAILED=1; }
step ok close "tabId=$SECOND"
expect_in "$TRANSCRIPT" "Closed tab $SECOND."

# A job's turn: its tabs go in a group named for the job, a kept tab stays, the rest close when the turn ends, and
# later calls are refused until the next turn.
jstep() {
  local expect=$1
  shift
  echo "\$ occtl browser call --job e2e-job $*" >>"$TRANSCRIPT"
  local status=0
  "$OCCTL" browser call --job e2e-job "$@" >>"$TRANSCRIPT" 2>&1 || status=$?
  echo >>"$TRANSCRIPT"
  if [[ $expect == ok && $status -ne 0 ]] || [[ $expect == error && $status -eq 0 ]]; then
    echo "UNEXPECTED (exit $status): --job $*" | tee -a "$TRANSCRIPT" >&2
    FAILED=1
  fi
}
jstep ok open "url=http://127.0.0.1:$PORT/page2.html"
JOB_A=$(sed -n 's/^Opened tab \([0-9]*\)\..*/\1/p' "$TRANSCRIPT" | tail -1)
jstep ok open "url=http://127.0.0.1:$PORT/page.html"
JOB_B=$(sed -n 's/^Opened tab \([0-9]*\)\..*/\1/p' "$TRANSCRIPT" | tail -1)
jstep ok keep "tabId=$JOB_B" why=result
jstep ok screenshot "tabId=$JOB_B" save=true
jstep error close "tabId=$FOCUSED"
echo "\$ (tab groups, through the DevTools protocol)" >>"$TRANSCRIPT"
node "$TESTS/tabgroups.mjs" "$PROFILE" "$EXTENSION_ID" >>"$TRANSCRIPT" 2>&1 || { echo "UNEXPECTED: tabgroups.mjs failed" | tee -a "$TRANSCRIPT" >&2; FAILED=1; }
echo >>"$TRANSCRIPT"
expect_in "$TRANSCRIPT" "group \"💰 Compare plan prices\""
echo "\$ kill -USR1 mcp-serve   (the job's turn ends)" >>"$TRANSCRIPT"
kill -USR1 "$SERVE"
for _ in $(seq 1 40); do grep -q "turn ended" "$OUT/mcp-serve.log" && break; sleep 0.25; done
grep "\[turn\]" "$OUT/mcp-serve.log" >>"$TRANSCRIPT" || true
echo >>"$TRANSCRIPT"
expect_in "$OUT/mcp-serve.log" "turn ended; browser: 5 calls"
expect_in "$OUT/mcp-serve.log" "1 kept"
step ok tabs
grep -q "^tab $JOB_A[: ]" <(tail -20 "$TRANSCRIPT") && { echo "UNEXPECTED: tab $JOB_A survived the end of the turn" | tee -a "$TRANSCRIPT" >&2; FAILED=1; }
grep -q "^tab $JOB_B[: ]" <(tail -20 "$TRANSCRIPT") || { echo "UNEXPECTED: kept tab $JOB_B was closed" | tee -a "$TRANSCRIPT" >&2; FAILED=1; }
jstep error tabs
expect_in "$TRANSCRIPT" "The agent turn ended."
echo "\$ kill -USR2 mcp-serve   (the next turn starts)" >>"$TRANSCRIPT"
kill -USR2 "$SERVE"
for _ in $(seq 1 40); do grep -q "turn started" "$OUT/mcp-serve.log" && break; sleep 0.25; done
jstep ok tabs

# Stop: a call in flight fails at once, and later calls are refused until Resume.
STARTED=$(date +%s)
"$OCCTL" browser call wait_for "text=This text never appears" timeout=60 >"$OUT/stopped-in-flight.txt" 2>&1 &
INFLIGHT=$!
sleep 1.5
popup stop
INFLIGHT_STATUS=0
wait $INFLIGHT || INFLIGHT_STATUS=$?
echo "in-flight wait_for ended after $(($(date +%s) - STARTED)) s with exit $INFLIGHT_STATUS" >>"$OUT/stopped-in-flight.txt"
cat "$OUT/stopped-in-flight.txt" >>"$TRANSCRIPT"
echo >>"$TRANSCRIPT"
[[ $INFLIGHT_STATUS -ne 0 && $(($(date +%s) - STARTED)) -lt 15 ]] || { echo "UNEXPECTED: Stop didn't end the in-flight call" | tee -a "$TRANSCRIPT" >&2; FAILED=1; }
expect_in "$OUT/stopped-in-flight.txt" "pressed Stop"
step error tabs
step error read
expect_in "$TRANSCRIPT" "until they press Resume"
popup resume
step ok tabs

# Stop between a job's calls, in a fresh turn: the tab it opened is the user's now, so the turn-end tidy-up leaves
# it open.
# turn_signal <USR1|USR2> <log text> <count>: signal mcp-serve and wait for its count-th log line with the text.
turn_signal() {
  kill -"$1" "$SERVE"
  for _ in $(seq 1 40); do [[ $(grep -c "$2" "$OUT/mcp-serve.log") -ge $3 ]] && break; sleep 0.25; done
}
turn_signal USR1 "turn ended" 2
turn_signal USR2 "turn started" 2
jstep ok open "url=http://127.0.0.1:$PORT/page2.html"
JOB_C=$(sed -n 's/^Opened tab \([0-9]*\)\..*/\1/p' "$TRANSCRIPT" | tail -1)
popup stop
popup resume
echo "\$ kill -USR1 mcp-serve   (the job's turn ends after the user's Stop)" >>"$TRANSCRIPT"
turn_signal USR1 "turn ended" 3
LAST_TURN=$(grep "\[turn\]" "$OUT/mcp-serve.log" | tail -1)
echo "$LAST_TURN" >>"$TRANSCRIPT"
echo >>"$TRANSCRIPT"
[[ $LAST_TURN == *"stopped by the user"* ]] || { echo "UNEXPECTED: the turn doesn't count the Stop between calls" | tee -a "$TRANSCRIPT" >&2; FAILED=1; }
step ok tabs
grep -q "^tab $JOB_C[: ]" <(tail -20 "$TRANSCRIPT") || { echo "UNEXPECTED: tab $JOB_C was closed after Stop" | tee -a "$TRANSCRIPT" >&2; FAILED=1; }
expect_in "$TRANSCRIPT" "[e7] combobox \"Card expiry month\" value=\"01\" (password or payment field: only the user fills it)"
expect_in "$TRANSCRIPT" "doesn't choose payment details"

if [[ $FAILED -eq 0 ]]; then echo "E2E PASSED ($TRANSCRIPT)"; else echo "E2E FAILED ($TRANSCRIPT)"; exit 1; fi
