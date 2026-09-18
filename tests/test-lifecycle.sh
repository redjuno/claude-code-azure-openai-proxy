#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
BIN_DIR="${TEST_DIR}/bin"
ENV_FILE="${TEST_DIR}/test.env"
RUNTIME_DIR="${TEST_DIR}/runtime"
STARTS_FILE="${TEST_DIR}/proxy-starts"
CLAUDE_RUNS_FILE="${TEST_DIR}/claude-runs"
AZ_RUNS_FILE="${TEST_DIR}/az-runs"
COST_REFRESHES_FILE="${TEST_DIR}/cost-refreshes"
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
: > "${AZ_RUNS_FILE}"
: > "${COST_REFRESHES_FILE}"

cat > "${ENV_FILE}" <<EOF
AZURE_API_KEY=test-key
AZURE_API_BASE=https://example.test
AZURE_API_VERSION=2025-03-01-preview
AZURE_DEPLOYMENT_OPUS=test-opus-deployment
AZURE_DEPLOYMENT_FABLE=test-fable-deployment
AZURE_DEPLOYMENT_HAIKU=test-haiku-deployment
CLAUDE_AZURE_TENANT_ID=ktopen.onmicrosoft.com
CLAUDE_AZURE_COST_SUBSCRIPTION_ID=3c7b1819-c657-41ca-a22e-b6dc6d34fd98
LITELLM_MASTER_KEY=test-master-key
LITELLM_HOST=127.0.0.1
LITELLM_PORT=${PORT}
CLAUDE_CODE_OPUS_ALIAS=test-model
CLAUDE_CODE_FABLE_ALIAS=test-fable
CLAUDE_CODE_HAIKU_ALIAS=test-haiku
EOF

cat > "${BIN_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$PWD" "${ANTHROPIC_BASE_URL}" "$*" >> "${MOCK_CLAUDE_RUNS}"
sleep "${MOCK_CLAUDE_SLEEP:-0}"
exit "${MOCK_CLAUDE_EXIT:-0}"
EOF
chmod +x "${BIN_DIR}/claude"

cat > "${BIN_DIR}/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_AZ_RUNS}"
case "$1 $2" in
  'account get-access-token')
    sleep "${MOCK_AZ_ACCESS_TOKEN_SLEEP:-0}"
    if [[ -n "${MOCK_AZ_LOGIN_MARKER:-}" && -e "${MOCK_AZ_LOGIN_MARKER}" ]]; then
      exit 0
    fi
    status="${MOCK_AZ_ACCESS_TOKEN_EXIT:-0}"
    if (( status != 0 )); then
      printf '%s\n' "${MOCK_AZ_ACCESS_TOKEN_ERROR:-Interactive authentication is needed. Please run: az login}" >&2
    fi
    exit "${status}"
    ;;
  'rest --method')
    exit "${MOCK_AZ_SUBSCRIPTION_ACCESS_EXIT:-0}"
    ;;
  'login --tenant')
    if [[ -n "${MOCK_AZ_LOGIN_STDIN:-}" ]]; then
      IFS= read -r login_input || login_input=""
      printf '%s\n' "${login_input}" > "${MOCK_AZ_LOGIN_STDIN}"
    fi
    sleep "${MOCK_AZ_LOGIN_SLEEP:-0}"
    status="${MOCK_AZ_LOGIN_EXIT:-0}"
    if [[ "${status}" == 0 && -n "${MOCK_AZ_LOGIN_MARKER:-}" ]]; then
      : > "${MOCK_AZ_LOGIN_MARKER}"
    fi
    exit "${status}"
    ;;
esac
EOF
chmod +x "${BIN_DIR}/az"

cat > "${BIN_DIR}/azure-cost-refresh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_COST_REFRESHES}"
sleep "${MOCK_COST_REFRESH_SLEEP:-0}"
if [[ -n "${MOCK_COST_REFRESH_DONE:-}" ]]; then
  : > "${MOCK_COST_REFRESH_DONE}"
fi
exit "${MOCK_COST_REFRESH_EXIT:-0}"
EOF
chmod +x "${BIN_DIR}/azure-cost-refresh"

export PATH="${BIN_DIR}:${PATH}"
export CLAUDE_AZURE_ENV_FILE="${ENV_FILE}"
export CLAUDE_AZURE_RUNTIME_DIR="${RUNTIME_DIR}"
export CLAUDE_AZURE_PROXY_COMMAND="${ROOT_DIR}/tests/mock-proxy.py"
export CLAUDE_AZURE_PROXY_START_TIMEOUT=5
export CLAUDE_AZURE_PROXY_STOP_TIMEOUT=2
export MOCK_PROXY_STARTS="${STARTS_FILE}"
export MOCK_CLAUDE_RUNS="${CLAUDE_RUNS_FILE}"
export MOCK_AZ_RUNS="${AZ_RUNS_FILE}"
export MOCK_COST_REFRESHES="${COST_REFRESHES_FILE}"
export CLAUDE_AZURE_COST_REFRESH_SCRIPT="${BIN_DIR}/azure-cost-refresh"
export CLAUDE_AZURE_LOGIN_STDIN="${TEST_DIR}/login-stdin"
printf '%s\n' 'tenant-login-input' > "${CLAUDE_AZURE_LOGIN_STDIN}"

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
    if (( actual == expected )); then
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

