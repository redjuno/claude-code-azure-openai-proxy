#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${ROOT_DIR}/scripts/claude-via-azure-openai.sh"
SHELL_RC="${CLAUDE_AZURE_SHELL_RC:-${HOME}/.zshrc}"
ALIAS_NAME="${CLAUDE_AZURE_ALIAS_NAME:-claude-azure}"
MARKER_BEGIN="# >>> claude-code-azure-openai-proxy >>>"
MARKER_END="# <<< claude-code-azure-openai-proxy <<<"
BIN_DIR="${CLAUDE_AZURE_BIN_DIR:-${HOME}/.local/bin}"
SHIM="${BIN_DIR}/${ALIAS_NAME}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
STATUSLINE="${ROOT_DIR}/scripts/azure-cost-statusline.py"
AZURE_SETTINGS="${CLAUDE_DIR}/azure-settings.json"
COST_CONFIG="${CLAUDE_DIR}/azure-cost.json"

if [[ ! -f "${LAUNCHER}" ]]; then
  printf 'Launcher not found: %s\n' "${LAUNCHER}" >&2
  exit 1
fi

mkdir -p "${CLAUDE_DIR}"


# The cost config names a real subscription and resource, so it is never
# committed and never overwritten once it exists.
if [[ ! -f "${COST_CONFIG}" ]]; then
  cp "${ROOT_DIR}/config/azure-cost.example.json" "${COST_CONFIG}"
  cost_config_created=1
else
  cost_config_created=0
fi

# Generated before the alias, because whether it succeeds decides whether the
# alias carries --settings at all. It needs python3 and a writable config dir,
# and neither failure may cost the user the launcher they asked for.
# statusLine has to name an absolute path, so the tracked template carries a
# placeholder and the real file is generated here. The substitution runs through
# python rather than sed: the path lands inside a JSON string that the shell then
# executes, so it needs JSON escaping and shell quoting, and sed would also choke
# on a path containing its delimiter or an unescaped "&".
if ! python3 - "${ROOT_DIR}/config/azure-settings.json" "${STATUSLINE}" "${AZURE_SETTINGS}" <<'PYTHON'
import json
import pathlib
import shlex
import sys

template, statusline, destination = sys.argv[1:4]
template_settings = json.loads(pathlib.Path(template).read_text())
command = template_settings["statusLine"]["command"].replace(
    "__AZURE_COST_STATUSLINE__", shlex.quote(statusline)
)

# Only statusLine is ours. Anything else the user added to this file — hooks,
# permissions, env — survives re-running the installer after moving the repo.
target = pathlib.Path(destination)
try:
    settings = json.loads(target.read_text())
except (OSError, ValueError):
    settings = {}
if not isinstance(settings, dict):
    settings = {}
settings["statusLine"] = {"type": "command", "command": command}
target.write_text(json.dumps(settings, indent=2) + "\n")
PYTHON
then
  printf 'Warning: could not write %s; the cost HUD statusline was not installed.\n' "${AZURE_SETTINGS}" >&2
  AZURE_SETTINGS=""
fi

mkdir -p "$(dirname "${SHELL_RC}")"
touch "${SHELL_RC}"

tmp_file="$(mktemp)"
awk -v begin="${MARKER_BEGIN}" -v end="${MARKER_END}" '
  $0 == begin { skip = 1; next }
  $0 == end { skip = 0; next }
  skip != 1 { print }
' "${SHELL_RC}" > "${tmp_file}"

{
  cat "${tmp_file}"
  printf '\n%s\n' "${MARKER_BEGIN}"
  # The alias value is re-parsed by the shell when the alias expands, so the
  # escaping has to survive twice: once for each path, once for the whole value.
  if [[ -n "${AZURE_SETTINGS}" ]]; then
    printf 'alias %s=%q\n' "${ALIAS_NAME}" "$(printf '%q --settings %q' "${LAUNCHER}" "${AZURE_SETTINGS}")"
  else
    printf 'alias %s=%q\n' "${ALIAS_NAME}" "${LAUNCHER}"
  fi
  printf '%s\n' "${MARKER_END}"
} > "${SHELL_RC}"

rm -f "${tmp_file}"

mkdir -p "${BIN_DIR}"
{
  printf '#!/usr/bin/env bash\n'
  if [[ -n "${AZURE_SETTINGS}" ]]; then
    printf 'exec %q --settings %q "$@"\n' "${LAUNCHER}" "${AZURE_SETTINGS}"
  else
    printf 'exec %q "$@"\n' "${LAUNCHER}"
  fi
} > "${SHIM}"
chmod +x "${SHIM}"


printf 'Installed alias:\n'
printf '  %s -> %s\n' "${ALIAS_NAME}" "${LAUNCHER}"
if [[ -n "${AZURE_SETTINGS}" ]]; then
  printf '\nInstalled cost HUD statusline:\n'
  printf '  %s -> %s\n' "${AZURE_SETTINGS}" "${STATUSLINE}"
fi
if (( cost_config_created == 1 )); then
  printf '\nFill in the Azure account the HUD reports on:\n'
  printf '  %s\n' "${COST_CONFIG}"
fi
printf '\nInstalled command shim:\n'
printf '  %s\n' "${SHIM}"
printf '\nApply it in the current terminal:\n'
printf '  source %s\n' "${SHELL_RC}"
printf '\nThen run from any project directory:\n'
printf '  %s\n' "${ALIAS_NAME}"
