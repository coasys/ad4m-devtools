#!/bin/bash
# ci-logs.sh — Fetch CircleCI CI logs for a GitHub PR
#
# Usage:
#   ci-logs.sh <owner/repo> <pr-number> [options]
#
# Options:
#   --all              Show all jobs (not just failing)
#   --job <name>       Show only this job
#   --tail <lines>     Truncate each step to last N lines (default: no truncation)
#   --llm              LLM-optimised output: strips noise, keeps errors + surrounding context
#   --llm-context <n>  Lines of context around errors in --llm mode (default: 10)
#   --steps            Show all steps (default: only failed step, or last step if none failed)
#
# Examples:
#   ci-logs.sh coasys/ad4m 760                        # Full logs for failing jobs
#   ci-logs.sh coasys/ad4m 760 --all                  # All job statuses + failing logs
#   ci-logs.sh coasys/ad4m 760 --job integration-tests # Full log for one job
#   ci-logs.sh coasys/ad4m 760 --llm                  # LLM-friendly error digest
#   ci-logs.sh coasys/ad4m 760 --job build --steps    # All steps for a specific job
#   ci-logs.sh coasys/ad4m 760 --tail 200             # Last 200 lines per step

set -euo pipefail

REPO="${1:?Usage: ci-logs.sh <owner/repo> <pr-number>}"
PR="${2:?Usage: ci-logs.sh <owner/repo> <pr-number>}"
SHOW_ALL=false
TARGET_JOB=""
TAIL_LINES=0  # 0 = no truncation
LLM_MODE=false
LLM_CONTEXT=10
SHOW_ALL_STEPS=false

shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) SHOW_ALL=true; shift ;;
    --job) TARGET_JOB="$2"; shift 2 ;;
    --tail) TAIL_LINES="$2"; shift 2 ;;
    --llm) LLM_MODE=true; shift ;;
    --llm-context) LLM_CONTEXT="$2"; shift 2 ;;
    --steps) SHOW_ALL_STEPS=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# 1. Get PR check statuses from GitHub
echo "=== PR #${PR} CI Status ==="
CHECKS=$(gh pr checks "$PR" -R "$REPO" 2>/dev/null || true)
if [ -z "$CHECKS" ]; then
  echo "No checks found for PR #${PR}"
  exit 1
fi

# Extract the CircleCI workflow URL
WORKFLOW_URL=$(echo "$CHECKS" | grep -i 'circleci' | head -1 | awk '{print $NF}')
if [ -z "$WORKFLOW_URL" ]; then
  echo "No CircleCI checks found"
  echo "$CHECKS"
  exit 1
fi

WORKFLOW_ID=$(echo "$WORKFLOW_URL" | sed -E 's|.*/workflow/([a-f0-9-]+).*|\1|')

# 2. Get project slug from workflow
PROJECT_SLUG=$(curl -sL "https://circleci.com/api/v2/workflow/${WORKFLOW_ID}" -H "Accept: application/json" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('project_slug',''))" 2>/dev/null)

# 3. Get jobs
JOBS_JSON=$(curl -sL "https://circleci.com/api/v2/workflow/${WORKFLOW_ID}/job" -H "Accept: application/json")

echo "$JOBS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
for j in items:
    name = j['name']
    status = j['status']
    num = j.get('job_number', '?')
    icon = '✅' if status == 'success' else '❌' if status == 'failed' else '⏳' if status == 'running' else '⏸️'
    print(f'{icon} {name}: {status} (#{num})')
"
echo ""

# 4. Select jobs to show logs for
SELECTED_JOBS=$(echo "$JOBS_JSON" | SHOW_ALL="$SHOW_ALL" TARGET_JOB="$TARGET_JOB" python3 -c "
import sys, json, os
data = json.load(sys.stdin)
show_all = os.environ.get('SHOW_ALL', '') == 'true'
target = os.environ.get('TARGET_JOB', '')
for j in data.get('items', []):
    if target and j['name'] != target:
        continue
    if show_all or j['status'] == 'failed' or target:
        print(f'{j[\"name\"]}|{j[\"job_number\"]}|{j[\"status\"]}')
")

if [ -z "$SELECTED_JOBS" ]; then
  echo "No failing jobs found! 🎉"
  exit 0
fi

# --- Helper: strip ANSI codes and extract text from CircleCI log JSON ---
extract_log_text() {
  python3 -c "
import json, sys, re

raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)

try:
    data = json.loads(raw)
    parts = []
    for entry in data:
        if isinstance(entry, dict):
            parts.append(entry.get('message', ''))
        elif isinstance(entry, str):
            parts.append(entry)
    text = ''.join(parts)
except (json.JSONDecodeError, TypeError):
    text = raw

# Strip ANSI escape codes
text = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text)
# Strip carriage returns (progress bars etc.)
text = re.sub(r'\r', '', text)
print(text, end='')
"
}

