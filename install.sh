#!/usr/bin/env bash
# Tracepilot one-line installer.
#   curl -fsSL https://raw.githubusercontent.com/saumitra99/tracepilot-releases/main/install.sh | bash
#
# Detects OS/arch, fetches the latest release tarball from GitHub,
# installs `tracepilot` + `tracepilotd` (+ the optional `tracepilot-agent`
# local runner) to /usr/local/bin (falls back to ~/.local/bin if not
# writable), best-effort builds the runner's Docker runtime image, writes
# the runner launcher to ~/.tracepilot/scripts/, then starts the daemon.
#
# AI-usage tracking is OFF by default (runner-only: dashboard + runner
# controller, no proxy, no ~/.claude file-watchers). Pass --with-tracking
# to also run the Tracepilot usage tracker:
#   curl -fsSL .../install.sh | sh -s -- --with-tracking
set -euo pipefail

REPO="saumitra99/tracepilot-releases"
BIN_DIR_PREFERRED="/usr/local/bin"
BIN_DIR_FALLBACK="$HOME/.local/bin"

# Public defaults — no secrets. The runner token is the user's own and is
# read at launch time from ~/.tracepilot/agent-runner-token; the Claude
# OAuth token is read live from the macOS Keychain. Neither is embedded here.
TRACEPILOT_SERVER_DEFAULT="https://api.tracepilot.in"
TP_DIR="$HOME/.tracepilot"
SCRIPTS_DIR="$TP_DIR/scripts"
LAUNCHER="$SCRIPTS_DIR/start-local-runner.sh"

err() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

detect_target() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Darwin) os=darwin ;;
        Linux)  os=linux ;;
        *) err "unsupported OS: $os (build from source per README)" ;;
    esac
    case "$arch" in
        arm64|aarch64) arch=aarch64 ;;
        x86_64|amd64)  arch=x86_64 ;;
        *) err "unsupported arch: $arch" ;;
    esac

    # On Linux x86_64, use the legacy binary if glibc < 2.38.
    # The standard binary requires GLIBC_2.38 (from the ort/fastembed ONNX
    # Runtime prebuilt). The legacy binary targets glibc 2.17 and omits the
    # on-device embedder; all other features work normally.
    if [ "$os" = "linux" ] && [ "$arch" = "x86_64" ]; then
        local glibc_ver glibc_major glibc_minor
        glibc_ver=$(ldd --version 2>/dev/null | awk 'NR==1{print $NF}')
        glibc_major=$(printf '%s' "$glibc_ver" | cut -d. -f1)
        glibc_minor=$(printf '%s' "$glibc_ver" | cut -d. -f2)
        if [ -z "$glibc_major" ] || [ -z "$glibc_minor" ]; then
            info "could not detect glibc version — using legacy binary (safe default)"
            printf '%s-%s-legacy' "$arch" "$os"
            return
        fi
        if [ "$glibc_major" -lt 2 ] || { [ "$glibc_major" -eq 2 ] && [ "$glibc_minor" -lt 38 ]; }; then
            info "glibc ${glibc_ver} < 2.38 — using legacy binary (on-device embedder disabled)"
            printf '%s-%s-legacy' "$arch" "$os"
            return
        fi
    fi

    printf '%s-%s' "$arch" "$os"
}

pick_bin_dir() {
    if [ -w "$BIN_DIR_PREFERRED" ] || { [ -d "$BIN_DIR_PREFERRED" ] && sudo -n true 2>/dev/null; }; then
        echo "$BIN_DIR_PREFERRED"
    else
        mkdir -p "$BIN_DIR_FALLBACK"
        echo "$BIN_DIR_FALLBACK"
    fi
}

# install_bin <src> <bin_dir> <name>
# Mirrors the tracepilotd install pattern (sudo iff installing to a
# non-writable preferred dir).
install_bin() {
    local src="$1" bin_dir="$2" name="$3"
    if [ "$bin_dir" = "$BIN_DIR_PREFERRED" ] && [ ! -w "$bin_dir" ]; then
        sudo install -m 0755 "$src" "$bin_dir/$name"
    else
        install -m 0755 "$src" "$bin_dir/$name"
    fi
}

