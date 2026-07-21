#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure-env.sh"

BASE_URL="http://${LITELLM_HOST}:${LITELLM_PORT}"

printf 'Testing Anthropic-compatible endpoint: %s/v1/messages\n' "${BASE_URL}"

curl -sS "${BASE_URL}/v1/messages" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "x-api-key: ${LITELLM_MASTER_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "'"${CLAUDE_CODE_OPUS_ALIAS}"'",
    "max_tokens": 64,
    "messages": [
      {
        "role": "user",
        "content": "Reply with one short sentence confirming the proxy works."
      }
    ]
  }'

printf '\n'

