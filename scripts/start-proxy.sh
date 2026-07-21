#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure-env.sh"

cd "${ROOT_DIR}"

GENERATED_DIR="${ROOT_DIR}/.generated"
GENERATED_CONFIG="${GENERATED_DIR}/litellm.config.yaml"
mkdir -p "${GENERATED_DIR}"

sed \
  -e "s#__AZURE_DEPLOYMENT_OPUS__#${AZURE_DEPLOYMENT_OPUS}#g" \
  -e "s#__AZURE_DEPLOYMENT_SONNET__#${AZURE_DEPLOYMENT_SONNET}#g" \
  -e "s#__AZURE_DEPLOYMENT_HAIKU__#${AZURE_DEPLOYMENT_HAIKU}#g" \
  -e "s#__CLAUDE_CODE_OPUS_ALIAS__#${CLAUDE_CODE_OPUS_ALIAS}#g" \
  -e "s#__CLAUDE_CODE_SONNET_ALIAS__#${CLAUDE_CODE_SONNET_ALIAS}#g" \
  -e "s#__CLAUDE_CODE_HAIKU_ALIAS__#${CLAUDE_CODE_HAIKU_ALIAS}#g" \
  "${ROOT_DIR}/config/litellm.config.yaml" > "${GENERATED_CONFIG}"

printf 'Starting LiteLLM proxy on http://%s:%s\n' "${LITELLM_HOST}" "${LITELLM_PORT}"
printf 'Exposing model aliases:\n'
printf '  %s -> azure/%s (opus)\n' "${CLAUDE_CODE_OPUS_ALIAS}" "${AZURE_DEPLOYMENT_OPUS}"
printf '  %s -> azure/%s (sonnet)\n' "${CLAUDE_CODE_SONNET_ALIAS}" "${AZURE_DEPLOYMENT_SONNET}"
printf '  %s -> azure/%s (haiku)\n' "${CLAUDE_CODE_HAIKU_ALIAS}" "${AZURE_DEPLOYMENT_HAIKU}"
printf 'Azure API version: %s\n' "${AZURE_API_VERSION}"

exec uvx \
  --from 'litellm[proxy]!=1.82.7,!=1.82.8' \
  litellm \
  --config "${GENERATED_CONFIG}" \
  --host "${LITELLM_HOST}" \
  --port "${LITELLM_PORT}"
