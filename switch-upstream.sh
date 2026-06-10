#!/bin/zsh
set -euo pipefail

LABEL="dev.codex-imagegen-guard.agent"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
INSTALL_ROOT="$CODEX_HOME/imagegen-guard"
CONFIG_ENV="$INSTALL_ROOT/config.env"
CONFIG_FILE="$CODEX_HOME/config.toml"

DEFAULT_UPSTREAMS="https://api.hanhegufei.online/v1,https://ai.ailinyu.de/v1,https://token.fourj.space/v1"
DEFAULT_ALIASES="hanhe=https://api.hanhegufei.online/v1,ailinyu=https://ai.ailinyu.de/v1,fourj=https://token.fourj.space/v1"

usage() {
  cat <<'EOF_USAGE'
Usage:
  switch-upstream.sh status
  switch-upstream.sh hanhe
  switch-upstream.sh ailinyu
  switch-upstream.sh fourj
  switch-upstream.sh custom https://example.com[/v1]
EOF_USAGE
}

read_env_key() {
  python3 - "$1" "$2" <<'PY'
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]
if not path.exists():
    raise SystemExit(1)

for line in path.read_text().splitlines():
    if line.startswith(f"{target}="):
        try:
            parsed = shlex.split(line.split("=", 1)[1], posix=True)
            print(parsed[0] if parsed else "")
        except ValueError:
            print(line.split("=", 1)[1].strip("'\""))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

normalize_base_url() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse

raw = sys.argv[1].strip().rstrip("/")
if not raw:
    raise SystemExit(1)
parsed = urllib.parse.urlparse(raw)
if not parsed.scheme or not parsed.netloc:
    raise SystemExit(f"invalid URL: {raw}")
host = parsed.hostname or ""
if host == "localhost":
    host = "127.0.0.1"
port = f":{parsed.port}" if parsed.port else ""
path = (parsed.path or "").rstrip("/")
if not path:
    path = "/v1"
elif path != "/v1" and not path.endswith("/v1"):
    path = f"{path}/v1"
print(urllib.parse.urlunparse((parsed.scheme, f"{host}{port}", path, "", "", "")))
PY
}

unique_list() {
  python3 - "$@" <<'PY'
import sys
import urllib.parse

def normalize(raw: str) -> str:
    parsed = urllib.parse.urlparse(raw.strip().rstrip("/"))
    host = parsed.hostname or ""
    if host == "localhost":
        host = "127.0.0.1"
    port = f":{parsed.port}" if parsed.port else ""
    path = (parsed.path or "").rstrip("/")
    return urllib.parse.urlunparse((parsed.scheme, f"{host}{port}", path, "", "", ""))

items = []
seen = set()
for value in sys.argv[1:]:
    for part in value.split(","):
        item = part.strip().rstrip("/")
        if not item:
            continue
        key = normalize(item)
        if key in seen:
            continue
        seen.add(key)
        items.append(item)
print(",".join(items))
PY
}

read_codex_base_url() {
  python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
text = path.read_text()
provider = "Codex"
for line in text.splitlines():
    match = re.match(r'\s*model_provider\s*=\s*"([^"]+)"', line)
    if match:
        provider = match.group(1)
        break

in_provider = False
provider_header = f"[model_providers.{provider}]"
for line in text.splitlines():
    stripped = line.strip()
    if stripped == provider_header:
        in_provider = True
        continue
    if in_provider and stripped.startswith("[") and stripped.endswith("]"):
        break
    if in_provider:
        match = re.match(r'base_url\s*=\s*"([^"]+)"', stripped)
        if match:
            print(match.group(1))
            raise SystemExit(0)
raise SystemExit(1)
PY
}

