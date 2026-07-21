#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
BIN_DIR="${TEST_DIR}/bin"
ENV_FILE="${TEST_DIR}/test.env"
RUNTIME_DIR="${TEST_DIR}/runtime"
STARTS_FILE="${TEST_DIR}/proxy-starts"
CLAUDE_RUNS_FILE="${TEST_DIR}/claude-runs"
PORT="${CLAUDE_AZURE_TEST_PORT:-$((20000 + RANDOM % 20000))}"

cleanup() {
  if [[ -f "${RUNTIME_DIR}/proxy.pid" ]]; then
    kill -- "-$(<"${RUNTIME_DIR}/proxy.pid")" 2>/dev/null || true
  fi
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

mkdir -p "${BIN_DIR}"
: > "${STARTS_FILE}"
: > "${CLAUDE_RUNS_FILE}"

cat > "${ENV_FILE}" <<EOF
AZURE_API_KEY=test-key
AZURE_API_BASE=https://example.test
AZURE_API_VERSION=2025-03-01-preview
AZURE_DEPLOYMENT_OPUS=test-opus
AZURE_DEPLOYMENT_SONNET=test-sonnet
AZURE_DEPLOYMENT_HAIKU=test-haiku
LITELLM_MASTER_KEY=test-master-key
LITELLM_HOST=127.0.0.1
LITELLM_PORT=${PORT}
CLAUDE_CODE_OPUS_ALIAS=opus
CLAUDE_CODE_SONNET_ALIAS=sonnet
CLAUDE_CODE_HAIKU_ALIAS=haiku
EOF

cat > "${BIN_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$PWD" "${ANTHROPIC_BASE_URL}" "$*" >> "${MOCK_CLAUDE_RUNS}"
sleep "${MOCK_CLAUDE_SLEEP:-0}"
exit "${MOCK_CLAUDE_EXIT:-0}"
EOF
chmod +x "${BIN_DIR}/claude"

export PATH="${BIN_DIR}:${PATH}"
export CLAUDE_AZURE_ENV_FILE="${ENV_FILE}"
export CLAUDE_AZURE_RUNTIME_DIR="${RUNTIME_DIR}"
export CLAUDE_AZURE_PROXY_COMMAND="${ROOT_DIR}/tests/mock-proxy.py"
export CLAUDE_AZURE_PROXY_START_TIMEOUT=5
export CLAUDE_AZURE_PROXY_STOP_TIMEOUT=2
export MOCK_PROXY_STARTS="${STARTS_FILE}"
export MOCK_CLAUDE_RUNS="${CLAUDE_RUNS_FILE}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

wait_for_file() {
  local path="$1"
  local attempts=100
  while [[ ! -s "${path}" && ${attempts} -gt 0 ]]; do
    attempts=$((attempts - 1))
    sleep 0.05
  done
  [[ -s "${path}" ]] || fail "timed out waiting for ${path}"
}

wait_for_lease_count() {
  local expected="$1"
  local attempts=100
  local actual
  while (( attempts > 0 )); do
    actual="$(find "${RUNTIME_DIR}/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    if [[ "${actual}" == "${expected}" ]]; then
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 0.05
  done
  printf '%s\n' '--- first session log ---' >&2
  [[ -f "${TEST_DIR}/first.log" ]] && command cat "${TEST_DIR}/first.log" >&2
  printf '%s\n' '--- second session log ---' >&2
  [[ -f "${TEST_DIR}/second.log" ]] && command cat "${TEST_DIR}/second.log" >&2
  fail "timed out waiting for ${expected} session leases"
}

printf 'Test: automatic start, cwd preservation, exit code, and automatic stop\n'
work_dir="${TEST_DIR}/project"
mkdir -p "${work_dir}"
set +e
(
  cd "${work_dir}"
  MOCK_CLAUDE_EXIT=7 "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" --version
)
status=$?
set -e
[[ "${status}" == 7 ]] || fail "expected Claude exit code 7, got ${status}"
[[ "$(wc -l < "${STARTS_FILE}")" == 1 ]] || fail "expected one proxy start"
grep -F "${work_dir}|http://127.0.0.1:${PORT}|--version" "${CLAUDE_RUNS_FILE}" >/dev/null || fail "cwd, base URL, or arguments were not preserved"
[[ ! -f "${RUNTIME_DIR}/proxy.pid" ]] || fail "managed proxy metadata remained after last session"

printf 'Test: two concurrent sessions share one proxy until both exit\n'
: > "${STARTS_FILE}"
MOCK_CLAUDE_SLEEP=1 "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" first >"${TEST_DIR}/first.log" 2>&1 &
first_pid=$!
wait_for_file "${STARTS_FILE}"
MOCK_CLAUDE_SLEEP=2 "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" second >"${TEST_DIR}/second.log" 2>&1 &
second_pid=$!
wait_for_lease_count 2
[[ "$(wc -l < "${STARTS_FILE}")" == 1 ]] || fail "concurrent sessions started more than one proxy"
wait "${first_pid}"
if [[ ! -f "${RUNTIME_DIR}/proxy.pid" ]]; then
  printf '%s\n' '--- first session log ---' >&2
  command cat "${TEST_DIR}/first.log" >&2
  printf '%s\n' '--- second session log ---' >&2
  command cat "${TEST_DIR}/second.log" >&2
  find "${RUNTIME_DIR}" -maxdepth 2 -type f -print -exec cat {} \; >&2 || true
  fail "proxy metadata disappeared while second session was active"
fi
proxy_pid="$(<"${RUNTIME_DIR}/proxy.pid")"
kill -0 "${proxy_pid}" 2>/dev/null || fail "proxy stopped while second session was active"
wait "${second_pid}"
[[ ! -f "${RUNTIME_DIR}/proxy.pid" ]] || fail "proxy remained after final concurrent session"

printf 'Test: an external compatible proxy is reused and not stopped\n'
external_starts="${TEST_DIR}/external-starts"
PORT=$((PORT + 1))
python3 - "${ENV_FILE}" "${PORT}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
port = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
path.write_text("\n".join(f"LITELLM_PORT={port}" if line.startswith("LITELLM_PORT=") else line for line in lines) + "\n", encoding="utf-8")
PY
export LITELLM_PORT="${PORT}"
export LITELLM_MASTER_KEY=test-master-key
export MOCK_PROXY_STARTS="${external_starts}"
MOCK_PROXY_STARTS="${external_starts}" "${ROOT_DIR}/tests/mock-proxy.py" >"${TEST_DIR}/external.log" 2>&1 &
external_pid=$!
sleep 0.2
if [[ ! -s "${external_starts}" ]]; then
  printf '%s\n' '--- external proxy log ---' >&2
  command cat "${TEST_DIR}/external.log" >&2
fi
wait_for_file "${external_starts}"
if ! "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" external >"${TEST_DIR}/reuse.log" 2>&1; then
  printf '%s\n' '--- external reuse launcher log ---' >&2
  command cat "${TEST_DIR}/reuse.log" >&2
  printf '%s\n' '--- managed proxy log ---' >&2
  command cat "${RUNTIME_DIR}/proxy.log" >&2 || true
  printf '%s\n' '--- external process ---' >&2
  ps -p "${external_pid}" -o pid,stat,cmd >&2 || true
  fail "external proxy reuse launcher failed"
fi
kill -0 "${external_pid}" 2>/dev/null || fail "external proxy was stopped"
[[ ! -f "${RUNTIME_DIR}/proxy.pid" ]] || fail "external proxy was incorrectly marked managed"
kill "${external_pid}"
wait "${external_pid}" 2>/dev/null || true

printf 'All lifecycle tests passed.\n'
