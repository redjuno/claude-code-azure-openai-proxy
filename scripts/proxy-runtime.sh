#!/usr/bin/env bash

RUNTIME_DIR="${CLAUDE_AZURE_RUNTIME_DIR:-${ROOT_DIR}/.claude-runtime}"
RUNTIME_LOCK_DIR="${RUNTIME_DIR}/lock"
SESSIONS_DIR="${RUNTIME_DIR}/sessions"
PROXY_PID_FILE="${RUNTIME_DIR}/proxy.pid"
PROXY_STARTED_FILE="${RUNTIME_DIR}/proxy.started"
PROXY_PORT_FILE="${RUNTIME_DIR}/proxy.port"
PROXY_STOP_MODE_FILE="${RUNTIME_DIR}/proxy.stop-mode"
PROXY_LOG_FILE="${RUNTIME_DIR}/proxy.log"
PROXY_START_TIMEOUT="${CLAUDE_AZURE_PROXY_START_TIMEOUT:-120}"
PROXY_STOP_TIMEOUT="${CLAUDE_AZURE_PROXY_STOP_TIMEOUT:-10}"
RUNTIME_LOCK_TIMEOUT="${CLAUDE_AZURE_LOCK_TIMEOUT:-45}"
RUNTIME_LOCK_HELD=0

runtime_prepare() {
  mkdir -p "${RUNTIME_DIR}" "${SESSIONS_DIR}"
}

process_is_alive() {
  local pid="${1:-}"
  [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null
}

process_started_at() {
  local pid="$1"
  local stat_file="/proc/${pid}/stat"

  if [[ -r "${stat_file}" ]]; then
    command cut -d ' ' -f 22 "${stat_file}" 2>/dev/null || true
  else
    ps -p "${pid}" -o lstart= 2>/dev/null | xargs 2>/dev/null || true
  fi
}

runtime_lock_acquire() {
  local attempts=0
  local incomplete_attempts=0
  local max_attempts=$((RUNTIME_LOCK_TIMEOUT * 10))
  local owner_pid owner_started current_started

  runtime_prepare
  while ! mkdir "${RUNTIME_LOCK_DIR}" 2>/dev/null; do
    owner_pid="$(command cat "${RUNTIME_LOCK_DIR}/pid" 2>/dev/null || true)"
    owner_started="$(command cat "${RUNTIME_LOCK_DIR}/started" 2>/dev/null || true)"
    current_started="$(process_started_at "${owner_pid}" 2>/dev/null || true)"
    if [[ -z "${owner_pid}" || -z "${owner_started}" ]]; then
      incomplete_attempts=$((incomplete_attempts + 1))
      if (( incomplete_attempts >= 10 )); then
        rm -rf "${RUNTIME_LOCK_DIR}"
        incomplete_attempts=0
      else
        sleep 0.1
      fi
      continue
    fi
    incomplete_attempts=0
    if [[ "${owner_started}" != "${current_started}" ]] || ! process_is_alive "${owner_pid}"; then
      rm -rf "${RUNTIME_LOCK_DIR}"
      continue
    fi

    if (( attempts >= max_attempts )); then
      printf 'Timed out waiting for the Claude Azure runtime lock held by PID %s.\n' "${owner_pid}" >&2
      return 1
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done

  printf '%s\n' "$$" > "${RUNTIME_LOCK_DIR}/pid"
  printf '%s\n' "$(process_started_at "$$")" > "${RUNTIME_LOCK_DIR}/started"
  RUNTIME_LOCK_HELD=1
}

runtime_lock_release() {
  local owner_pid

  if (( RUNTIME_LOCK_HELD != 1 )); then
    return
  fi
  owner_pid="$(command cat "${RUNTIME_LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ "${owner_pid}" == "$$" ]]; then
    rm -rf "${RUNTIME_LOCK_DIR}"
  fi
  RUNTIME_LOCK_HELD=0
}

proxy_clear_metadata() {
  rm -f \
    "${PROXY_PID_FILE}" \
    "${PROXY_STARTED_FILE}" \
    "${PROXY_PORT_FILE}" \
    "${PROXY_STOP_MODE_FILE}"
}

proxy_metadata_matches_process() {
  local pid recorded_started current_started

  [[ -f "${PROXY_PID_FILE}" ]] || return 1
  pid="$(<"${PROXY_PID_FILE}")"
  process_is_alive "${pid}" || return 1

  [[ -s "${PROXY_STARTED_FILE}" ]] || return 1
  recorded_started="$(<"${PROXY_STARTED_FILE}")"
  current_started="$(process_started_at "${pid}")"
  [[ -n "${current_started}" && "${recorded_started}" == "${current_started}" ]] || return 1
}