write_env() {
  local active="$1"
  local bases="$2"
  local alias_map="$3"
  python3 - "$CONFIG_ENV" "$active" "$bases" "$alias_map" <<'PY'
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
updates = {
    "UPSTREAM_BASE": sys.argv[2],
    "UPSTREAM_BASES": sys.argv[3],
    "UPSTREAM_ALIASES": sys.argv[4],
}
path.parent.mkdir(parents=True, exist_ok=True)
lines = path.read_text().splitlines() if path.exists() else []
out = []
seen = set()
for line in lines:
    key = line.split("=", 1)[0] if "=" in line else ""
    if key in updates:
        out.append(f"{key}={shlex.quote(updates[key])}")
        seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={shlex.quote(value)}")
path.write_text("\n".join(out) + "\n")
path.chmod(0o600)
PY
}

restart_agent() {
  if command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
  fi
}

status() {
  local listen_port active bases alias_map current_base guard_base chain_status
  listen_port="$(read_env_key "$CONFIG_ENV" LISTEN_PORT 2>/dev/null || echo 11435)"
  active="$(read_env_key "$CONFIG_ENV" UPSTREAM_BASE 2>/dev/null || true)"
  bases="$(read_env_key "$CONFIG_ENV" UPSTREAM_BASES 2>/dev/null || echo "$DEFAULT_UPSTREAMS")"
  alias_map="$(read_env_key "$CONFIG_ENV" UPSTREAM_ALIASES 2>/dev/null || echo "$DEFAULT_ALIASES")"
  current_base="$(read_codex_base_url "$CONFIG_FILE" 2>/dev/null || true)"
  guard_base="http://127.0.0.1:$listen_port/v1"
  if [[ "$(normalize_base_url "$current_base" 2>/dev/null || true)" == "$(normalize_base_url "$guard_base")" ]]; then
    chain_status="ok"
  elif [[ "$current_base" == http://127.0.0.1:* || "$current_base" == http://localhost:* ]]; then
    chain_status="bypassed-local"
  else
    chain_status="bypassed-remote"
  fi

  echo "status=$chain_status"
  echo "active_upstream=$active"
  echo "known_upstreams=$bases"
  echo "upstream_aliases=$alias_map"
  echo "codex_base_url=$current_base"
  echo "guard_base_url=$guard_base"
  if [[ "$chain_status" != "ok" ]]; then
    echo "hint=run $INSTALL_ROOT/repair.sh to route Codex through the guard"
  fi
}

resolve_alias() {
  local name="$1"
  local alias_map
  alias_map="$(read_env_key "$CONFIG_ENV" UPSTREAM_ALIASES 2>/dev/null || echo "$DEFAULT_ALIASES")"
  python3 - "$name" "$alias_map" <<'PY'
import sys
target = sys.argv[1]
for item in sys.argv[2].split(","):
    if "=" not in item:
        continue
    key, value = item.split("=", 1)
    if key == target:
        print(value)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

[[ $# -ge 1 ]] || {
  usage >&2
  exit 2
}

case "$1" in
  status)
    status
    ;;
  custom)
    [[ $# -eq 2 ]] || {
      usage >&2
      exit 2
    }
    target="$(normalize_base_url "$2")"
    bases="$(unique_list "$target" "$(read_env_key "$CONFIG_ENV" UPSTREAM_BASES 2>/dev/null || echo "$DEFAULT_UPSTREAMS")")"
    alias_map="$(read_env_key "$CONFIG_ENV" UPSTREAM_ALIASES 2>/dev/null || echo "$DEFAULT_ALIASES")"
    write_env "$target" "$bases" "$alias_map"
    restart_agent
    echo "active_upstream=$target"
    ;;
  *)
    target="$(resolve_alias "$1" 2>/dev/null || true)"
    [[ -n "$target" ]] || {
      echo "ERROR: unknown upstream alias: $1" >&2
      usage >&2
      exit 2
    }
    target="$(normalize_base_url "$target")"
    bases="$(unique_list "$target" "$(read_env_key "$CONFIG_ENV" UPSTREAM_BASES 2>/dev/null || echo "$DEFAULT_UPSTREAMS")")"
    alias_map="$(read_env_key "$CONFIG_ENV" UPSTREAM_ALIASES 2>/dev/null || echo "$DEFAULT_ALIASES")"
    write_env "$target" "$bases" "$alias_map"
    restart_agent
    echo "active_upstream=$target"
    ;;
esac
