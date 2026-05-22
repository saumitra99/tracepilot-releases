#!/usr/bin/env bash
# Tracepilot one-line installer.
#   curl -fsSL https://raw.githubusercontent.com/saumitra99/tracepilot-releases/main/install.sh | bash
#
# Detects OS/arch, fetches the latest release tarball from GitHub,
# installs `tracepilot` + `tracepilotd` to /usr/local/bin (falls back
# to ~/.local/bin if not writable), then starts the daemon in
# file-watcher mode (no system changes).
set -euo pipefail

REPO="saumitra99/tracepilot-releases"
BIN_DIR_PREFERRED="/usr/local/bin"
BIN_DIR_FALLBACK="$HOME/.local/bin"

err() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[32m==>\033[0m %s\n' "$*"; }

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

main() {
    command -v curl >/dev/null 2>&1 || err "curl is required"
    command -v tar  >/dev/null 2>&1 || err "tar is required"

    local target tag asset_url tmp bin_dir
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
    if [ "$bin_dir" = "$BIN_DIR_PREFERRED" ] && [ ! -w "$bin_dir" ]; then
        sudo install -m 0755 "$tmp/tracepilot"  "$bin_dir/tracepilot"
        sudo install -m 0755 "$tmp/tracepilotd" "$bin_dir/tracepilotd"
    else
        install -m 0755 "$tmp/tracepilot"  "$bin_dir/tracepilot"
        install -m 0755 "$tmp/tracepilotd" "$bin_dir/tracepilotd"
    fi

    if [ "$bin_dir" = "$BIN_DIR_FALLBACK" ]; then
        case ":$PATH:" in
            *":$bin_dir:"*) ;;
            *) info "add $bin_dir to PATH (e.g. echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc)" ;;
        esac
    fi

    info "starting daemon (file-watcher mode, no system changes)"
    "$bin_dir/tracepilot" start || err "daemon start failed (see logs above)"

    info "done — open http://localhost:4321"
    info "uninstall: tracepilot uninstall"
}

main "$@"