# Per-arch runtime image tag. Matches the daemon's runtime_image() default
# (tracepilot-agent-runtime:arm64) and the launcher we write below.
runtime_image_tag() {
    case "$(uname -m)" in
        arm64|aarch64) echo "tracepilot-agent-runtime:arm64" ;;
        *)             echo "tracepilot-agent-runtime:amd64" ;;
    esac
}

# Best-effort: build the runner's Docker runtime image from the tarball's
# runtime/ dir. Never fails the install — if Docker isn't running we print
# guidance and move on.
build_runtime_image() {
    local tmp="$1" tag
    tag="$(runtime_image_tag)"

    if [ ! -f "$tmp/runtime/Dockerfile.runtime" ]; then
        warn "runtime image build context not in this release — skipping image build"
        warn "  (older release; the runner still installs. Build the image later or upgrade.)"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        info "Docker not installed — skipping runtime image build."
        info "  Install Docker, then build it with:"
        info "    docker build -t $tag -f \"$LAUNCHER_RUNTIME_DIR/Dockerfile.runtime\" \"$LAUNCHER_RUNTIME_DIR\""
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        info "Docker is installed but not running — skipping runtime image build."
        info "  Start Docker, then re-run this installer (or build it manually):"
        info "    docker build -t $tag -f \"$LAUNCHER_RUNTIME_DIR/Dockerfile.runtime\" \"$LAUNCHER_RUNTIME_DIR\""
        return 0
    fi

    info "building runner runtime image: $tag (one-time, a few minutes)"
    if docker build -t "$tag" -f "$tmp/runtime/Dockerfile.runtime" "$tmp/runtime"; then
        info "runtime image built: $tag"
    else
        warn "runtime image build failed — the runner can still be enabled later."
        warn "  Retry manually: docker build -t $tag -f \"$LAUNCHER_RUNTIME_DIR/Dockerfile.runtime\" \"$LAUNCHER_RUNTIME_DIR\""
    fi
}

# Stash the runtime build context under ~/.tracepilot so the user can rebuild
# the image later without re-downloading the tarball.
stash_runtime_context() {
    local tmp="$1"
    [ -d "$tmp/runtime" ] || return 0
    mkdir -p "$LAUNCHER_RUNTIME_DIR"
    cp -r "$tmp/runtime/." "$LAUNCHER_RUNTIME_DIR/"
}