proxy_is_ready() {
  curl --silent --show-error --fail --max-time 2 \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "x-api-key: ${LITELLM_MASTER_KEY}" \
    "http://${LITELLM_HOST}:${LITELLM_PORT}/health/readiness" \
    >/dev/null 2>&1
}

proxy_wait_until_ready() {
  local pid="$1"
  local attempts=$((PROXY_START_TIMEOUT * 5))
  local attempt=0

  while (( attempt < attempts )); do
    if proxy_is_ready; then
      return 0
    fi
    if ! process_is_alive "${pid}"; then
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 0.2
  done
  return 1
}

proxy_start_managed_locked() {
  local pid stop_mode started_at

  : > "${PROXY_LOG_FILE}"
  local proxy_command="${CLAUDE_AZURE_PROXY_COMMAND:-${ROOT_DIR}/scripts/start-proxy.sh}"

  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash -c 'exec "$@"' _ "${proxy_command}" \
      >>"${PROXY_LOG_FILE}" 2>&1 </dev/null &
    stop_mode=group
  else
    nohup "${proxy_command}" \
      >>"${PROXY_LOG_FILE}" 2>&1 </dev/null &
    stop_mode=pid
  fi
  pid=$!
  started_at="$(process_started_at "${pid}")"

  printf '%s\n' "${pid}" > "${PROXY_PID_FILE}"
  printf '%s\n' "${started_at}" > "${PROXY_STARTED_FILE}"
  printf '%s\n' "${LITELLM_PORT}" > "${PROXY_PORT_FILE}"
  printf '%s\n' "${stop_mode}" > "${PROXY_STOP_MODE_FILE}"

  printf 'Starting managed LiteLLM proxy in the background (PID %s).\n' "${pid}"
  if proxy_wait_until_ready "${pid}"; then
    printf 'LiteLLM proxy is ready at http://%s:%s.\n' "${LITELLM_HOST}" "${LITELLM_PORT}"
    return 0
  fi

  printf 'LiteLLM proxy did not become ready within %s seconds.\n' "${PROXY_START_TIMEOUT}" >&2
  printf 'Proxy log: %s\n' "${PROXY_LOG_FILE}" >&2
  proxy_stop_managed_locked
  return 1
}

proxy_signal_target() {
  local signal="$1"
  local pid="$2"
  local stop_mode="$3"

  if [[ "${stop_mode}" == group ]]; then
    kill -"${signal}" -- "-${pid}" 2>/dev/null || kill -"${signal}" "${pid}" 2>/dev/null || true
  else
    kill -"${signal}" "${pid}" 2>/dev/null || true
  fi
}

proxy_target_is_alive() {
  local pid="$1"
  local stop_mode="$2"

  if [[ "${stop_mode}" == group ]]; then
    kill -0 -- "-${pid}" 2>/dev/null
  else
    process_is_alive "${pid}"
  fi
}

proxy_stop_managed_locked() {
  local pid stop_mode attempts attempt=0

  if ! proxy_metadata_matches_process; then
    proxy_clear_metadata
    return 0
  fi

  pid="$(<"${PROXY_PID_FILE}")"
  stop_mode="$(command cat "${PROXY_STOP_MODE_FILE}" 2>/dev/null || printf 'pid')"
  attempts=$((PROXY_STOP_TIMEOUT * 10))

  printf 'Stopping managed LiteLLM proxy (PID %s).\n' "${pid}"
  proxy_signal_target TERM "${pid}" "${stop_mode}"
  while proxy_target_is_alive "${pid}" "${stop_mode}" && (( attempt < attempts )); do
    attempt=$((attempt + 1))
    sleep 0.1
  done

  if proxy_target_is_alive "${pid}" "${stop_mode}"; then
    printf 'Proxy did not stop within %s seconds; sending SIGKILL.\n' "${PROXY_STOP_TIMEOUT}" >&2
    proxy_signal_target KILL "${pid}" "${stop_mode}"
  fi

  attempt=0
  while proxy_is_ready && (( attempt < attempts )); do
    attempt=$((attempt + 1))
    sleep 0.1
  done
  if proxy_is_ready; then
    printf 'The managed proxy process stopped, but port %s is still serving the configured LiteLLM credentials.\n' \
      "${LITELLM_PORT}" >&2
  fi
  proxy_clear_metadata
}

