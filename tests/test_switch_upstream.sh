#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT

export HOME="$tmp_home"
export CODEX_HOME="$tmp_home/.codex"

install_root="$CODEX_HOME/imagegen-guard"
mkdir -p "$install_root" "$CODEX_HOME"

cat > "$CODEX_HOME/config.toml" <<'EOF_CONFIG'
model_provider = "Codex"

[model_providers]
[model_providers.Codex]
name = "Codex"
base_url = "http://127.0.0.1:11435/v1"
EOF_CONFIG

cat > "$install_root/config.env" <<'EOF_ENV'
UPSTREAM_BASE=https://ai.ailinyu.de/v1
UPSTREAM_BASES=https://api.hanhegufei.online/v1,https://ai.ailinyu.de/v1,https://token.fourj.space/v1
UPSTREAM_ALIASES=hanhe=https://api.hanhegufei.online/v1,ailinyu=https://ai.ailinyu.de/v1,fourj=https://token.fourj.space/v1
LISTEN_HOST=127.0.0.1
LISTEN_PORT=11435
NO_PROXY=127.0.0.1,localhost,::1
UPSTREAM_PROXY_MODE=system
CCSWITCH_URL=http://127.0.0.1:15721/v1
EOF_ENV

cp "$repo_root/switch-upstream.sh" "$install_root/switch-upstream.sh"
chmod +x "$install_root/switch-upstream.sh"

"$install_root/switch-upstream.sh" hanhe >/tmp/switch-hanhe.out
grep -q '^UPSTREAM_BASE=https://api.hanhegufei.online/v1$' "$install_root/config.env"
grep -q '^UPSTREAM_BASES=https://api.hanhegufei.online/v1,https://ai.ailinyu.de/v1,https://token.fourj.space/v1$' "$install_root/config.env"

"$install_root/switch-upstream.sh" fourj >/tmp/switch-fourj.out
grep -q '^UPSTREAM_BASE=https://token.fourj.space/v1$' "$install_root/config.env"
grep -q '^UPSTREAM_BASES=https://token.fourj.space/v1,https://api.hanhegufei.online/v1,https://ai.ailinyu.de/v1$' "$install_root/config.env"

"$install_root/switch-upstream.sh" custom https://example.test >/tmp/switch-custom.out
grep -q '^UPSTREAM_BASE=https://example.test/v1$' "$install_root/config.env"
grep -q '^UPSTREAM_BASES=https://example.test/v1,https://token.fourj.space/v1,https://api.hanhegufei.online/v1,https://ai.ailinyu.de/v1$' "$install_root/config.env"

"$install_root/switch-upstream.sh" status > /tmp/switch-status.out
grep -q '^active_upstream=https://example.test/v1$' /tmp/switch-status.out
grep -q '^known_upstreams=https://example.test/v1,https://token.fourj.space/v1,https://api.hanhegufei.online/v1,https://ai.ailinyu.de/v1$' /tmp/switch-status.out