# Write the runner launcher that the daemon executes (resolve_script_path #3:
# ~/.tracepilot/scripts/start-local-runner.sh). It targets the INSTALLED
# tracepilot-agent binary, sources the Claude OAuth from the macOS Keychain,
# reads the runner token from ~/.tracepilot/agent-runner-token, and nohups
# the runner. No secrets are written into this file.
write_launcher() {
    local bin_dir="$1" image_tag="$2"
    mkdir -p "$SCRIPTS_DIR"
    cat > "$LAUNCHER" <<LAUNCHER_EOF
#!/usr/bin/env bash
#
# Start the Tracepilot local "--connect" agent runner (INSTALLED binary).
# Written by install.sh. Run by the daemon when you click "enable runner"
# at http://localhost:4321, or run it directly:
#
#   ~/.tracepilot/scripts/start-local-runner.sh           # start / restart
#   ~/.tracepilot/scripts/start-local-runner.sh --logs    # start, then tail
#
# Prereqs (one-time):
#   * Claude Code logged in   (token read live from the macOS Keychain)
#   * jq installed            (brew install jq)
#   * Docker running          (the runtime image is built at install time)
#   * Runner token at         ~/.tracepilot/agent-runner-token
#       -> mint it by clicking "enable runner" at http://localhost:4321
#
# Config (env overrides):
#   TRACEPILOT_SERVER       default ${TRACEPILOT_SERVER_DEFAULT}
#   TRACEPILOT_AGENT_IMAGE  default ${image_tag}
#   RUNNER_TOKEN_FILE       default \$HOME/.tracepilot/agent-runner-token

set -euo pipefail

SERVER="\${TRACEPILOT_SERVER:-${TRACEPILOT_SERVER_DEFAULT}}"
AGENT_IMAGE="\${TRACEPILOT_AGENT_IMAGE:-${image_tag}}"
RUNNER_TOKEN_FILE="\${RUNNER_TOKEN_FILE:-\$HOME/.tracepilot/agent-runner-token}"
INSTALL_BIN_DIR="${bin_dir}"
LOG=/tmp/tp-agent.log

fail() { echo "x \$*" >&2; exit 1; }

# --- locate the installed runner ------------------------------------------
# Prefer PATH; fall back to the dir install.sh installed into.
if command -v tracepilot-agent >/dev/null 2>&1; then
  AGENT_BIN="\$(command -v tracepilot-agent)"
elif [ -x "\$INSTALL_BIN_DIR/tracepilot-agent" ]; then
  AGENT_BIN="\$INSTALL_BIN_DIR/tracepilot-agent"
else
  fail "tracepilot-agent not found on PATH or in \$INSTALL_BIN_DIR — re-run the installer"
fi

# --- prereqs --------------------------------------------------------------
command -v jq    >/dev/null 2>&1 || fail "jq not found — brew install jq"
docker info       >/dev/null 2>&1 || fail "Docker not running — open Docker Desktop"
[ -f "\$RUNNER_TOKEN_FILE" ]      || fail "runner token missing at \$RUNNER_TOKEN_FILE — enable the runner from http://localhost:4321"

RUNNER_TOKEN="\$(tr -d '[:space:]' < "\$RUNNER_TOKEN_FILE")"
[ -n "\$RUNNER_TOKEN" ]           || fail "runner token file is empty — enable the runner from http://localhost:4321"

# Claude subscription OAuth — read live from the Keychain, never written to disk.
TOKEN="\$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \\
  | jq -r '.claudeAiOauth.accessToken' 2>/dev/null || true)"
[ -n "\${TOKEN:-}" ] && [ "\$TOKEN" != "null" ] \\
  || fail "no Claude OAuth in Keychain — run: claude setup-token"

# gh shim: the bundled gh may belong to an account without access to the
# target repo; forcing gh to "fail" makes the runner fall back to the hosted
# provider token for git. Harmless for GitHub repos too.
SHIM_DIR=/tmp/tp-no-gh
mkdir -p "\$SHIM_DIR"
printf '#!/bin/sh\nexit 1\n' > "\$SHIM_DIR/gh"
chmod +x "\$SHIM_DIR/gh"

# --- restart --------------------------------------------------------------
if pgrep -f "tracepilot-agent --connect" >/dev/null 2>&1; then
  echo "* stopping existing runner"
  pkill -f "tracepilot-agent --connect" || true
  sleep 1
fi

PATH="\$SHIM_DIR:\$PATH" \\
  TRACEPILOT_CONNECT=1 \\
  TRACEPILOT_SERVER="\$SERVER" \\
  TRACEPILOT_RUNNER_TOKEN="\$RUNNER_TOKEN" \\
  CLAUDE_CODE_OAUTH_TOKEN="\$TOKEN" \\
  TRACEPILOT_AGENT_IMAGE="\$AGENT_IMAGE" \\
  nohup "\$AGENT_BIN" --connect > "\$LOG" 2>&1 &

PID=\$!
sleep 2
if kill -0 "\$PID" 2>/dev/null; then
  echo "v runner started (pid=\$PID)"
  echo "  server : \$SERVER"
  echo "  image  : \$AGENT_IMAGE"
  echo "  log    : \$LOG"
else
  echo "x runner died on startup — see \$LOG:" >&2
  tail -20 "\$LOG" >&2
  exit 1
fi

