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

read_existing_upstream() {
  if [[ -f "$INSTALL_ROOT/config.env" ]]; then
    read_upstream_from_env "$INSTALL_ROOT/config.env" && return
  fi

  if [[ -f "$OLD_INSTALL_ROOT/config.env" ]]; then
    read_upstream_from_env "$OLD_INSTALL_ROOT/config.env" && return
  fi

  local latest_backup
  latest_backup="$(ls -t "$BACKUP_DIR"/config.toml.backup-* 2>/dev/null | head -1 || true)"
  if [[ -n "$latest_backup" ]]; then
    local backup_base
    backup_base="$(read_codex_base_url "$latest_backup" "$provider_name" || true)"
    if [[ -n "$backup_base" ]] && ! is_local_base "$backup_base"; then
      printf '%s\n' "$backup_base"
      return
    fi
  fi

  local old_latest_backup
  old_latest_backup="$(ls -t "$OLD_BACKUP_DIR"/config.toml.backup-* 2>/dev/null | head -1 || true)"
  if [[ -n "$old_latest_backup" ]]; then
    local old_backup_base
    old_backup_base="$(read_codex_base_url "$old_latest_backup" "$provider_name" || true)"
    if [[ -n "$old_backup_base" ]] && ! is_local_base "$old_backup_base"; then
      printf '%s\n' "$old_backup_base"
      return
    fi
  fi

  return 1
}

read_upstream_from_env() {
  python3 - "$1" <<'PY'
import shlex
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("UPSTREAM_BASE="):
        print(shlex.split(line, posix=True)[0].split("=", 1)[1])
        raise SystemExit(0)
raise SystemExit(1)
PY
}

if is_local_base "$current_base"; then
  upstream_base="$(read_existing_upstream || true)"
  [[ -n "${upstream_base:-}" ]] || fail "Codex already points to a local proxy, but no original upstream was found. Restore config.toml or set CODEX_SANITIZER_UPSTREAM."
else
  upstream_base="$current_base"
fi

if [[ -n "${CODEX_SANITIZER_UPSTREAM:-}" ]]; then
  upstream_base="$CODEX_SANITIZER_UPSTREAM"
fi

stop_existing_agents

choose_port() {
  local existing_port=""
  if [[ "$current_base" =~ '^http://(127\.0\.0\.1|localhost):([0-9]+)/v1/?$' ]]; then
    existing_port="${match[2]}"
  fi
  if [[ -n "$existing_port" ]]; then
    printf '%s\n' "$existing_port"
    return
  fi
  local port
  for port in $(seq "$DEFAULT_PORT" "$MAX_PORT"); do
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
LISTEN_HOST=127.0.0.1
LISTEN_PORT=$listen_port
NO_PROXY=$(printf '%q' "$no_proxy_value")
UPSTREAM_PROXY_MODE=$upstream_proxy_mode
EOF_CONFIG
chmod 600 "$INSTALL_ROOT/config.env"

cat > "$INSTALL_ROOT/codex_imagegen_guard.py" <<'PY_PROXY'
#!/usr/bin/env python3
import json
import logging
import os
import re
import shlex
import sys
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
LOG_PATH = os.path.expanduser(os.environ.get("CODEX_SANITIZER_LOG", "~/.codex/imagegen-guard/logs/proxy.log"))
NO_PROXY_VALUE = CONFIG.get("NO_PROXY", "127.0.0.1,localhost,::1")
os.environ["NO_PROXY"] = NO_PROXY_VALUE
os.environ["no_proxy"] = NO_PROXY_VALUE
UPSTREAM_PROXY_MODE = os.environ.get("CODEX_SANITIZER_UPSTREAM_PROXY_MODE", CONFIG.get("UPSTREAM_PROXY_MODE", "system"))
URL_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({})) if UPSTREAM_PROXY_MODE == "direct" else urllib.request.build_opener()

IMAGE_TOOL_NAMES = {"image_generation"}
USER_TEXT_KEYS = {"input", "text", "input_text", "content", "message", "prompt"}
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


