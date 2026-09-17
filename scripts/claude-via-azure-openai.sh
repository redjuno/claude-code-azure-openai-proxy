#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-env.sh"
source "${SCRIPT_DIR}/proxy-runtime.sh"

export ANTHROPIC_BASE_URL="http://${LITELLM_HOST}:${LITELLM_PORT}"
export ANTHROPIC_AUTH_TOKEN="${LITELLM_MASTER_KEY}"
unset ANTHROPIC_API_KEY

export ANTHROPIC_MODEL="${CLAUDE_CODE_OPUS_ALIAS}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${CLAUDE_CODE_OPUS_ALIAS}"
export ANTHROPIC_DEFAULT_FABLE_MODEL="${CLAUDE_CODE_FABLE_ALIAS}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${CLAUDE_CODE_HAIKU_ALIAS}"
# No deployment maps to the sonnet tier, so it points at the opus one. Without
# this, Claude Code would ask the proxy for a real Anthropic model name and fail.
export ANTHROPIC_DEFAULT_SONNET_MODEL="${CLAUDE_CODE_OPUS_ALIAS}"
export CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_OPUS_ALIAS}"

# Claude Code does not know these aliases, so it would assume a 200k window
# and auto-compact far too early. gpt-5.6-sol and gpt-6-astra both take 922k
# input tokens.
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-922000}"

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}"
export DISABLE_TELEMETRY="${DISABLE_TELEMETRY:-1}"

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  python3 -c '
import os
import signal
import subprocess
import sys

process = subprocess.Popen(sys.argv[2:], start_new_session=True)

def terminate(exit_code):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    raise SystemExit(exit_code)

for handled_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(handled_signal, lambda number, _frame: terminate(128 + number))

try:
    raise SystemExit(process.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    terminate(124)
' "${timeout_seconds}" "$@"
}

azure_cost_preflight() {
  local subscription_id="${CLAUDE_AZURE_COST_SUBSCRIPTION_ID:-3c7b1819-c657-41ca-a22e-b6dc6d34fd98}"
  local refresh_script="${HOME:-}/.claude/azure_cost_statusline.py"
  local timeout_seconds="${CLAUDE_AZURE_PREFLIGHT_TIMEOUT:-5}"

  if ! command -v az >/dev/null 2>&1; then
    printf 'Warning: Azure CLI not found; cost HUD refresh skipped.\n' >&2
    return
  fi

  local auth_error
  if ! auth_error="$(run_with_timeout "${timeout_seconds}" az account get-access-token 2>&1 >/dev/null)"; then
    if grep -Eqi 'az login|interactive authentication|login required' <<<"${auth_error}"; then
      printf 'Azure CLI login required for cost HUD.\n'
      az login &
      preflight_pid=$!
      set +e
      wait "${preflight_pid}"
      login_status=$?
      set -e
      preflight_pid=""
      if (( login_status != 0 )); then
        printf 'Warning: Azure login failed; continuing without cost refresh.\n' >&2
        return
      fi
    else
      printf 'Warning: Azure authentication check failed; continuing without cost refresh.\n' >&2
      return
    fi
  fi

  if ! run_with_timeout "${timeout_seconds}" az rest --method get \
    --url "https://management.azure.com/subscriptions/${subscription_id}?api-version=2022-12-01" >/dev/null 2>&1; then
    printf 'Warning: could not access Azure subscription; continuing without cost refresh.\n' >&2
    return
  fi

  if [[ -n "${CLAUDE_AZURE_COST_REFRESH_COMMAND:-}" ]]; then
    nohup "${CLAUDE_AZURE_COST_REFRESH_COMMAND}" --refresh >/dev/null 2>&1 &
  elif [[ -f "${refresh_script}" ]]; then
    nohup python3 "${refresh_script}" --refresh >/dev/null 2>&1 &
  fi
}

session_id="session-$$"
preflight_pid=""
claude_pid=""
session_acquired=0
cleanup_started=0

cleanup() {
  local exit_code="${1:-$?}"

  if (( cleanup_started == 1 )); then
    return
  fi
  cleanup_started=1
  trap - EXIT INT TERM HUP

  if [[ -n "${preflight_pid}" ]] && process_is_alive "${preflight_pid}"; then
    kill -TERM "${preflight_pid}" 2>/dev/null || true
    for _ in {1..20}; do
      process_is_alive "${preflight_pid}" || break
      sleep 0.05
    done
    if process_is_alive "${preflight_pid}"; then
      kill -KILL "${preflight_pid}" 2>/dev/null || true
    fi
    wait "${preflight_pid}" 2>/dev/null || true
  fi
  if [[ -n "${claude_pid}" ]] && process_is_alive "${claude_pid}"; then
    kill -TERM "${claude_pid}" 2>/dev/null || true
    wait "${claude_pid}" 2>/dev/null || true
  fi
  if (( session_acquired == 1 )); then
    proxy_session_release "${session_id}" || true
    session_acquired=0
  fi
  exit "${exit_code}"
}

forward_signal() {
  local signal="$1"

  if [[ -n "${preflight_pid}" ]] && process_is_alive "${preflight_pid}"; then
    kill -"${signal}" "${preflight_pid}" 2>/dev/null || true
  elif [[ -n "${claude_pid}" ]] && process_is_alive "${claude_pid}"; then
    kill -"${signal}" "${claude_pid}" 2>/dev/null || true
    return
  fi

  case "${signal}" in
    HUP) exit 129 ;;
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

trap 'cleanup $?' EXIT
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
trap 'forward_signal HUP' HUP

azure_cost_preflight

if proxy_session_acquire "${session_id}"; then
  session_acquired=1
else
  exit 1
fi

printf 'Launching Claude Code via LiteLLM: %s, model=%s\n' "${ANTHROPIC_BASE_URL}" "${ANTHROPIC_MODEL}"
printf 'Using Claude Code config unchanged: %s\n' "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

set +e
claude "$@" <&0 &
claude_pid=$!
wait "${claude_pid}"
claude_exit_code=$?
set -e
claude_pid=""
cleanup "${claude_exit_code}"