if [ "\${1:-}" = "--logs" ]; then
  echo "-- tailing \$LOG (Ctrl-C to stop tail; runner keeps running) --"
  tail -f "\$LOG"
fi
LAUNCHER_EOF
    chmod +x "$LAUNCHER"
}

main() {
    command -v curl >/dev/null 2>&1 || err "curl is required"
    command -v tar  >/dev/null 2>&1 || err "tar is required"

    # Tracking choice. Default OFF (runner-only). `--with-tracking` opts into
    # the full Tracepilot usage tracker (proxy + ~/.claude watchers).
    local with_tracking=0 arg
    for arg in "$@"; do
        case "$arg" in
            --with-tracking) with_tracking=1 ;;
            *) warn "ignoring unknown argument: $arg" ;;
        esac
    done

    local target tag asset_url tmp bin_dir image_tag
    target="$(detect_target)"
    info "platform: $target"

    tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')"
    [ -n "$tag" ] || err "could not find latest release on github.com/$REPO"
    info "latest release: $tag"

    asset_url="https://github.com/$REPO/releases/download/$tag/tracepilot-$tag-$target.tar.gz"
    info "downloading $asset_url"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "$asset_url" | tar -xz -C "$tmp"

    [ -x "$tmp/tracepilot" ] || err "tracepilot binary missing in tarball"
    [ -x "$tmp/tracepilotd" ] || err "tracepilotd binary missing in tarball"

    bin_dir="$(pick_bin_dir)"
    info "installing to $bin_dir"
    install_bin "$tmp/tracepilot"  "$bin_dir" "tracepilot"
    install_bin "$tmp/tracepilotd" "$bin_dir" "tracepilotd"

    # tracepilot-agent — the local "--connect" runner. Optional for
    # back-compat with older releases that didn't ship it (warn, don't fail).
    image_tag="$(runtime_image_tag)"
    # Where the launcher (and the manual rebuild command) expect the runtime
    # build context to live after install.
    LAUNCHER_RUNTIME_DIR="$TP_DIR/runtime"
    if [ -x "$tmp/tracepilot-agent" ]; then
        info "installing tracepilot-agent (local runner)"
        install_bin "$tmp/tracepilot-agent" "$bin_dir" "tracepilot-agent"

        # Keep the runtime build context for later manual rebuilds, then
        # build the image now (best-effort) and write the launcher.
        stash_runtime_context "$tmp"
        build_runtime_image "$tmp"
        write_launcher "$bin_dir" "$image_tag"
        info "runner launcher written: $LAUNCHER"
    else
        warn "this release does not include tracepilot-agent — runner not installed."
        warn "  The daemon will still run in file-watcher mode. Upgrade for the runner."
    fi

    if [ "$bin_dir" = "$BIN_DIR_FALLBACK" ]; then
        case ":$PATH:" in
            *":$bin_dir:"*) ;;
            *) info "add $bin_dir to PATH (e.g. echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc)" ;;
        esac
    fi

    # Non-disruptive: if a daemon is already running, install the new bits but
    # leave the running process untouched — never kill/restart it from here.
    # Only start one when none is running, honoring the tracking choice.
    if pgrep -x tracepilotd >/dev/null 2>&1; then
        info "existing Tracepilot daemon detected — left running untouched; restart it yourself to pick up the new version."
    elif [ "$with_tracking" = "1" ]; then
        info "starting daemon with AI-usage tracking enabled"
        "$bin_dir/tracepilot" start || err "daemon start failed (see logs above)"
    else
        info "starting daemon (runner-only — no AI-usage tracking)"
        "$bin_dir/tracepilot" start --no-track || err "daemon start failed (see logs above)"
    fi

    info "done — open http://localhost:4321"
    if [ -x "$tmp/tracepilot-agent" ]; then
        info "to run hosted agent tasks on this machine, click \"enable runner\" in the dashboard."
        info "  prerequisites: Docker running + Claude Code logged in (run: claude setup-token)."
    fi
    info "uninstall: tracepilot uninstall"
}

main "$@"
