#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT

export HOME="$tmp_home"
export CODEX_HOME="$tmp_home/.codex"

fake_bin="$tmp_home/bin"
install_root="$CODEX_HOME/imagegen-guard"
mkdir -p "$fake_bin" "$install_root" "$CODEX_HOME"

cat > "$fake_bin/launchctl" <<'EOF_LAUNCHCTL'
#!/bin/zsh
case "$1" in
  getenv)
    exit 1
    ;;
  bootout|bootstrap|kickstart|print)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF_LAUNCHCTL
chmod +x "$fake_bin/launchctl"

cat > "$fake_bin/lsof" <<'EOF_LSOF'
#!/bin/zsh
exit 1
EOF_LSOF
chmod +x "$fake_bin/lsof"

cat > "$fake_bin/plutil" <<'EOF_PLUTIL'
#!/bin/zsh
exit 0
EOF_PLUTIL
chmod +x "$fake_bin/plutil"

cat > "$fake_bin/pkill" <<'EOF_PKILL'
#!/bin/zsh
exit 1
EOF_PKILL
chmod +x "$fake_bin/pkill"

export PATH="$fake_bin:$PATH"

cat > "$CODEX_HOME/config.toml" <<'EOF_CONFIG'
model_provider = "Codex"

[model_providers]
[model_providers.Codex]
name = "Codex"
base_url = "http://127.0.0.1:11435/v1"
EOF_CONFIG

cat > "$install_root/config.env" <<'EOF_ENV'
UPSTREAM_BASE=https://token.fourj.space/v1
UPSTREAM_BASES=https://token.fourj.space/v1,https://custom.example/v1,https://api.hanhegufei.online/v1
UPSTREAM_ALIASES=fourj=https://token.fourj.space/v1,custom=https://custom.example/v1,hanhe=https://api.hanhegufei.online/v1
LISTEN_HOST=127.0.0.1
LISTEN_PORT=11435
NO_PROXY=127.0.0.1,localhost,::1
UPSTREAM_PROXY_MODE=system
CCSWITCH_URL=http://127.0.0.1:15721/v1
AUTO_DISCOVER_UPSTREAM=0
DISCOVERY_INTERVAL=9
DISCOVERY_DEBOUNCE=2
EOF_ENV

zsh "$repo_root/install.sh" >/tmp/install-preserves-discovery.out

grep -q '^UPSTREAM_BASE=https://token.fourj.space/v1$' "$install_root/config.env"
grep -q '^UPSTREAM_BASES=https://token.fourj.space/v1,https://custom.example/v1,https://api.hanhegufei.online/v1,https://ai.ailinyu.de/v1$' "$install_root/config.env"
grep -q '^UPSTREAM_ALIASES=fourj=https://token.fourj.space/v1,custom=https://custom.example/v1,hanhe=https://api.hanhegufei.online/v1$' "$install_root/config.env"
grep -q '^AUTO_DISCOVER_UPSTREAM=0$' "$install_root/config.env"
grep -q '^DISCOVERY_INTERVAL=9$' "$install_root/config.env"
grep -q '^DISCOVERY_DEBOUNCE=2$' "$install_root/config.env"
grep -q 'base_url = "http://127.0.0.1:11435/v1"' "$CODEX_HOME/config.toml"