printf 'Test: LiteLLM receives public and additional CA certificates\n'
SYSTEM_CA_FILE="${TEST_DIR}/system-ca.pem"
EXTRA_CA_FILE="${TEST_DIR}/extra-ca.pem"
PROXY_ENV_FILE="${TEST_DIR}/proxy-env"
printf '%s\n' 'public-ca' > "${SYSTEM_CA_FILE}"
printf '%s\n' 'vpn-ca' > "${EXTRA_CA_FILE}"
cat > "${BIN_DIR}/uvx" <<'EOF'
#!/usr/bin/env bash
printf 'UV_NATIVE_TLS=%s\n' "${UV_NATIVE_TLS:-}" > "${MOCK_PROXY_ENV}"
command cat "${SSL_CERT_FILE}" >> "${MOCK_PROXY_ENV}"
EOF
chmod +x "${BIN_DIR}/uvx"
SYSTEM_CA_FILE="${SYSTEM_CA_FILE}" NODE_EXTRA_CA_CERTS="${EXTRA_CA_FILE}" MOCK_PROXY_ENV="${PROXY_ENV_FILE}" \
  "${ROOT_DIR}/scripts/start-proxy.sh"
grep -Fx 'UV_NATIVE_TLS=true' "${PROXY_ENV_FILE}" >/dev/null || fail "uv native TLS was not enabled"
grep -Fx 'public-ca' "${PROXY_ENV_FILE}" >/dev/null || fail "system CA was not passed to LiteLLM"
grep -Fx 'vpn-ca' "${PROXY_ENV_FILE}" >/dev/null || fail "additional CA was not passed to LiteLLM"

printf 'Test: missing cost HUD configuration skips Azure preflight\n'
NO_COST_ENV_FILE="${TEST_DIR}/no-cost.env"
grep -v '^CLAUDE_AZURE_' "${ENV_FILE}" > "${NO_COST_ENV_FILE}"
: > "${AZ_RUNS_FILE}"
: > "${CLAUDE_RUNS_FILE}"
CLAUDE_AZURE_ENV_FILE="${NO_COST_ENV_FILE}" "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" no-cost-config
[[ ! -s "${AZ_RUNS_FILE}" ]] || fail "Azure preflight ran without tenant/subscription configuration"
grep -F '|no-cost-config' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run without cost HUD configuration"

printf 'Test: authenticated Azure CLI skips login and refreshes cost\n'
: > "${AZ_RUNS_FILE}"
: > "${COST_REFRESHES_FILE}"
"${ROOT_DIR}/scripts/claude-via-azure-openai.sh" authenticated
! grep -Fx 'login' "${AZ_RUNS_FILE}" >/dev/null || fail "az login ran with a valid session"
grep -Fx 'rest --method get --url https://management.azure.com/subscriptions/3c7b1819-c657-41ca-a22e-b6dc6d34fd98?api-version=2022-12-01' "${AZ_RUNS_FILE}" >/dev/null || fail "expected subscription access was not validated"
! grep -F 'account set' "${AZ_RUNS_FILE}" >/dev/null || fail "launcher changed the global Azure subscription"
wait_for_file "${COST_REFRESHES_FILE}"
grep -Fx -- '--refresh' "${COST_REFRESHES_FILE}" >/dev/null || fail "cost refresh was not triggered"

printf 'Test: detached cost refresh does not block Claude\n'
detached_refreshes="${TEST_DIR}/detached-refreshes"
detached_done="${TEST_DIR}/detached-done"
: > "${CLAUDE_RUNS_FILE}"
start_time="$(date +%s)"
MOCK_COST_REFRESHES="${detached_refreshes}" MOCK_COST_REFRESH_DONE="${detached_done}" MOCK_COST_REFRESH_SLEEP=5 \
  "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" detached-refresh
elapsed=$(( $(date +%s) - start_time ))
(( elapsed < 5 )) || fail "cost refresh blocked Claude for ${elapsed}s"
grep -F '|detached-refresh' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run while cost refresh was pending"
[[ ! -e "${detached_done}" ]] || fail "launcher waited for detached cost refresh to finish"

printf 'Test: expired Azure CLI session logs in before selecting subscription\n'
: > "${AZ_RUNS_FILE}"
MOCK_AZ_LOGIN_MARKER="${TEST_DIR}/login-marker" MOCK_AZ_ACCESS_TOKEN_EXIT=1 \
  "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" login-required
