#!/usr/bin/env bash
# Installs system packages: Homebrew and the Brewfile on macOS, apt packages on Debian and Ubuntu.
# Note: macOS ships Bash 3.2, so avoid mapfile, associative arrays, and empty array expansion.
set -euo pipefail

if [[ "$EUID" -eq 0 ]]; then
    echo "Run this script as your normal user, without sudo; it will use sudo for system packages." >&2
    exit 1
fi

PACKAGES_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.local/bin"

install_macos() {
    # Homebrew needs the Xcode Command Line Tools, which also provide the C compiler AstroNvim uses.
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "Install the Xcode Command Line Tools first: xcode-select --install" >&2
        exit 1
    fi

    if ! command -v brew >/dev/null 2>&1; then
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    local brew_bin
    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$brew_bin" ]]; then
            eval "$("$brew_bin" shellenv)"
            break
        fi
    done

    brew bundle --file "$PACKAGES_DIR/Brewfile"

    # Homebrew installs gdu as gdu-go because coreutils also ships a gdu (GNU du).
    # ~/.local/bin comes first in PATH, so this link makes gdu the disk usage analyzer AstroNvim expects.
    if command -v gdu-go >/dev/null 2>&1; then
        ln -sf "$(command -v gdu-go)" "$HOME/.local/bin/gdu"
    fi
}

install_linux() {
    local apt=(sudo apt-get)

    "${apt[@]}" update
    "${apt[@]}" install -y \
        fish \
        fd-find \
        silversearcher-ag \
        exa \
        fzf \
        bat \
        hexyl \
        ripgrep \
        nano \
        curl \
        python3 \
        podman \
        git \
        unzip \
        build-essential

    # Optional AstroNvim helpers are not packaged in every Debian or Ubuntu release.
    local pkg
    for pkg in lazygit gdu bottom; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            "${apt[@]}" install -y "$pkg"
        else
            echo "Skipping $pkg: not available in this release's repositories." >&2
        fi
    done

    curl -fsSL https://tailscale.com/install.sh | sh

    if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
        ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"
    fi

    # AstroNvim needs Neovim 0.11+, which is newer than the Debian and Ubuntu packages, so use the official release build.
    local nvim_arch nvim_dir
    case "$(uname -m)" in
        x86_64) nvim_arch=x86_64 ;;
        aarch64 | arm64) nvim_arch=arm64 ;;
        *)
            echo "No official Neovim build for $(uname -m)." >&2
            exit 1
            ;;
    esac
    nvim_dir="$HOME/.local/opt/nvim"
    rm -rf "$nvim_dir"
    mkdir -p "$nvim_dir"
    curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$nvim_arch.tar.gz" \
        | tar -xzf - --strip-components=1 -C "$nvim_dir"
    ln -sf "$nvim_dir/bin/nvim" "$HOME/.local/bin/nvim"
}

case "$(uname -s)" in
    Darwin) install_macos ;;
    Linux) install_linux ;;
    *)
        echo "Unsupported operating system: $(uname -s)." >&2
        exit 1
        ;;
esac
