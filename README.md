# codex-imagegen-guard

中文 | [English](#english)

`codex-imagegen-guard` 是一个 macOS 本机守卫服务，用在 Codex Desktop 前面。

它会拦截 Codex 发往 OpenAI-compatible `/v1/responses` 的本机请求：当请求里带了 `image_generation` tool，但用户文字没有明确表达“生成图片 / 生图 / 画一张 / create image / generate image”等意图时，自动移除这个 tool。截图输入、读图分析、普通代码任务不会因为误带生图工具而触发生图流程。

## 安装

一行安装：

```zsh
curl -fsSL https://raw.githubusercontent.com/OWNER_OR_ORG/codex-imagegen-guard/main/install.sh | zsh
```

更谨慎的方式是先下载/审阅再运行：

```zsh
git clone https://github.com/OWNER_OR_ORG/codex-imagegen-guard.git
cd codex-imagegen-guard
zsh install.sh
```

安装后请完全退出并重新打开 Codex Desktop。

## 它会做什么

- 只支持 macOS Codex Desktop。
- 启动一个只监听 `127.0.0.1` 的本机服务，默认端口 `11435`。
- 把当前 Codex provider 的 `base_url` 改为 `http://127.0.0.1:11435/v1`。
- 保存安装前的 `~/.codex/config.toml` 备份。
- 通过 LaunchAgent 常驻运行：`dev.codex-imagegen-guard.agent`。
- 默认不修改系统代理、TUN、Network Extension 或任何代理软件配置。

## 验证

```zsh
launchctl print gui/$(id -u)/dev.codex-imagegen-guard.agent
lsof -nP -iTCP:11435 -sTCP:LISTEN
curl -i --noproxy 127.0.0.1 http://127.0.0.1:11435/healthz
```

`/healthz` 应返回 JSON，例如：

```json
{"status":"ok","upstream":"https://example.com/v1","listen":"127.0.0.1:11435"}
```

## 代理软件设置

本服务会在自身进程内设置：

```txt
NO_PROXY=127.0.0.1,localhost,::1
```

这能避免大多数 HTTP 代理劫持本机请求。但如果你的代理软件启用了 TUN、增强模式或 Network Extension，建议在代理软件里手动加入直连规则：

```txt
127.0.0.0/8 DIRECT
localhost DIRECT
::1 DIRECT
```

不同代理软件写法不同，核心目标是：`127.0.0.1:11435` 必须走 DIRECT。

## 高级配置

安装时可通过环境变量覆盖默认行为：

```zsh
CODEX_SANITIZER_PROVIDER=Codex \
CODEX_SANITIZER_UPSTREAM=https://api.example.com/v1 \
CODEX_SANITIZER_UPSTREAM_PROXY_MODE=system \
zsh install.sh
```

可用变量：

- `CODEX_SANITIZER_PROVIDER`：指定要修改的 Codex provider，默认读取当前 `model_provider`。
- `CODEX_SANITIZER_UPSTREAM`：指定真实上游 `base_url`。
- `CODEX_SANITIZER_NO_PROXY`：覆盖本服务使用的 `NO_PROXY`。
- `CODEX_SANITIZER_UPSTREAM_PROXY_MODE`：`system` 或 `direct`。默认 `system`，表示上游继续走系统代理。

## 卸载

```zsh
~/.codex/imagegen-guard/uninstall.sh
```

卸载会停止 LaunchAgent，并尽量恢复安装前的 `~/.codex/config.toml`。

## English

`codex-imagegen-guard` is a local macOS guard for Codex Desktop.

It sits in front of Codex's OpenAI-compatible `/v1/responses` endpoint. If a request includes the `image_generation` tool but the user's text does not explicitly ask to generate an image, the guard removes that tool before forwarding the request upstream.

This is useful when Codex Desktop accidentally includes image generation while the user only wants screenshot analysis, coding help, or normal text work.

## Install

One-line install:

```zsh
curl -fsSL https://raw.githubusercontent.com/OWNER_OR_ORG/codex-imagegen-guard/main/install.sh | zsh
```

For a safer review-first install:

```zsh
git clone https://github.com/OWNER_OR_ORG/codex-imagegen-guard.git
cd codex-imagegen-guard
zsh install.sh
```

Restart Codex Desktop after installation.

## What It Does

- macOS Codex Desktop only.
- Starts a localhost-only service on `127.0.0.1`, default port `11435`.
- Changes the active Codex provider `base_url` to `http://127.0.0.1:11435/v1`.
- Backs up `~/.codex/config.toml`.
- Runs as LaunchAgent `dev.codex-imagegen-guard.agent`.
- Does not modify system proxy, TUN, Network Extension, or third-party proxy app settings.

## Verify

```zsh
launchctl print gui/$(id -u)/dev.codex-imagegen-guard.agent
lsof -nP -iTCP:11435 -sTCP:LISTEN
curl -i --noproxy 127.0.0.1 http://127.0.0.1:11435/healthz
```

## Proxy Apps

The guard sets process-level:

```txt
NO_PROXY=127.0.0.1,localhost,::1
```

If you use a TUN mode, enhanced mode, or Network Extension based proxy app, add DIRECT rules manually:

```txt
127.0.0.0/8 DIRECT
localhost DIRECT
::1 DIRECT
```

The goal is simple: `127.0.0.1:11435` must not be intercepted by your proxy app.

## Uninstall

```zsh
~/.codex/imagegen-guard/uninstall.sh
```

The uninstaller stops the LaunchAgent and restores the latest saved Codex config backup when available.