def setup_logging() -> None:
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    logging.basicConfig(filename=LOG_PATH, level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


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


def has_explicit_image_intent(payload: Any) -> bool:
    chunks: list[str] = []
    collect_text(payload, chunks)
    text = "\n".join(chunks).lower()
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


def build_upstream_url(path: str) -> str:
    if UPSTREAM_BASE.endswith("/v1") and (path == "/v1" or path.startswith("/v1/") or path.startswith("/v1?")):
        path = path.removeprefix("/v1") or "/"
    return f"{UPSTREAM_BASE}{path if path.startswith('/') else '/' + path}"


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.info("%s - %s", self.client_address[0], fmt % args)

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
        self.wfile.write(body)
        self.wfile.flush()

    def forward(self) -> None:
        if self.path in {"/healthz", "/v1/healthz"}:
            self.respond_json(200, {"status": "ok", "upstream": UPSTREAM_BASE, "listen": f"{LISTEN_HOST}:{LISTEN_PORT}"})
            return
        if not UPSTREAM_BASE:
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

        upstream_url = build_upstream_url(self.path)
        headers = self.upstream_headers(len(body))
        request = urllib.request.Request(upstream_url, data=body if self.command not in {"GET", "HEAD"} else None, headers=headers, method=self.command)

        try:
            with URL_OPENER.open(request, timeout=900) as response:
                content_type = response.headers.get("Content-Type", "")
                first_chunk = response.read(65536)
                if "text/html" in content_type.lower() or first_chunk.lstrip().lower().startswith(b"<!doctype html") or first_chunk.lstrip().lower().startswith(b"<html"):
                    logging.warning("upstream returned html success status=%s path=%s", response.status, self.path)
                    self.respond_json(502, {"error": {"message": "upstream proxy returned an HTML page instead of API JSON", "status": response.status}})
                    return
                self.send_response(response.status)
                self.copy_response_headers(response.headers)
                self.send_header("Connection", "close")
                self.end_headers()
                if first_chunk:
                    self.wfile.write(first_chunk)
                    self.wfile.flush()
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                logging.info("%s %s -> %s sanitized=%s", self.command, self.path, response.status, sanitized)
        except urllib.error.HTTPError as error:
            error_body = error.read()
            content_type = error.headers.get("Content-Type", "")
            if "text/html" in content_type.lower() or error_body.lstrip().lower().startswith(b"<!doctype html") or error_body.lstrip().lower().startswith(b"<html"):
                logging.warning("upstream returned html error status=%s path=%s", error.code, self.path)
                self.respond_json(error.code, {"error": {"message": "upstream proxy returned an HTML error page", "status": error.code}})
                return
            self.send_response(error.code)
            self.copy_response_headers(error.headers)
            self.send_header("Content-Length", str(len(error_body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(error_body)
            self.wfile.flush()
            logging.info("%s %s -> %s sanitized=%s", self.command, self.path, error.code, sanitized)
        except Exception as error:
            logging.exception("proxy error on %s %s", self.command, self.path)
            self.respond_json(502, {"error": {"message": f"local Codex imagegen guard proxy error: {error}"}})

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
- LaunchAgent：\`$PLIST_PATH\`

## 验证

\`\`\`zsh
launchctl print gui/\$(id -u)/$LABEL
lsof -nP -iTCP:$listen_port -sTCP:LISTEN
curl -i --noproxy 127.0.0.1 http://127.0.0.1:$listen_port/healthz
tail -30 "$INSTALL_ROOT/logs/proxy.log"
\`\`\`

## 卸载

\`\`\`zsh
"$INSTALL_ROOT/uninstall.sh"
\`\`\`

卸载会恢复最近一次安装前的 \`config.toml\` 备份，并停止 LaunchAgent。
EOF_README

chmod 700 "$INSTALL_ROOT/codex_imagegen_guard.py" "$INSTALL_ROOT/uninstall.sh"

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
