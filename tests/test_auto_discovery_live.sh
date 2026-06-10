#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_home="$(mktemp -d)"
proxy_py="$tmp_home/codex_imagegen_guard.py"
trap '[[ -n "${guard_pid:-}" ]] && kill "$guard_pid" 2>/dev/null || true; rm -rf "$tmp_home"' EXIT

export HOME="$tmp_home"
export CODEX_HOME="$tmp_home/.codex"

install_root="$CODEX_HOME/imagegen-guard"
mkdir -p "$install_root/logs" "$CODEX_HOME"

python3 - "$repo_root/install.sh" "$proxy_py" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
start_marker = 'cat > "$INSTALL_ROOT/codex_imagegen_guard.py" <<\'PY_PROXY\'\n'
end_marker = '\nPY_PROXY\n'
start = text.index(start_marker) + len(start_marker)
end = text.index(end_marker, start)
Path(sys.argv[2]).write_text(text[start:end])
PY

port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

cat > "$CODEX_HOME/config.toml" <<EOF_CONFIG
model_provider = "Codex"

[model_providers]
[model_providers.Codex]
name = "Codex"
base_url = "http://127.0.0.1:$port/v1"
EOF_CONFIG

cat > "$install_root/config.env" <<EOF_ENV
UPSTREAM_BASE=https://token.fourj.space/v1
UPSTREAM_BASES=https://token.fourj.space/v1,https://api.hanhegufei.online/v1
UPSTREAM_ALIASES=fourj=https://token.fourj.space/v1,hanhe=https://api.hanhegufei.online/v1
LISTEN_HOST=127.0.0.1
LISTEN_PORT=$port
NO_PROXY=127.0.0.1,localhost,::1
UPSTREAM_PROXY_MODE=system
CCSWITCH_URL=http://127.0.0.1:15721/v1
AUTO_DISCOVER_UPSTREAM=1
DISCOVERY_INTERVAL=1
DISCOVERY_DEBOUNCE=0
EOF_ENV

python3 "$proxy_py" &
guard_pid="$!"

for _ in {1..50}; do
  if curl --noproxy 127.0.0.1 -fsS "http://127.0.0.1:$port/healthz" >/tmp/guard-healthz-initial.json 2>/dev/null; then
    break
  fi
  sleep 0.1
done

grep -q 'token.fourj.space' /tmp/guard-healthz-initial.json

cat > "$CODEX_HOME/config.toml" <<'EOF_CONFIG'
model_provider = "Codex"

[model_providers]
[model_providers.Codex]
name = "Codex"
base_url = "https://api.hanhegufei.online/v1"
EOF_CONFIG

for _ in {1..50}; do
  if grep -q "http://127.0.0.1:$port/v1" "$CODEX_HOME/config.toml" && grep -q '^UPSTREAM_BASE=https://api.hanhegufei.online/v1$' "$install_root/config.env"; then
    break
  fi
  sleep 0.1
done

grep -q "http://127.0.0.1:$port/v1" "$CODEX_HOME/config.toml"
grep -q '^UPSTREAM_BASE=https://api.hanhegufei.online/v1$' "$install_root/config.env"
curl --noproxy 127.0.0.1 -fsS "http://127.0.0.1:$port/healthz" >/tmp/guard-healthz-discovered.json
grep -q 'api.hanhegufei.online' /tmp/guard-healthz-discovered.json
