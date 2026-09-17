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
# Only two deployments exist, so the sonnet/haiku tiers point at the opus one.
# Without this, background Claude Code calls would ask the proxy for real
# Anthropic model names and fail.
export ANTHROPIC_DEFAULT_SONNET_MODEL="${CLAUDE_CODE_OPUS_ALIAS}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${CLAUDE_CODE_OPUS_ALIAS}"
export CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_OPUS_ALIAS}"

# Claude Code does not know these aliases, so it would assume a 200k window
# and auto-compact far too early. gpt-5.6-sol and gpt-6-astra both take 922k
# input tokens.
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-922000}"

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}"
export DISABLE_TELEMETRY="${DISABLE_TELEMETRY:-1}"

session_id="session-$$"
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

  if [[ -n "${claude_pid}" ]] && process_is_alive "${claude_pid}"; then
    kill -"${signal}" "${claude_pid}" 2>/dev/null || true
  fi
}

trap 'cleanup $?' EXIT
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM
trap 'forward_signal HUP' HUP

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
