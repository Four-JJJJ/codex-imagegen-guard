#!/bin/zsh
set -euo pipefail

LABEL="dev.codex-imagegen-guard.agent"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
INSTALL_ROOT="$CODEX_HOME/imagegen-guard"
OLD_INSTALL_ROOT="$CODEX_HOME/local-proxy"
BACKUP_DIR="$CODEX_HOME/backups/imagegen-guard"
OLD_BACKUP_DIR="$CODEX_HOME/backups/local-proxy"
CONFIG_FILE="$CODEX_HOME/config.toml"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENT_DIR/$LABEL.plist"
DEFAULT_PORT=11435
MAX_PORT=11445
DEFAULT_CCSWITCH_URL="http://127.0.0.1:15721/v1"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "this installer only supports macOS"
fi

need_cmd python3
need_cmd launchctl
need_cmd plutil
need_cmd lsof

[[ -f "$CONFIG_FILE" ]] || fail "Codex config not found: $CONFIG_FILE"

mkdir -p "$INSTALL_ROOT/logs" "$BACKUP_DIR" "$LAUNCH_AGENT_DIR"

stop_existing_agents() {
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
  pkill -f "$INSTALL_ROOT/codex_imagegen_guard.py" 2>/dev/null || true
  pkill -f "$OLD_INSTALL_ROOT/codex_request_sanitizer.py" 2>/dev/null || true
  pkill -f "$OLD_INSTALL_ROOT/codex_proxy_supervisor.py" 2>/dev/null || true
}

merge_no_proxy() {
  python3 - "$@" <<'PY'
import sys

items: list[str] = []
seen: set[str] = set()
for value in sys.argv[1:]:
    for part in value.split(","):
        item = part.strip()
        key = item.lower()
        if item and key not in seen:
            seen.add(key)
            items.append(item)
print(",".join(items))
PY
}

read_codex_base_url() {
  python3 - "$1" "$2" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider = sys.argv[2]
text = path.read_text()
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
    if not line.startswith(f"{target}="):
        continue
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
parsed = urllib.parse.urlparse(raw)
host = parsed.hostname or ""
if host == "localhost":
    host = "127.0.0.1"
port = f":{parsed.port}" if parsed.port else ""
path = (parsed.path or "").rstrip("/")
print(urllib.parse.urlunparse((parsed.scheme, f"{host}{port}", path, "", "", "")))
PY
}

url_port() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse

parsed = urllib.parse.urlparse(sys.argv[1].strip())
print(parsed.port or "")
PY
}

read_active_provider() {
  python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
for line in text.splitlines():
    match = re.match(r'\s*model_provider\s*=\s*"([^"]+)"', line)
    if match:
        print(match.group(1))
        raise SystemExit(0)
print("Codex")
PY
}

provider_name="${CODEX_SANITIZER_PROVIDER:-$(read_active_provider "$CONFIG_FILE")}"
[[ -n "$provider_name" ]] || fail "could not determine active Codex provider"
ccswitch_base="${CODEX_SANITIZER_CCSWITCH_URL:-$DEFAULT_CCSWITCH_URL}"
ccswitch_base="${ccswitch_base%/}"
normalized_ccswitch_base="$(normalize_base_url "$ccswitch_base")"
ccswitch_port="$(url_port "$ccswitch_base")"

launch_no_proxy="$(launchctl getenv NO_PROXY 2>/dev/null || true)"
no_proxy_value="${CODEX_SANITIZER_NO_PROXY:-$(merge_no_proxy "127.0.0.1,localhost,::1" "${NO_PROXY:-}" "${no_proxy:-}" "$launch_no_proxy")}"
upstream_proxy_mode="${CODEX_SANITIZER_UPSTREAM_PROXY_MODE:-system}"
case "$upstream_proxy_mode" in
  system|direct) ;;
  *) fail "CODEX_SANITIZER_UPSTREAM_PROXY_MODE must be system or direct" ;;
esac

current_base="$(read_codex_base_url "$CONFIG_FILE" "$provider_name" || true)"
[[ -n "$current_base" ]] || fail "could not find [model_providers.$provider_name] base_url in $CONFIG_FILE"

