#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_home="$(mktemp -d)"
proxy_py="$tmp_home/codex_imagegen_guard.py"
trap 'rm -rf "$tmp_home"' EXIT

export HOME="$tmp_home"
export CODEX_HOME="$tmp_home/.codex"

install_root="$CODEX_HOME/imagegen-guard"
mkdir -p "$install_root" "$CODEX_HOME"

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

cat > "$CODEX_HOME/config.toml" <<'EOF_CONFIG'
model_provider = "Codex"

[model_providers]
[model_providers.Codex]
name = "Codex"
base_url = "http://127.0.0.1:11435/v1"
EOF_CONFIG

cat > "$install_root/config.env" <<'EOF_ENV'
UPSTREAM_BASE=https://token.fourj.space/v1
UPSTREAM_BASES=https://token.fourj.space/v1,https://api.hanhegufei.online/v1
UPSTREAM_ALIASES=fourj=https://token.fourj.space/v1,hanhe=https://api.hanhegufei.online/v1
LISTEN_HOST=127.0.0.1
LISTEN_PORT=11435
NO_PROXY=127.0.0.1,localhost,::1
UPSTREAM_PROXY_MODE=system
CCSWITCH_URL=http://127.0.0.1:15721/v1
AUTO_DISCOVER_UPSTREAM=1
DISCOVERY_INTERVAL=5
DISCOVERY_DEBOUNCE=0
EOF_ENV

python3 - "$proxy_py" "$CODEX_HOME/config.toml" "$install_root/config.env" <<'PY'
import importlib.util
import sys
from pathlib import Path

module_path, codex_config, env_config = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("guard", module_path)
guard = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(guard)

assert guard.current_upstream_base() == "https://token.fourj.space/v1"

Path(codex_config).write_text('''model_provider = "Codex"

[model_providers]
[model_providers.Codex]
name = "Codex"
base_url = "https://api.hanhegufei.online/v1"
''')

changed = guard.detect_and_repair_codex_config()
assert changed is True

codex_text = Path(codex_config).read_text()
env_text = Path(env_config).read_text()
assert 'base_url = "http://127.0.0.1:11435/v1"' in codex_text
assert "UPSTREAM_BASE=https://api.hanhegufei.online/v1" in env_text
assert guard.current_upstream_base() == "https://api.hanhegufei.online/v1"

changed_again = guard.detect_and_repair_codex_config()
assert changed_again is False
PY