# --- Helper: LLM-friendly filtering ---
llm_filter() {
  local ctx="$1"
  python3 -c "
import sys, re

context_lines = int(sys.argv[1])
lines = sys.stdin.read().splitlines()
if not lines:
    sys.exit(0)

# Patterns that indicate errors, failures, or important diagnostics
error_pats = [
    r'(?i)\berror\b',
    r'(?i)\bfail(ed|ure|ing)?\b',
    r'(?i)\bpanic\b',
    r'(?i)\brejected\b',
    r'(?i)\bexception\b',
    r'(?i)\bassert(ion)?\b',
    r'(?i)\btimeout\b',
    r'(?i)\bdenied\b',
    r'(?i)\bnot found\b',
    r'(?i)\bcannot\b',
    r'(?i)\bcould not\b',
    r'(?i)thread .* panicked',
    r'(?i)FAILED',
    r'(?i)exited with',
    r'(?i)exit code [^0]',
    r'(?i)stack trace',
    r'(?i)backtrace',
    r'^\s*\d+\)',                  # Numbered test failures
    r'(?i)passing|failing|pending', # Test summaries
    r'(?i)^\s*at\s+',              # Stack frames
    r'(?i)Caused by',
]

# Patterns for lines that are pure noise in CI logs
noise_pats = [
    r'^\s*$',                      # Blank lines (handled by dedup below)
    r'^\s*\.\.\.\s*$',            # Progress dots
    r'^\s*Compiling\s+',          # Cargo compiling lines
    r'^\s*Downloading\s+',        # Cargo/npm downloading
    r'^\s*Downloaded\s+',
    r'^\s*Installing\s+',
    r'^\s*Unpacking\s+',
    r'^\s*Resolving\s+',
    r'^\s*Fetching\s+',
    r'^\s*Fresh\s+',
    r'^\s*Blocking\s+waiting\s+for\s+file\s+lock',
    r'npm warn',
    r'^\s*added\s+\d+\s+packages',
]

error_re = [re.compile(p) for p in error_pats]
noise_re = [re.compile(p) for p in noise_pats]

# Find error line indices
error_indices = set()
for i, line in enumerate(lines):
    if any(r.search(line) for r in error_re):
        error_indices.add(i)

# Expand with context
include = set()
for idx in error_indices:
    for c in range(max(0, idx - context_lines), min(len(lines), idx + context_lines + 1)):
        include.add(c)

# Always include first 5 and last 10 lines (step name, final summary)
for i in range(min(5, len(lines))):
    include.add(i)
for i in range(max(0, len(lines) - 10), len(lines)):
    include.add(i)

# Output with gap markers, filtering noise
sorted_indices = sorted(include)
prev = -2
for i in sorted_indices:
    line = lines[i]
    if any(r.search(line) for r in noise_re):
        continue
    if i > prev + 1:
        print('  [...]')
    print(line)
    prev = i
" "$ctx"
}

while IFS='|' read -r JOB_NAME JOB_NUM JOB_STATUS; do
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "━━━ ${JOB_NAME} (#${JOB_NUM}) — ${JOB_STATUS} ━━━"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Get full job detail with all step output URLs via v1.1 API
  STEP_DATA=$(curl -sL "https://circleci.com/api/v1.1/project/${PROJECT_SLUG}/${JOB_NUM}" -H "Accept: application/json" 2>/dev/null)

  if [ -z "$STEP_DATA" ]; then
    echo "(Could not fetch job details)"
    echo ""
    continue
  fi

  # Extract step info: name, status, output_url — for all relevant steps
  STEPS=$(python3 -c "
import json, sys, os

show_all_steps = os.environ.get('SHOW_ALL_STEPS', '') == 'true'

try:
    data = json.loads(sys.stdin.read())
except (json.JSONDecodeError, TypeError):
    sys.exit(0)

steps = data.get('steps', [])
results = []

for step in steps:
    for action in step.get('actions', []):
        name = action.get('name', step.get('name', '?'))
        status = action.get('status', '?')
        url = action.get('output_url', '')
        has_output = action.get('has_output', False)

        if show_all_steps:
            results.append((name, status, url, has_output))
        elif status == 'failed' or action.get('failed'):
            results.append((name, status, url, has_output))

# If no failed steps found and not showing all, show the last step with output
if not results and not show_all_steps:
    for step in reversed(steps):
        for action in step.get('actions', []):
            url = action.get('output_url', '')
            has_output = action.get('has_output', False)
            if url or has_output:
                name = action.get('name', step.get('name', '?'))
                status = action.get('status', '?')
                results.append((name, status, url, has_output))
                break
        if results:
            break

for name, status, url, has_output in results:
    # Use | as delimiter — step names shouldn't contain it
    print(f'{name}|{status}|{url}|{has_output}')
" SHOW_ALL_STEPS="$SHOW_ALL_STEPS" <<< "$STEP_DATA")

  if [ -z "$STEPS" ]; then
    echo "(No step output found)"
    echo ""
    continue
  fi

  while IFS='|' read -r STEP_NAME STEP_STATUS STEP_URL STEP_HAS_OUTPUT; do
    STEP_ICON="✅"
    [[ "$STEP_STATUS" == "failed" ]] && STEP_ICON="❌"
    [[ "$STEP_STATUS" == "running" ]] && STEP_ICON="⏳"

    echo ""
    echo "── ${STEP_ICON} Step: ${STEP_NAME} (${STEP_STATUS}) ──"

    if [ -z "$STEP_URL" ]; then
      echo "(No output URL)"
      continue
    fi

    # Fetch the log content
    RAW_LOG=$(curl -sL "$STEP_URL" 2>/dev/null)

    if [ -z "$RAW_LOG" ]; then
      echo "(Empty log output)"
      continue
    fi

    # Extract clean text
    CLEAN=$(echo "$RAW_LOG" | extract_log_text)

    if [ -z "$CLEAN" ]; then
      echo "(No text content)"
      continue
    fi

    # Apply output mode
    if [ "$LLM_MODE" = true ]; then
      echo "$CLEAN" | llm_filter "$LLM_CONTEXT"
    elif [ "$TAIL_LINES" -gt 0 ]; then
      echo "$CLEAN" | tail -n "$TAIL_LINES"
    else
      echo "$CLEAN"
    fi

  done <<< "$STEPS"

  echo ""
done <<< "$SELECTED_JOBS"