is_local_base() {
  [[ "$1" == http://127.0.0.1:* || "$1" == http://localhost:* ]]
}

is_ccswitch_base() {
  [[ "$(normalize_base_url "$1")" == "$normalized_ccswitch_base" ]]
}

is_guard_base() {
  local base="$1"
  local normalized_base
  normalized_base="$(normalize_base_url "$base")"
  local listen
  listen="$(read_env_key "$INSTALL_ROOT/config.env" LISTEN_PORT 2>/dev/null || true)"
  if [[ -n "$listen" ]] && [[ "$normalized_base" == "$(normalize_base_url "http://127.0.0.1:$listen/v1")" ]]; then
    return 0
  fi
  return 1
}

read_upstream_from_env() {
  read_env_key "$1" UPSTREAM_BASE
}

append_unique_upstream() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return 0
  if [[ "$candidate" == *,* ]]; then
    local part
    for part in ${(s:,:)candidate}; do
      append_unique_upstream "$part"
    done
    return
  fi
  local normalized_candidate
  normalized_candidate="$(normalize_base_url "$candidate")"
  local existing
  for existing in "${upstream_bases[@]}"; do
    [[ "$(normalize_base_url "$existing")" == "$normalized_candidate" ]] && return
  done
  upstream_bases+=("$candidate")
}

read_existing_upstream() {
  local saved_upstream
  saved_upstream="$(read_upstream_from_env "$INSTALL_ROOT/config.env" 2>/dev/null || true)"
  if [[ -n "$saved_upstream" ]] && ! is_guard_base "$saved_upstream"; then
    printf '%s\n' "$saved_upstream"
    return
  fi

  local old_saved_upstream
  old_saved_upstream="$(read_upstream_from_env "$OLD_INSTALL_ROOT/config.env" 2>/dev/null || true)"
  if [[ -n "$old_saved_upstream" ]] && ! is_guard_base "$old_saved_upstream"; then
    printf '%s\n' "$old_saved_upstream"
    return
  fi

  local latest_backup
  latest_backup="$(ls -t "$BACKUP_DIR"/config.toml.backup-* 2>/dev/null | head -1 || true)"
  if [[ -n "$latest_backup" ]]; then
    local backup_base
    backup_base="$(read_codex_base_url "$latest_backup" "$provider_name" || true)"
    if [[ -n "$backup_base" ]] && ! is_guard_base "$backup_base"; then
      printf '%s\n' "$backup_base"
      return
    fi
  fi

  local old_latest_backup
  old_latest_backup="$(ls -t "$OLD_BACKUP_DIR"/config.toml.backup-* 2>/dev/null | head -1 || true)"
  if [[ -n "$old_latest_backup" ]]; then
    local old_backup_base
    old_backup_base="$(read_codex_base_url "$old_latest_backup" "$provider_name" || true)"
    if [[ -n "$old_backup_base" ]] && ! is_guard_base "$old_backup_base"; then
      printf '%s\n' "$old_backup_base"
      return
    fi
  fi

  return 1
}

if [[ -n "${CODEX_SANITIZER_UPSTREAM:-}" ]]; then
  upstream_base="$CODEX_SANITIZER_UPSTREAM"
elif is_ccswitch_base "$current_base"; then
  upstream_base="$ccswitch_base"
elif is_guard_base "$current_base"; then
  upstream_base="$(read_existing_upstream || true)"
  [[ -n "${upstream_base:-}" ]] || fail "Codex already points to this guard, but no saved upstream was found. Restore config.toml or set CODEX_SANITIZER_UPSTREAM."
elif is_local_base "$current_base"; then
  upstream_base="$current_base"
else
  upstream_base="$current_base"
fi

upstream_bases=()
append_unique_upstream "$upstream_base"
append_unique_upstream "${CODEX_SANITIZER_UPSTREAM_FALLBACK:-}"
append_unique_upstream "https://api.hanhegufei.online/v1"
append_unique_upstream "https://ai.ailinyu.de/v1"
append_unique_upstream "https://token.fourj.space/v1"
upstream_bases_value="$(IFS=,; printf '%s' "${upstream_bases[*]}")"
upstream_aliases_value="hanhe=https://api.hanhegufei.online/v1,ailinyu=https://ai.ailinyu.de/v1,fourj=https://token.fourj.space/v1"
upstream_port="$(url_port "$upstream_base")"

stop_existing_agents

choose_port() {
  local existing_port
  existing_port="$(read_env_key "$INSTALL_ROOT/config.env" LISTEN_PORT 2>/dev/null || true)"
  if [[ -n "$existing_port" ]] && [[ "$existing_port" != "$ccswitch_port" ]] && [[ "$existing_port" != "$upstream_port" ]] && ! lsof -nP -iTCP:"$existing_port" -sTCP:LISTEN >/dev/null 2>&1; then
    printf '%s\n' "$existing_port"
    return
  fi

  local port
  for port in $(seq "$DEFAULT_PORT" "$MAX_PORT"); do
    [[ "$port" == "$ccswitch_port" ]] && continue
    [[ "$port" == "$upstream_port" ]] && continue
    if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s\n' "$port"
      return
    fi
  done
  return 1
}

listen_port="$(choose_port || true)"
[[ -n "$listen_port" ]] || fail "no free local port found in $DEFAULT_PORT-$MAX_PORT"

cp -p "$CONFIG_FILE" "$BACKUP_DIR/config.toml.backup-$STAMP"
if is_local_base "$current_base"; then
  python3 - "$BACKUP_DIR/config.toml.backup-$STAMP" "$provider_name" "$upstream_base" <<'PY_RESTORE_BACKUP'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider = sys.argv[2]
upstream = sys.argv[3]
lines = path.read_text().splitlines()
provider_header = f"[model_providers.{provider}]"
out: list[str] = []
in_provider = False
changed = False

for line in lines:
    stripped = line.strip()
    if stripped == provider_header:
        in_provider = True
        out.append(line)
        continue
    if in_provider and stripped.startswith("[") and stripped.endswith("]"):
        in_provider = False
    if in_provider and re.match(r'\s*base_url\s*=', line):
        prefix = line[: len(line) - len(line.lstrip())]
        out.append(f'{prefix}base_url = "{upstream}"')
        changed = True
    else:
        out.append(line)

if not changed:
    raise SystemExit(f"failed to write restore backup for [model_providers.{provider}]")
path.write_text("\n".join(out) + "\n")
PY_RESTORE_BACKUP
fi

cat > "$INSTALL_ROOT/config.env" <<EOF_CONFIG
UPSTREAM_BASE=$(printf '%q' "$upstream_base")
UPSTREAM_BASES=$(printf '%q' "$upstream_bases_value")
UPSTREAM_ALIASES=$(printf '%q' "$upstream_aliases_value")
LISTEN_HOST=127.0.0.1
LISTEN_PORT=$listen_port
NO_PROXY=$(printf '%q' "$no_proxy_value")
UPSTREAM_PROXY_MODE=$upstream_proxy_mode
CCSWITCH_URL=$(printf '%q' "$ccswitch_base")
EOF_CONFIG
chmod 600 "$INSTALL_ROOT/config.env"

cat > "$INSTALL_ROOT/codex_imagegen_guard.py" <<'PY_PROXY'
#!/usr/bin/env python3
import json
import logging
import os
import re
import shlex
import socket
import ssl
import sys
import threading
import http.client
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path.home() / ".codex" / "imagegen-guard"
CONFIG_PATH = ROOT / "config.env"


def load_config() -> dict[str, str]:
    config: dict[str, str] = {}
    if CONFIG_PATH.exists():
        for line in CONFIG_PATH.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            try:
                parsed = shlex.split(value, posix=True)
                config[key] = parsed[0] if parsed else ""
            except ValueError:
                config[key] = value.strip("'\"")
    return config


CONFIG = load_config()
LISTEN_HOST = os.environ.get("CODEX_SANITIZER_HOST", CONFIG.get("LISTEN_HOST", "127.0.0.1"))
LISTEN_PORT = int(os.environ.get("CODEX_SANITIZER_PORT", CONFIG.get("LISTEN_PORT", "11435")))
UPSTREAM_BASE = os.environ.get("CODEX_SANITIZER_UPSTREAM", CONFIG.get("UPSTREAM_BASE", "")).rstrip("/")
UPSTREAM_LOCK = threading.Lock()
LOG_PATH = os.path.expanduser(os.environ.get("CODEX_SANITIZER_LOG", "~/.codex/imagegen-guard/logs/proxy.log"))
NO_PROXY_VALUE = CONFIG.get("NO_PROXY", "127.0.0.1,localhost,::1")
os.environ["NO_PROXY"] = NO_PROXY_VALUE
os.environ["no_proxy"] = NO_PROXY_VALUE
UPSTREAM_PROXY_MODE = os.environ.get("CODEX_SANITIZER_UPSTREAM_PROXY_MODE", CONFIG.get("UPSTREAM_PROXY_MODE", "system"))
URL_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({})) if UPSTREAM_PROXY_MODE == "direct" else urllib.request.build_opener()
STREAM_CHUNK_SIZE = int(os.environ.get("CODEX_SANITIZER_STREAM_CHUNK_SIZE", CONFIG.get("STREAM_CHUNK_SIZE", "8192")))
UPSTREAM_RETRY_STATUSES = {int(item.strip()) for item in os.environ.get("CODEX_SANITIZER_RETRY_STATUSES", CONFIG.get("RETRY_STATUSES", "401")).split(",") if item.strip()}

IMAGE_TOOL_NAMES = {"image_generation"}
USER_TEXT_KEYS = {"input", "text", "input_text", "content", "message", "prompt"}
USER_ROLE_KEYS = {"user", "human"}
EXPLICIT_IMAGE_PATTERNS = [
    r"\bimage_generation\b",
    r"\bgenerate\s+(an?\s+)?image\b",
    r"\bcreate\s+(an?\s+)?image\b",
    r"\bdraw\s+(an?\s+)?image\b",
    r"\bmake\s+(an?\s+)?picture\b",
    r"生成.{0,8}(图片|图像|图|海报|插画|照片)",
    r"(图片|图像|插画|海报|照片).{0,8}(生成|生图|画|绘制)",
    r"生图",
    r"画一张",
]
NEGATIVE_IMAGE_PATTERNS = [
    r"(不要|不用|不需要|无需|别|禁止).{0,8}(生成.{0,4}(图片|图像|图)|生图|画图|画一张|绘制)",
    r"(不要|不用|不需要|无需|别|禁止).{0,8}(image_generation|generate\s+(an?\s+)?image|create\s+(an?\s+)?image|draw\s+(an?\s+)?image)",
    r"\b(do not|don't|dont|no need to|without)\s+(use\s+)?(image_generation|generate\s+(an?\s+)?image|create\s+(an?\s+)?image|draw\s+(an?\s+)?image)",
    r"\bno\s+image\s+generation\b",
]


def setup_logging() -> None:
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    logging.basicConfig(filename=LOG_PATH, level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def normalize_base_url(raw: str) -> str:
    parsed = urllib.parse.urlparse(raw.strip().rstrip("/"))
    host = parsed.hostname or ""
    if host == "localhost":
        host = "127.0.0.1"
    port = f":{parsed.port}" if parsed.port else ""
    path = (parsed.path or "").rstrip("/")
    return urllib.parse.urlunparse((parsed.scheme, f"{host}{port}", path, "", "", ""))


def split_upstream_bases(value: str) -> list[str]:
    items: list[str] = []
    seen: set[str] = set()
    for part in value.split(","):
        item = part.strip().rstrip("/")
        if not item:
            continue
        key = normalize_base_url(item)
        if key not in seen:
            seen.add(key)
            items.append(item)
    return items


UPSTREAM_BASES = split_upstream_bases(os.environ.get("CODEX_SANITIZER_UPSTREAMS", CONFIG.get("UPSTREAM_BASES", "")))
if UPSTREAM_BASE:
    UPSTREAM_BASES = split_upstream_bases(",".join([UPSTREAM_BASE, *UPSTREAM_BASES]))
UPSTREAM_BASE = UPSTREAM_BASES[0] if UPSTREAM_BASES else UPSTREAM_BASE


def current_upstream_base() -> str:
    with UPSTREAM_LOCK:
        return UPSTREAM_BASE


def ordered_upstream_bases() -> list[str]:
    with UPSTREAM_LOCK:
        current = UPSTREAM_BASE
        bases = list(UPSTREAM_BASES)
    if not current:
        return bases
    return split_upstream_bases(",".join([current, *bases]))


def persist_current_upstream(base_url: str) -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    lines = CONFIG_PATH.read_text().splitlines() if CONFIG_PATH.exists() else []
    out: list[str] = []
    changed = False
    for line in lines:
        if line.startswith("UPSTREAM_BASE="):
            out.append(f"UPSTREAM_BASE={shlex.quote(base_url)}")
            changed = True
        else:
            out.append(line)
    if not changed:
        out.append(f"UPSTREAM_BASE={shlex.quote(base_url)}")
    CONFIG_PATH.write_text("\n".join(out) + "\n")
    CONFIG_PATH.chmod(0o600)


def set_current_upstream(base_url: str) -> None:
    global UPSTREAM_BASE
    with UPSTREAM_LOCK:
        if normalize_base_url(base_url) == normalize_base_url(UPSTREAM_BASE):
            return
        UPSTREAM_BASE = base_url
    persist_current_upstream(base_url)
    logging.info("switched active upstream to %s", base_url)


def collect_text(value: Any, chunks: list[str]) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in USER_TEXT_KEYS:
                if isinstance(child, str):
                    chunks.append(child)
                else:
                    collect_text(child, chunks)
            else:
                collect_text(child, chunks)
    elif isinstance(value, list):
        for child in value:
            collect_text(child, chunks)


def collect_user_text(value: Any, chunks: list[str]) -> None:
    if isinstance(value, dict):
        role = value.get("role")
        if isinstance(role, str) and role.lower() in USER_ROLE_KEYS:
            collect_text(value, chunks)
            return
        for child in value.values():
            collect_user_text(child, chunks)
    elif isinstance(value, list):
        for child in value:
            collect_user_text(child, chunks)


def latest_input_payload(payload: dict[str, Any]) -> Any:
    for key in ("input", "messages"):
        value = payload.get(key)
        if isinstance(value, list) and value:
            return value[-1]
        if isinstance(value, str):
            return value
    return payload


def has_explicit_image_intent(payload: Any) -> bool:
    chunks: list[str] = []
    if isinstance(payload, dict):
        current = latest_input_payload(payload)
        collect_user_text(current, chunks)
        if not chunks:
            collect_text(current, chunks)
    else:
        collect_text(payload, chunks)
    text = "\n".join(chunks).lower()
    if any(re.search(pattern, text, re.IGNORECASE) for pattern in NEGATIVE_IMAGE_PATTERNS):
        return False
    return any(re.search(pattern, text, re.IGNORECASE) for pattern in EXPLICIT_IMAGE_PATTERNS)


def is_image_generation_tool(tool: Any) -> bool:
    if not isinstance(tool, dict):
        return False
    if tool.get("type") in IMAGE_TOOL_NAMES or tool.get("name") in IMAGE_TOOL_NAMES:
        return True
    function = tool.get("function")
    return isinstance(function, dict) and function.get("name") in IMAGE_TOOL_NAMES


def image_tool_choice(value: Any) -> bool:
    if isinstance(value, str):
        return value in IMAGE_TOOL_NAMES
    if isinstance(value, dict):
        if value.get("type") in IMAGE_TOOL_NAMES or value.get("name") in IMAGE_TOOL_NAMES:
            return True
        function = value.get("function")
        return isinstance(function, dict) and function.get("name") in IMAGE_TOOL_NAMES
    return False


def sanitize_payload(payload: Any) -> tuple[Any, bool]:
    if not isinstance(payload, dict) or has_explicit_image_intent(payload):
        return payload, False
    changed = False
    tools = payload.get("tools")
    if isinstance(tools, list):
        filtered = [tool for tool in tools if not is_image_generation_tool(tool)]
        if len(filtered) != len(tools):
            payload = dict(payload)
            changed = True
            if filtered:
                payload["tools"] = filtered
            else:
                payload.pop("tools", None)
    if image_tool_choice(payload.get("tool_choice")):
        payload = dict(payload)
        payload.pop("tool_choice", None)
        changed = True
    return payload, changed


def should_sanitize(path: str) -> bool:
    return path == "/v1/responses" or path.startswith("/v1/responses?")


def build_upstream_url(path: str, upstream_base: str) -> str:
    if upstream_base.endswith("/v1") and (path == "/v1" or path.startswith("/v1/") or path.startswith("/v1?")):
        path = path.removeprefix("/v1") or "/"
    return f"{upstream_base}{path if path.startswith('/') else '/' + path}"


CLIENT_DISCONNECT_ERRORS = (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)
UPSTREAM_STREAM_ERRORS = (
    socket.timeout,
    TimeoutError,
    ssl.SSLEOFError,
    http.client.IncompleteRead,
    http.client.RemoteDisconnected,
)


def is_html_response(content_type: str, sample: bytes = b"") -> bool:
    sample = sample.lstrip().lower()
    return "text/html" in content_type.lower() or sample.startswith(b"<!doctype html") or sample.startswith(b"<html")


def short_error(error: BaseException) -> str:
    return f"{error.__class__.__name__}: {error}"


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self) -> None:
        super().setup()
        self._headers_sent = False

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.info("%s - %s", self.client_address[0], fmt % args)

    def end_headers(self) -> None:
        super().end_headers()
        self._headers_sent = True

    def safe_write(self, data: bytes) -> bool:
        if not data:
            return True
        try:
            self.wfile.write(data)
            self.wfile.flush()
            return True
        except CLIENT_DISCONNECT_ERRORS:
            logging.warning("client disconnected while streaming %s %s", self.command, self.path)
            return False

    def write_chunk(self, data: bytes) -> bool:
        return self.safe_write(f"{len(data):x}\r\n".encode("ascii") + data + b"\r\n")

    def finish_chunked_response(self) -> None:
        self.safe_write(b"0\r\n\r\n")

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, OpenAI-Beta")
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_GET(self) -> None:
        self.forward()

    def do_HEAD(self) -> None:
        self.forward()

    def do_POST(self) -> None:
        self.forward()

    def do_PUT(self) -> None:
        self.forward()

    def do_DELETE(self) -> None:
        self.forward()

    def respond_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.safe_write(body)

    def forward(self) -> None:
        if self.path in {"/healthz", "/v1/healthz"}:
            self.respond_json(200, {"status": "ok", "upstream": current_upstream_base(), "upstreams": ordered_upstream_bases(), "listen": f"{LISTEN_HOST}:{LISTEN_PORT}"})
            return
        upstream_bases = ordered_upstream_bases()
        if not upstream_bases:
            self.respond_json(502, {"error": {"message": "local Codex imagegen guard proxy is not configured: UPSTREAM_BASE is empty"}})
            return

        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
        sanitized = False
        if self.command == "POST" and should_sanitize(self.path) and body and "application/json" in self.headers.get("Content-Type", ""):
            try:
                payload = json.loads(body)
                payload, sanitized = sanitize_payload(payload)
                if sanitized:
                    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            except json.JSONDecodeError:
                logging.warning("invalid JSON on %s; forwarded unchanged", self.path)

        try:
            for index, upstream_base in enumerate(upstream_bases):
                upstream_url = build_upstream_url(self.path, upstream_base)
                headers = self.upstream_headers(len(body), upstream_base)
                request = urllib.request.Request(upstream_url, data=body if self.command not in {"GET", "HEAD"} else None, headers=headers, method=self.command)

                with URL_OPENER.open(request, timeout=900) as response:
                    if normalize_base_url(upstream_base) != normalize_base_url(current_upstream_base()):
                        set_current_upstream(upstream_base)
                    if should_sanitize(self.path):
                        self.stream_response(response)
                    else:
                        self.buffered_response(response)
                    logging.info("%s %s -> %s upstream=%s sanitized=%s", self.command, self.path, response.status, upstream_base, sanitized)
                    return
        except urllib.error.HTTPError as error:
            current_index = upstream_bases.index(upstream_base) if upstream_base in upstream_bases else 0
            if error.code in UPSTREAM_RETRY_STATUSES and current_index + 1 < len(upstream_bases):
                logging.warning("%s %s -> %s upstream=%s; retrying next upstream", self.command, self.path, error.code, upstream_base)
                error.close()
                remaining_bases = upstream_bases[current_index + 1 :]
                for retry_base in remaining_bases:
                    retry_url = build_upstream_url(self.path, retry_base)
                    retry_headers = self.upstream_headers(len(body), retry_base)
                    retry_request = urllib.request.Request(retry_url, data=body if self.command not in {"GET", "HEAD"} else None, headers=retry_headers, method=self.command)
                    try:
                        with URL_OPENER.open(retry_request, timeout=900) as response:
                            if normalize_base_url(retry_base) != normalize_base_url(current_upstream_base()):
                                set_current_upstream(retry_base)
                            if should_sanitize(self.path):
                                self.stream_response(response)
                            else:
                                self.buffered_response(response)
                            logging.info("%s %s -> %s upstream=%s sanitized=%s", self.command, self.path, response.status, retry_base, sanitized)
                            return
                    except urllib.error.HTTPError as retry_error:
                        if retry_error.code in UPSTREAM_RETRY_STATUSES and retry_base != remaining_bases[-1]:
                            logging.warning("%s %s -> %s upstream=%s; retrying next upstream", self.command, self.path, retry_error.code, retry_base)
                            retry_error.close()
                            continue
                        self.forward_http_error(retry_error, sanitized, retry_base)
                        return
            self.forward_http_error(error, sanitized, upstream_base)
        except CLIENT_DISCONNECT_ERRORS as error:
            logging.warning("client disconnected before proxy response on %s %s: %s", self.command, self.path, short_error(error))
        except UPSTREAM_STREAM_ERRORS as error:
            logging.warning("upstream stream interrupted on %s %s: %s", self.command, self.path, short_error(error))
            if not self._headers_sent:
                self.respond_json(502, {"error": {"message": f"local Codex imagegen guard upstream stream interrupted: {error}"}})
        except urllib.error.URLError as error:
            logging.warning("upstream url error on %s %s: %s", self.command, self.path, short_error(error))
            if not self._headers_sent:
                self.respond_json(502, {"error": {"message": f"local Codex imagegen guard upstream error: {error.reason}"}})
        except Exception as error:
            if self._headers_sent:
                logging.warning("proxy stream ended with %s on %s %s", short_error(error), self.command, self.path)
                return
            logging.exception("proxy error on %s %s", self.command, self.path)
            self.respond_json(502, {"error": {"message": f"local Codex imagegen guard proxy error: {error}"}})

    def forward_http_error(self, error: urllib.error.HTTPError, sanitized: bool, upstream_base: str) -> None:
        error_body = error.read()
        content_type = error.headers.get("Content-Type", "")
        if is_html_response(content_type, error_body):
            logging.warning("upstream returned html error status=%s path=%s upstream=%s", error.code, self.path, upstream_base)
            self.respond_json(error.code, {"error": {"message": "upstream proxy returned an HTML error page", "status": error.code}})
            return
        self.send_response(error.code)
        self.copy_response_headers(error.headers)
        self.send_header("Content-Length", str(len(error_body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.safe_write(error_body)
        logging.info("%s %s -> %s upstream=%s sanitized=%s", self.command, self.path, error.code, upstream_base, sanitized)

    def buffered_response(self, response: Any) -> None:
        content_type = response.headers.get("Content-Type", "")
        first_chunk = response.read(STREAM_CHUNK_SIZE)
        if is_html_response(content_type, first_chunk):
            logging.warning("upstream returned html success status=%s path=%s", response.status, self.path)
            self.respond_json(502, {"error": {"message": "upstream proxy returned an HTML page instead of API JSON", "status": response.status}})
            return
        self.send_response(response.status)
        self.copy_response_headers(response.headers)
        self.send_header("Connection", "close")
        self.end_headers()
        if first_chunk and not self.safe_write(first_chunk):
            return
        while True:
            chunk = response.read(STREAM_CHUNK_SIZE)
            if not chunk:
                break
            if not self.safe_write(chunk):
                break

    def stream_response(self, response: Any) -> None:
        content_type = response.headers.get("Content-Type", "")
        if is_html_response(content_type):
            logging.warning("upstream returned html streaming status=%s path=%s", response.status, self.path)
            self.respond_json(502, {"error": {"message": "upstream proxy returned an HTML page instead of API JSON", "status": response.status}})
            return

        upstream_chunked = response.headers.get("Transfer-Encoding", "").lower() == "chunked"
        self.send_response(response.status)
        self.copy_response_headers(response.headers)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()

        try:
            if upstream_chunked and self.copy_raw_chunked_response(response):
                return
            while True:
                chunk = response.read(STREAM_CHUNK_SIZE)
                if not chunk:
                    break
                if not self.write_chunk(chunk):
                    return
            self.finish_chunked_response()
        except UPSTREAM_STREAM_ERRORS as error:
            logging.warning("upstream stream interrupted on %s %s: %s", self.command, self.path, short_error(error))
        except CLIENT_DISCONNECT_ERRORS as error:
            logging.warning("client disconnected while streaming %s %s: %s", self.command, self.path, short_error(error))

    def copy_raw_chunked_response(self, response: Any) -> bool:
        raw = getattr(response, "fp", None)
        if raw is None:
            return False
        while True:
            line = raw.readline()
            if not line:
                return True
            if not self.safe_write(line):
                return True
            try:
                chunk_size = int(line.split(b";", 1)[0].strip(), 16)
            except ValueError:
                logging.warning("invalid upstream chunk header on %s %s: %r", self.command, self.path, line[:80])
                return True
            if chunk_size == 0:
                while True:
                    trailer = raw.readline()
                    if not trailer:
                        return True
                    if not self.safe_write(trailer):
                        return True
                    if trailer in {b"\r\n", b"\n"}:
                        return True
            remaining = chunk_size + 2
            while remaining > 0:
                data = raw.read(min(STREAM_CHUNK_SIZE, remaining))
                if not data:
                    return True
                remaining -= len(data)
                if not self.safe_write(data):
                    return True

    def upstream_headers(self, content_length: int) -> dict[str, str]:
        blocked = {"host", "content-length", "connection", "proxy-connection", "accept-encoding"}
        headers = {key: value for key, value in self.headers.items() if key.lower() not in blocked}
        headers["Host"] = urllib.parse.urlparse(UPSTREAM_BASE).netloc
        if self.command not in {"GET", "HEAD"}:
            headers["Content-Length"] = str(content_length)
        return headers

    def copy_response_headers(self, headers: Any) -> None:
        blocked = {"connection", "proxy-connection", "transfer-encoding", "content-encoding", "content-length"}
        for key, value in headers.items():
            if key.lower() not in blocked:
                self.send_header(key, value)


def main() -> int:
    setup_logging()
    if not UPSTREAM_BASE:
        logging.error("UPSTREAM_BASE is empty")
        return 2
    server = ReusableThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    logging.info("Codex imagegen guard listening on http://%s:%s -> %s", LISTEN_HOST, LISTEN_PORT, UPSTREAM_BASE)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Codex imagegen guard stopped")
        return 0


if __name__ == "__main__":
    sys.exit(main())
PY_PROXY

cat > "$INSTALL_ROOT/uninstall.sh" <<'SH_UNINSTALL'
#!/bin/zsh
set -euo pipefail

LABEL="dev.codex-imagegen-guard.agent"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
INSTALL_ROOT="$CODEX_HOME/imagegen-guard"
OLD_INSTALL_ROOT="$CODEX_HOME/local-proxy"
BACKUP_DIR="$CODEX_HOME/backups/imagegen-guard"
OLD_BACKUP_DIR="$CODEX_HOME/backups/local-proxy"
CONFIG_FILE="$CODEX_HOME/config.toml"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
pkill -f "$INSTALL_ROOT/codex_imagegen_guard.py" 2>/dev/null || true
pkill -f "$OLD_INSTALL_ROOT/codex_request_sanitizer.py" 2>/dev/null || true
pkill -f "$OLD_INSTALL_ROOT/codex_proxy_supervisor.py" 2>/dev/null || true

latest_config="$(ls -t "$BACKUP_DIR"/config.toml.backup-* 2>/dev/null | head -1 || true)"
old_latest_config="$(ls -t "$OLD_BACKUP_DIR"/config.toml.backup-* 2>/dev/null | head -1 || true)"
if [[ -n "$latest_config" ]]; then
  cp -p "$latest_config" "$CONFIG_FILE"
  echo "Restored Codex config from $latest_config"
elif [[ -n "$old_latest_config" ]]; then
  cp -p "$old_latest_config" "$CONFIG_FILE"
  echo "Restored Codex config from $old_latest_config"
else
  echo "No config backup found; Codex config was not changed."
fi

rm -f "$PLIST_PATH"
echo "Codex imagegen guard uninstalled. Logs and backups remain in $INSTALL_ROOT and $BACKUP_DIR."
SH_UNINSTALL

cat > "$INSTALL_ROOT/doctor.sh" <<'SH_DOCTOR'
#!/bin/zsh
set -euo pipefail

LABEL="dev.codex-imagegen-guard.agent"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
INSTALL_ROOT="$CODEX_HOME/imagegen-guard"
CONFIG_FILE="$CODEX_HOME/config.toml"
DEFAULT_CCSWITCH_URL="http://127.0.0.1:15721/v1"

read_config_value() {
  python3 - "$1" "$2" "$3" <<'PY'
import re
import shlex
import sys
from pathlib import Path

kind, path_raw, key = sys.argv[1:4]
path = Path(path_raw)
if not path.exists():
    raise SystemExit(1)

if kind == "env":
    for line in path.read_text().splitlines():
        if line.startswith(f"{key}="):
            try:
                parsed = shlex.split(line.split("=", 1)[1], posix=True)
                print(parsed[0] if parsed else "")
            except ValueError:
                print(line.split("=", 1)[1].strip("'\""))
            raise SystemExit(0)
    raise SystemExit(1)

provider = key
in_provider = False
provider_header = f"[model_providers.{provider}]"
for line in path.read_text().splitlines():
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

read_active_provider() {
  python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
for line in path.read_text().splitlines():
    match = re.match(r'\s*model_provider\s*=\s*"([^"]+)"', line)
    if match:
        print(match.group(1))
        raise SystemExit(0)
print("Codex")
PY
}

normalize_base_url() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse

raw = sys.argv[1].strip().rstrip("/")
parsed = urllib.parse.urlparse(raw)
host = parsed.hostname or ""
if host == "localhost":
    host = "127.0.0.1"
port = f":{parsed.port}" if parsed.port else ""
path = (parsed.path or "").rstrip("/")
print(urllib.parse.urlunparse((parsed.scheme, f"{host}{port}", path, "", "", "")))
PY
}

is_local_base() {
  [[ "$1" == http://127.0.0.1:* || "$1" == http://localhost:* ]]
}

append_unique_upstream() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return 0
  local normalized_candidate
  normalized_candidate="$(normalize_base_url "$candidate")"
  local existing
  for existing in "${upstream_bases[@]}"; do
    [[ "$(normalize_base_url "$existing")" == "$normalized_candidate" ]] && return
  done
  upstream_bases+=("$candidate")
}

saved_ccswitch_url="$(read_config_value env "$INSTALL_ROOT/config.env" CCSWITCH_URL 2>/dev/null || true)"
CCSWITCH_URL="${CODEX_SANITIZER_CCSWITCH_URL:-${saved_ccswitch_url:-$DEFAULT_CCSWITCH_URL}}"
provider="$(read_active_provider "$CONFIG_FILE" 2>/dev/null || true)"
current_base="$(read_config_value toml "$CONFIG_FILE" "$provider" 2>/dev/null || true)"
listen_port="$(read_config_value env "$INSTALL_ROOT/config.env" LISTEN_PORT 2>/dev/null || true)"
upstream_base="$(read_config_value env "$INSTALL_ROOT/config.env" UPSTREAM_BASE 2>/dev/null || true)"
known_upstreams="$(read_config_value env "$INSTALL_ROOT/config.env" UPSTREAM_BASES 2>/dev/null || true)"
upstream_aliases="$(read_config_value env "$INSTALL_ROOT/config.env" UPSTREAM_ALIASES 2>/dev/null || true)"
listen_port="${listen_port:-11435}"
known_upstreams="${known_upstreams:-https://api.hanhegufei.online/v1,https://ai.ailinyu.de/v1,https://token.fourj.space/v1}"
upstream_aliases="${upstream_aliases:-hanhe=https://api.hanhegufei.online/v1,ailinyu=https://ai.ailinyu.de/v1,fourj=https://token.fourj.space/v1}"
guard_base="http://127.0.0.1:$listen_port/v1"
chain_status="unknown"

if [[ "$(normalize_base_url "$current_base")" == "$(normalize_base_url "$guard_base")" ]]; then
  chain_status="ok"
elif [[ "$(normalize_base_url "$current_base")" == "$(normalize_base_url "$CCSWITCH_URL")" ]]; then
  chain_status="bypassed-cc-switch"
elif is_local_base "$current_base"; then
  chain_status="bypassed-local-upstream"
else
  chain_status="bypassed-remote"
fi

echo "status=$chain_status"
echo "provider=$provider"
echo "codex_base_url=$current_base"
echo "guard_base_url=$guard_base"
echo "guard_upstream=$upstream_base"
echo "active_upstream=$upstream_base"
echo "known_upstreams=$known_upstreams"
echo "upstream_aliases=$upstream_aliases"
if [[ "$chain_status" != "ok" ]]; then
  echo "hint=run $INSTALL_ROOT/repair.sh to route Codex through the guard"
fi

if lsof -nP -iTCP:"$listen_port" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "guard_listening=yes"
else
  echo "guard_listening=no"
fi

ccswitch_port="$(python3 - "$CCSWITCH_URL" <<'PY'
import sys
import urllib.parse
parsed = urllib.parse.urlparse(sys.argv[1])
print(parsed.port or 80)
PY
)"
if lsof -nP -iTCP:"$ccswitch_port" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ccswitch_listening=yes"
else
  echo "ccswitch_listening=no"
fi

launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "launchagent=running" || echo "launchagent=not-running"
SH_DOCTOR

cat > "$INSTALL_ROOT/repair.sh" <<'SH_REPAIR'
#!/bin/zsh
set -euo pipefail

LABEL="dev.codex-imagegen-guard.agent"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
INSTALL_ROOT="$CODEX_HOME/imagegen-guard"
BACKUP_DIR="$CODEX_HOME/backups/imagegen-guard"
CONFIG_FILE="$CODEX_HOME/config.toml"
DEFAULT_CCSWITCH_URL="http://127.0.0.1:15721/v1"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$INSTALL_ROOT/logs" "$BACKUP_DIR"

read_config_value() {
  python3 - "$1" "$2" "$3" <<'PY'
import re
import shlex
import sys
from pathlib import Path

kind, path_raw, key = sys.argv[1:4]
path = Path(path_raw)
if not path.exists():
    raise SystemExit(1)

if kind == "env":
    for line in path.read_text().splitlines():
        if line.startswith(f"{key}="):
            try:
                parsed = shlex.split(line.split("=", 1)[1], posix=True)
                print(parsed[0] if parsed else "")
            except ValueError:
                print(line.split("=", 1)[1].strip("'\""))
            raise SystemExit(0)
    raise SystemExit(1)

provider = key
in_provider = False
provider_header = f"[model_providers.{provider}]"
for line in path.read_text().splitlines():
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

read_active_provider() {
  python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
for line in path.read_text().splitlines():
    match = re.match(r'\s*model_provider\s*=\s*"([^"]+)"', line)
    if match:
        print(match.group(1))
        raise SystemExit(0)
print("Codex")
PY
}

normalize_base_url() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse

raw = sys.argv[1].strip().rstrip("/")
parsed = urllib.parse.urlparse(raw)
host = parsed.hostname or ""
if host == "localhost":
    host = "127.0.0.1"
port = f":{parsed.port}" if parsed.port else ""
path = (parsed.path or "").rstrip("/")
print(urllib.parse.urlunparse((parsed.scheme, f"{host}{port}", path, "", "", "")))
PY
}

is_local_base() {
  [[ "$1" == http://127.0.0.1:* || "$1" == http://localhost:* ]]
}

append_unique_upstream() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return
  local normalized_candidate
  normalized_candidate="$(normalize_base_url "$candidate")"
  local existing
  for existing in "${upstream_bases[@]}"; do
    [[ "$(normalize_base_url "$existing")" == "$normalized_candidate" ]] && return
  done
  upstream_bases+=("$candidate")
}

saved_ccswitch_url="$(read_config_value env "$INSTALL_ROOT/config.env" CCSWITCH_URL 2>/dev/null || true)"
CCSWITCH_URL="${CODEX_SANITIZER_CCSWITCH_URL:-${saved_ccswitch_url:-$DEFAULT_CCSWITCH_URL}}"
provider="${CODEX_SANITIZER_PROVIDER:-$(read_active_provider "$CONFIG_FILE")}"
current_base="$(read_config_value toml "$CONFIG_FILE" "$provider" || true)"
listen_port="$(read_config_value env "$INSTALL_ROOT/config.env" LISTEN_PORT 2>/dev/null || true)"
listen_host="$(read_config_value env "$INSTALL_ROOT/config.env" LISTEN_HOST 2>/dev/null || true)"
no_proxy_value="$(read_config_value env "$INSTALL_ROOT/config.env" NO_PROXY 2>/dev/null || true)"
proxy_mode="$(read_config_value env "$INSTALL_ROOT/config.env" UPSTREAM_PROXY_MODE 2>/dev/null || true)"
listen_port="${listen_port:-11435}"
listen_host="${listen_host:-127.0.0.1}"
no_proxy_value="${CODEX_SANITIZER_NO_PROXY:-${no_proxy_value:-127.0.0.1,localhost,::1}}"
proxy_mode="${CODEX_SANITIZER_UPSTREAM_PROXY_MODE:-${proxy_mode:-system}}"
guard_base="http://127.0.0.1:$listen_port/v1"

if [[ -n "${CODEX_SANITIZER_UPSTREAM:-}" ]]; then
  upstream_base="$CODEX_SANITIZER_UPSTREAM"
elif [[ "$(normalize_base_url "$current_base")" == "$(normalize_base_url "$CCSWITCH_URL")" ]]; then
  upstream_base="$CCSWITCH_URL"
elif [[ "$(normalize_base_url "$current_base")" == "$(normalize_base_url "$guard_base")" ]]; then
  upstream_base="$(read_config_value env "$INSTALL_ROOT/config.env" UPSTREAM_BASE 2>/dev/null || true)"
elif is_local_base "$current_base"; then
  upstream_base="$current_base"
else
  upstream_base="$current_base"
fi

[[ -n "$upstream_base" ]] || {
  echo "ERROR: no upstream could be determined. Set CODEX_SANITIZER_UPSTREAM." >&2
  exit 1
}

upstream_bases=()
append_unique_upstream "$upstream_base"
append_unique_upstream "${CODEX_SANITIZER_UPSTREAM_FALLBACK:-}"
append_unique_upstream "https://api.hanhegufei.online/v1"
append_unique_upstream "https://ai.ailinyu.de/v1"
append_unique_upstream "https://token.fourj.space/v1"
upstream_bases_value="$(IFS=,; printf '%s' "${upstream_bases[*]}")"
upstream_aliases_value="$(read_config_value env "$INSTALL_ROOT/config.env" UPSTREAM_ALIASES 2>/dev/null || echo "hanhe=https://api.hanhegufei.online/v1,ailinyu=https://ai.ailinyu.de/v1,fourj=https://token.fourj.space/v1")"

cp -p "$CONFIG_FILE" "$BACKUP_DIR/config.toml.repair-$STAMP"

cat > "$INSTALL_ROOT/config.env" <<EOF_CONFIG
UPSTREAM_BASE=$(printf '%q' "$upstream_base")
UPSTREAM_BASES=$(printf '%q' "$upstream_bases_value")
UPSTREAM_ALIASES=$(printf '%q' "$upstream_aliases_value")
LISTEN_HOST=$listen_host
LISTEN_PORT=$listen_port
NO_PROXY=$(printf '%q' "$no_proxy_value")
UPSTREAM_PROXY_MODE=$proxy_mode
CCSWITCH_URL=$(printf '%q' "$CCSWITCH_URL")
EOF_CONFIG
chmod 600 "$INSTALL_ROOT/config.env"

python3 - "$CONFIG_FILE" "$listen_port" "$provider" <<'PY_EDIT_CONFIG'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
port = sys.argv[2]
provider = sys.argv[3]
lines = path.read_text().splitlines()
out = []
in_provider = False
changed = False
provider_header = f"[model_providers.{provider}]"
for line in lines:
    stripped = line.strip()
    if stripped == provider_header:
        in_provider = True
        out.append(line)
        continue
    if in_provider and stripped.startswith("[") and stripped.endswith("]"):
        in_provider = False
    if in_provider and re.match(r'\s*base_url\s*=', line):
        prefix = line[: len(line) - len(line.lstrip())]
        out.append(f'{prefix}base_url = "http://127.0.0.1:{port}/v1"')
        changed = True
    else:
        out.append(line)

if not changed:
    raise SystemExit(f"failed to update [model_providers.{provider}] base_url")
path.write_text("\n".join(out) + "\n")
PY_EDIT_CONFIG

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi

echo "Repaired Codex imagegen guard chain."
echo "Provider: $provider"
echo "Upstream: $upstream_base"
echo "Local base_url: http://127.0.0.1:$listen_port/v1"
SH_REPAIR

cat > "$INSTALL_ROOT/switch-upstream.sh" <<'SH_SWITCH'
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

SH_SWITCH

cat > "$INSTALL_ROOT/README.md" <<EOF_README
# Codex Imagegen Guard

这个本机伴随代理只影响 Codex Desktop：

- 只监听 \`127.0.0.1:$listen_port\`
- 只改当前用户的 \`$CONFIG_FILE\`
- 登录后常驻运行，先于 Codex 可用，避免 Codex 启动时请求打到空端口
- 代理自身强制让 \`127.0.0.1/localhost/::1\` 绕过系统 HTTP 代理，降低任意代理软件劫持本机请求的风险
- 上游默认继续使用系统代理；如需强制直连，可安装时设置 \`CODEX_SANITIZER_UPSTREAM_PROXY_MODE=direct\`
- 不改系统代理，不影响浏览器、终端或其他 App
- 保留截图输入，只在没有明确生图意图时移除 \`image_generation\` tool
- 如代理软件启用了 TUN/Network Extension，请在代理软件中手动设置 \`127.0.0.0/8\`、\`localhost\`、\`::1\` 为 DIRECT

## 当前配置

- 上游地址：\`$upstream_base\`
- 本机地址：\`http://127.0.0.1:$listen_port/v1\`
- 上游代理模式：\`$upstream_proxy_mode\`
- 本机代理绕过：\`$no_proxy_value\`
- 兼容 CC Switch 路由：\`$ccswitch_base\`
- LaunchAgent：\`$PLIST_PATH\`

## 验证

\`\`\`zsh
"$INSTALL_ROOT/doctor.sh"
launchctl print gui/\$(id -u)/$LABEL
lsof -nP -iTCP:$listen_port -sTCP:LISTEN
curl -i --noproxy 127.0.0.1 http://127.0.0.1:$listen_port/healthz
tail -30 "$INSTALL_ROOT/logs/proxy.log"
\`\`\`

如果中转站后续又把 Codex 改回自己的路由，可运行：

\`\`\`zsh
"$INSTALL_ROOT/repair.sh"
\`\`\`

## 卸载

\`\`\`zsh
"$INSTALL_ROOT/uninstall.sh"
\`\`\`

卸载会恢复最近一次安装前的 \`config.toml\` 备份，并停止 LaunchAgent。
EOF_README

chmod 700 "$INSTALL_ROOT/codex_imagegen_guard.py" "$INSTALL_ROOT/uninstall.sh" "$INSTALL_ROOT/doctor.sh" "$INSTALL_ROOT/repair.sh" "$INSTALL_ROOT/switch-upstream.sh"

python3 - "$CONFIG_FILE" "$listen_port" "$provider_name" <<'PY_EDIT_CONFIG'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
port = sys.argv[2]
provider = sys.argv[3]
text = path.read_text()
lines = text.splitlines()
out = []
in_provider = False
changed = False
provider_header = f"[model_providers.{provider}]"
for line in lines:
    stripped = line.strip()
    if stripped == provider_header:
        in_provider = True
        out.append(line)
        continue
    if in_provider and stripped.startswith("[") and stripped.endswith("]"):
        in_provider = False
    if in_provider and re.match(r'\s*base_url\s*=', line):
        prefix = line[: len(line) - len(line.lstrip())]
        out.append(f'{prefix}base_url = "http://127.0.0.1:{port}/v1"')
        changed = True
    else:
        out.append(line)

if not changed:
    raise SystemExit(f"failed to update [model_providers.{provider}] base_url")
path.write_text("\n".join(out) + "\n")
PY_EDIT_CONFIG

cat > "$INSTALL_ROOT/$LABEL.plist" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$INSTALL_ROOT/codex_imagegen_guard.py</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$INSTALL_ROOT/logs/launchagent.out.log</string>
  <key>StandardErrorPath</key>
  <string>$INSTALL_ROOT/logs/launchagent.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>NO_PROXY</key>
    <string>$no_proxy_value</string>
    <key>no_proxy</key>
    <string>$no_proxy_value</string>
  </dict>
</dict>
</plist>
EOF_PLIST

plutil -lint "$INSTALL_ROOT/$LABEL.plist" >/dev/null
cp -p "$INSTALL_ROOT/$LABEL.plist" "$PLIST_PATH"

stop_existing_agents
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

say "Installed Codex imagegen guard."
say "Provider: $provider_name"
say "Upstream: $upstream_base"
say "Upstream proxy mode: $upstream_proxy_mode"
say "Local base_url: http://127.0.0.1:$listen_port/v1"
say "Restart Codex Desktop if it was already open."
