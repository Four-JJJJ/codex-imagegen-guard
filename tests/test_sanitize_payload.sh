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

cat > "$install_root/config.env" <<'EOF_ENV'
UPSTREAM_BASE=https://token.fourj.space/v1
UPSTREAM_BASES=https://token.fourj.space/v1,https://api.hanhegufei.online/v1
UPSTREAM_ALIASES=fourj=https://token.fourj.space/v1,hanhe=https://api.hanhegufei.online/v1
LISTEN_HOST=127.0.0.1
LISTEN_PORT=11435
NO_PROXY=127.0.0.1,localhost,::1
UPSTREAM_PROXY_MODE=system
CCSWITCH_URL=http://127.0.0.1:15721/v1
AUTO_DISCOVER_UPSTREAM=0
DISCOVERY_INTERVAL=5
DISCOVERY_DEBOUNCE=1
EOF_ENV

python3 - "$proxy_py" <<'PY'
import copy
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(guard)

ordinary_payload = {
    "input": [{"role": "user", "content": "分析这张截图里按钮为什么没对齐"}],
    "tools": [{"type": "image_generation"}, {"type": "web_search_preview"}],
    "tool_choice": {"type": "image_generation"},
}
sanitized, changed = guard.sanitize_payload(copy.deepcopy(ordinary_payload))
assert changed is True
assert sanitized["tools"] == [{"type": "web_search_preview"}]
assert "tool_choice" not in sanitized

explicit_payload = {
    "input": [{"role": "user", "content": "帮我生成图片，一张干净的产品海报"}],
    "tools": [{"type": "image_generation"}],
    "tool_choice": {"type": "image_generation"},
}
kept, changed = guard.sanitize_payload(copy.deepcopy(explicit_payload))
assert changed is False
assert kept == explicit_payload

negative_payload = {
    "input": [{"role": "user", "content": "不要使用 image_generation，只解释这段代码"}],
    "tools": [{"type": "image_generation"}],
}
sanitized, changed = guard.sanitize_payload(copy.deepcopy(negative_payload))
assert changed is True
assert "tools" not in sanitized

strict_explicit_payload = {
    "input": [{"role": "user", "content": "帮我生成图片，一张极简海报"}],
    "tools": [{"type": "image_generation"}],
    "tool_choice": {"type": "image_generation"},
}
kept, changed = guard.sanitize_payload(copy.deepcopy(strict_explicit_payload))
assert changed is False
assert kept == strict_explicit_payload

ui_layout_payload = {
    "input": [{"role": "user", "content": "发送的首条对话距离窗口上部 16px，生成图片的模块距离对话 40px 向下排列"}],
    "tools": [{"type": "image_generation"}, {"type": "web_search_preview"}],
    "tool_choice": {"type": "image_generation"},
}
sanitized, changed = guard.sanitize_payload(copy.deepcopy(ui_layout_payload))
assert changed is True
assert sanitized["tools"] == [{"type": "web_search_preview"}]
assert "tool_choice" not in sanitized

button_payload = {
    "input": [{"role": "user", "content": "图片生成按钮为什么没对齐"}],
    "tools": [{"type": "image_generation"}],
}
sanitized, changed = guard.sanitize_payload(copy.deepcopy(button_payload))
assert changed is True
assert "tools" not in sanitized

error_payload = {
    "input": [{"role": "user", "content": "这个生图功能为什么报 403"}],
    "tools": [{"type": "image_generation"}],
}
sanitized, changed = guard.sanitize_payload(copy.deepcopy(error_payload))
assert changed is True
assert "tools" not in sanitized

not_request_payload = {
    "input": [{"role": "user", "content": "不是要生成图片，我是在描述设置页"}],
    "tools": [{"type": "image_generation"}],
}
sanitized, changed = guard.sanitize_payload(copy.deepcopy(not_request_payload))
assert changed is True
assert "tools" not in sanitized

english_descriptive_payload = {
    "input": [{"role": "user", "content": "the image generation panel should stay 40px below the message"}],
    "tools": [{"type": "image_generation"}],
}
sanitized, changed = guard.sanitize_payload(copy.deepcopy(english_descriptive_payload))
assert changed is True
assert "tools" not in sanitized

english_explicit_payload = {
    "input": [{"role": "user", "content": "please generate an image of a product poster"}],
    "tools": [{"type": "image_generation"}],
    "tool_choice": {"type": "image_generation"},
}
kept, changed = guard.sanitize_payload(copy.deepcopy(english_explicit_payload))
assert changed is False
assert kept == english_explicit_payload
PY
