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

## 与本机中转站一起使用

可以兼容 CC Switch 或其它本机中转站。推荐链路是：

```txt
Codex Desktop -> codex-imagegen-guard:11435 -> 当前本机中转站 -> 当前 Provider
```

推荐安装顺序：

1. 先打开你的中转站服务。
2. 让 Codex 暂时指到这个中转站的 `base_url`，例如 `http://127.0.0.1:15721/v1` 或其它端口。
3. 最后安装或重装 `codex-imagegen-guard`。安装脚本会读取当前 Codex provider 的 `base_url`，并自动把它作为 guard 的上游。

如果中转站后续又把 Codex 配置改回自己的路由，运行：

```zsh
~/.codex/imagegen-guard/repair.sh
```

查看当前链路状态：

```zsh
~/.codex/imagegen-guard/doctor.sh
```

`doctor.sh` 的 `status=ok` 表示 Codex 正在经过 guard；`status=bypassed-local-upstream` 或 `status=bypassed-cc-switch` 表示本机中转站又接管了 Codex 入口，需要运行 `repair.sh`。

切换已保存的上游：

```zsh
~/.codex/imagegen-guard/switch-upstream.sh hanhe
~/.codex/imagegen-guard/switch-upstream.sh ailinyu
~/.codex/imagegen-guard/switch-upstream.sh fourj
~/.codex/imagegen-guard/switch-upstream.sh status
~/.codex/imagegen-guard/switch-upstream.sh custom https://api.example.com
```

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
- `CODEX_SANITIZER_UPSTREAM_FALLBACK`：额外备用上游。默认会保留 `https://api.hanhegufei.online/v1`、`https://ai.ailinyu.de/v1` 和 `https://token.fourj.space/v1` 作为候选，当前上游返回 `401` 时自动尝试下一个。
- 上游识别不依赖域名名单：安装或修复时会读取当前 Codex provider 的 `base_url`，任意远程或本机 OpenAI-compatible 上游都可以。
- `CODEX_SANITIZER_CCSWITCH_URL`：兼容旧版 CC Switch 判断的可选覆盖；一般不需要设置，脚本会优先读取当前 Codex `base_url`。
- `CODEX_SANITIZER_NO_PROXY`：覆盖本服务使用的 `NO_PROXY`。
- `CODEX_SANITIZER_UPSTREAM_PROXY_MODE`：`system` 或 `direct`。默认 `system`，表示上游继续走系统代理。
- `CODEX_SANITIZER_RETRY_STATUSES`：触发备用上游重试的 HTTP 状态码，默认 `401`。

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

## With Local Upstreams

This project can work with CC Switch or any other local OpenAI-compatible upstream. The recommended chain is:

```txt
Codex Desktop -> codex-imagegen-guard:11435 -> current local upstream -> active provider
```

Recommended setup:

1. Start your local upstream service first.
2. Temporarily point Codex to that upstream `base_url`, for example `http://127.0.0.1:15721/v1` or another port.
3. Install or reinstall `codex-imagegen-guard` last. The installer reads the current Codex provider `base_url` and stores it as the guard upstream.

If the upstream later rewrites Codex back to its own route, run:

```zsh
~/.codex/imagegen-guard/repair.sh
```

Check the current chain:

```zsh
~/.codex/imagegen-guard/doctor.sh
```

`status=ok` means Codex is going through the guard. `status=bypassed-local-upstream` or `status=bypassed-cc-switch` means the local upstream took over the Codex entry again, so run `repair.sh`.

## Uninstall

```zsh
~/.codex/imagegen-guard/uninstall.sh
```

The uninstaller stops the LaunchAgent and restores the latest saved Codex config backup when available.