grep -Fx 'login --tenant ktopen.onmicrosoft.com' "${AZ_RUNS_FILE}" >/dev/null || fail "tenant-scoped az login did not run for an expired session"
expected_login_sequence=$'account get-access-token\nlogin --tenant ktopen.onmicrosoft.com\nrest --method get --url https://management.azure.com/subscriptions/3c7b1819-c657-41ca-a22e-b6dc6d34fd98?api-version=2022-12-01'
[[ "$(command cat "${AZ_RUNS_FILE}")" == "${expected_login_sequence}" ]] || fail "unexpected Azure login sequence"

printf 'Test: tenant login keeps terminal input attached\n'
login_stdin_file="${TEST_DIR}/login-stdin-read"
: > "${CLAUDE_RUNS_FILE}"
MOCK_AZ_LOGIN_STDIN="${login_stdin_file}" MOCK_AZ_ACCESS_TOKEN_EXIT=1 MOCK_AZ_LOGIN_EXIT=1 \
  "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" login-stdin
grep -Fx 'tenant-login-input' "${login_stdin_file}" >/dev/null || fail "az login could not read terminal input"
grep -F '|login-stdin' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run after canceled Azure login"

printf 'Test: canceling optional Azure login still launches Claude\n'
: > "${CLAUDE_RUNS_FILE}"
MOCK_AZ_ACCESS_TOKEN_EXIT=1 MOCK_AZ_LOGIN_SLEEP=5 "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" login-canceled >"${TEST_DIR}/login-canceled.log" 2>&1 &
launcher_pid=$!
sleep 0.2
kill -TERM "${launcher_pid}"
wait "${launcher_pid}"
grep -F '|login-canceled' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run after optional Azure login was canceled"

printf 'Test: hanging Azure auth check does not block Claude\n'
: > "${CLAUDE_RUNS_FILE}"
start_time="$(date +%s)"
CLAUDE_AZURE_PREFLIGHT_TIMEOUT=1 MOCK_AZ_ACCESS_TOKEN_SLEEP=5 "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" auth-timeout
elapsed=$(( $(date +%s) - start_time ))
(( elapsed < 5 )) || fail "Azure auth check blocked Claude for ${elapsed}s"
grep -F '|auth-timeout' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run after Azure auth timeout"

printf 'Test: missing Azure CLI does not block Claude\n'
: > "${CLAUDE_RUNS_FILE}"
mv "${BIN_DIR}/az" "${BIN_DIR}/az.disabled"
PATH="${BIN_DIR}:/usr/bin:/bin" "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" az-missing
mv "${BIN_DIR}/az.disabled" "${BIN_DIR}/az"
grep -F '|az-missing' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run without Azure CLI"

printf 'Test: Azure login failure does not block Claude\n'
login_failure_refreshes="${TEST_DIR}/login-failure-refreshes"
: > "${CLAUDE_RUNS_FILE}"
MOCK_COST_REFRESHES="${login_failure_refreshes}" MOCK_AZ_ACCESS_TOKEN_EXIT=1 MOCK_AZ_LOGIN_EXIT=1 \
  "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" login-failed
grep -F '|login-failed' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run after Azure login failure"
[[ ! -e "${login_failure_refreshes}" ]] || fail "cost refresh ran after Azure login failure"

printf 'Test: Azure subscription failure does not block Claude\n'
subscription_failure_refreshes="${TEST_DIR}/subscription-failure-refreshes"
: > "${CLAUDE_RUNS_FILE}"
MOCK_COST_REFRESHES="${subscription_failure_refreshes}" MOCK_AZ_SUBSCRIPTION_ACCESS_EXIT=1 \
  "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" subscription-failed
grep -F '|subscription-failed' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run after Azure subscription failure"
[[ ! -e "${subscription_failure_refreshes}" ]] || fail "cost refresh ran after Azure subscription failure"

printf 'Test: cost refresh failure does not block Claude\n'
: > "${CLAUDE_RUNS_FILE}"
: > "${COST_REFRESHES_FILE}"
MOCK_COST_REFRESH_EXIT=1 "${ROOT_DIR}/scripts/claude-via-azure-openai.sh" refresh-failed
wait_for_file "${COST_REFRESHES_FILE}"
grep -F '|refresh-failed' "${CLAUDE_RUNS_FILE}" >/dev/null || fail "Claude did not run after cost refresh failure"

printf 'Test: automatic start, cwd preservation, exit code, and automatic stop\n'
: > "${STARTS_FILE}"
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
(( "$(wc -l < "${STARTS_FILE}")" == 1 )) || fail "expected one proxy start"
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
(( "$(wc -l < "${STARTS_FILE}")" == 1 )) || fail "concurrent sessions started more than one proxy"
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
export LITELLM_HOST=127.0.0.1
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
