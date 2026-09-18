#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${CLAUDE_AZURE_ENV_FILE:-${ROOT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'Missing %s\n' "${ENV_FILE}" >&2
  printf 'Create it first:\n  cp %s/.env.example %s\n' "${ROOT_DIR}" "${ENV_FILE}" >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

required_vars=(
  AZURE_API_KEY
  AZURE_API_BASE
  AZURE_API_VERSION
  AZURE_DEPLOYMENT_OPUS
  AZURE_DEPLOYMENT_FABLE
  AZURE_DEPLOYMENT_HAIKU
  LITELLM_MASTER_KEY
)

missing=()
for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" || "${!var_name}" == your-* || "${!var_name}" == *your-* ]]; then
    missing+=("${var_name}")
  fi
done

if (( ${#missing[@]} > 0 )); then
  printf 'Fill these values in %s:\n' "${ENV_FILE}" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

if [[ "${AZURE_API_VERSION}" < "2025-03-01-preview" ]]; then
  printf 'AZURE_API_VERSION must be 2025-03-01-preview or later for Azure OpenAI Responses API.\n' >&2
  printf 'Current value: %s\n' "${AZURE_API_VERSION}" >&2
  exit 1
fi

export ROOT_DIR
export LITELLM_HOST="${LITELLM_HOST:-127.0.0.1}"
export LITELLM_PORT="${LITELLM_PORT:-4000}"
export CLAUDE_CODE_OPUS_ALIAS="${CLAUDE_CODE_OPUS_ALIAS:-opus}"
export CLAUDE_CODE_FABLE_ALIAS="${CLAUDE_CODE_FABLE_ALIAS:-fable}"
export CLAUDE_CODE_HAIKU_ALIAS="${CLAUDE_CODE_HAIKU_ALIAS:-haiku}"