proxy_clean_stale_leases_locked() {
  local lease pid recorded_started current_started

  shopt -s nullglob
  for lease in "${SESSIONS_DIR}"/*; do
    IFS=' ' read -r pid recorded_started < "${lease}" || true
    current_started="$(process_started_at "${pid}" 2>/dev/null || true)"
    if [[ -z "${pid}" || -z "${recorded_started}" || "${recorded_started}" != "${current_started}" ]] || ! process_is_alive "${pid}"; then
      rm -f "${lease}"
    fi
  done
  shopt -u nullglob
}

proxy_active_lease_count_locked() {
  local leases

  proxy_clean_stale_leases_locked
  shopt -s nullglob
  leases=("${SESSIONS_DIR}"/*)
  shopt -u nullglob
  printf '%s\n' "${#leases[@]}"
}

proxy_ensure_locked() {
  local managed_port pid

  if proxy_metadata_matches_process; then
    managed_port="$(command cat "${PROXY_PORT_FILE}" 2>/dev/null || true)"
    pid="$(<"${PROXY_PID_FILE}")"
    if [[ "${managed_port}" != "${LITELLM_PORT}" ]]; then
      printf 'Managed proxy PID %s uses port %s, but .env now requests port %s.\n' \
        "${pid}" "${managed_port:-unknown}" "${LITELLM_PORT}" >&2
      printf 'Finish active Claude sessions or run make stop before retrying.\n' >&2
      return 1
    fi
    if proxy_wait_until_ready "${pid}"; then
      return 0
    fi
    printf 'Managed proxy PID %s is running but is not ready. See %s\n' "${pid}" "${PROXY_LOG_FILE}" >&2
    return 1
  fi

  proxy_clear_metadata
  if proxy_is_ready; then
    printf 'Reusing an existing LiteLLM proxy at http://%s:%s; it will not be stopped automatically.\n' \
      "${LITELLM_HOST}" "${LITELLM_PORT}"
    return 0
  fi

  proxy_start_managed_locked
}

proxy_session_acquire() {
  local session_id="$1"

  runtime_lock_acquire || return 1
  if ! proxy_ensure_locked; then
    runtime_lock_release
    return 1
  fi
  printf '%s %s\n' "$$" "$(process_started_at "$$")" > "${SESSIONS_DIR}/${session_id}"
  runtime_lock_release
}

proxy_session_release() {
  local session_id="$1"
  local lease_count

  runtime_lock_acquire || return 1
  rm -f "${SESSIONS_DIR}/${session_id}"
  lease_count="$(proxy_active_lease_count_locked)"
  if [[ "${lease_count}" == 0 ]] && proxy_metadata_matches_process; then
    proxy_stop_managed_locked
  fi
  runtime_lock_release
}

proxy_runtime_stop() {
  local force="${1:-}"
  local lease_count

  runtime_lock_acquire || return 1
  lease_count="$(proxy_active_lease_count_locked)"
  if [[ "${lease_count}" != 0 && "${force}" != --force ]]; then
    printf 'Refusing to stop the proxy while %s Claude Azure session(s) are active.\n' "${lease_count}" >&2
    printf 'Use make stop-force only if those sessions may be interrupted.\n' >&2
    runtime_lock_release
    return 1
  fi

  if proxy_metadata_matches_process; then
    proxy_stop_managed_locked
  elif proxy_is_ready; then
    printf 'A compatible external proxy is listening at http://%s:%s; it is not managed and was not stopped.\n' \
      "${LITELLM_HOST}" "${LITELLM_PORT}"
    proxy_clear_metadata
  else
    printf 'No managed LiteLLM proxy is running.\n'
    proxy_clear_metadata
  fi
  runtime_lock_release
}

proxy_runtime_status() {
  local lease_count pid managed_port

  runtime_lock_acquire || return 1
  lease_count="$(proxy_active_lease_count_locked)"
  if proxy_metadata_matches_process; then
    pid="$(<"${PROXY_PID_FILE}")"
    managed_port="$(command cat "${PROXY_PORT_FILE}" 2>/dev/null || true)"
    printf 'Managed LiteLLM proxy: running (PID %s, port %s)\n' "${pid}" "${managed_port:-unknown}"
    if proxy_is_ready; then
      printf 'Readiness: ready\n'
    else
      printf 'Readiness: not ready\n'
    fi
  elif proxy_is_ready; then
    proxy_clear_metadata
    printf 'LiteLLM proxy: external/unmanaged at http://%s:%s\n' "${LITELLM_HOST}" "${LITELLM_PORT}"
  else
    proxy_clear_metadata
    printf 'LiteLLM proxy: stopped\n'
  fi
  printf 'Active Claude Azure sessions: %s\n' "${lease_count}"
  printf 'Runtime directory: %s\n' "${RUNTIME_DIR}"
  printf 'Proxy log: %s\n' "${PROXY_LOG_FILE}"
  runtime_lock_release
}

proxy_runtime_main() {
  local command="${1:-status}"

  case "${command}" in
    status)
      proxy_runtime_status
      ;;
    stop)
      proxy_runtime_stop "${2:-}"
      ;;
    *)
      printf 'Usage: %s {status|stop [--force]}\n' "$0" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure-env.sh"
  trap runtime_lock_release EXIT
  proxy_runtime_main "$@"
fi
