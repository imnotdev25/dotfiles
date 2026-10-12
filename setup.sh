#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r /etc/os-release ]]; then
    echo "Cannot identify the operating system; this installer requires Debian or Ubuntu." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
    echo "This installer supports Debian and Ubuntu only (found: ${ID:-unknown})." >&2
    exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
    echo "Run this script as your normal user, without sudo; it will use sudo for system packages." >&2
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    echo "This installer requires sudo to install system packages and change the login shell." >&2
    exit 1
fi

APT=(sudo apt-get)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

"${APT[@]}" update
"${APT[@]}" install -y \
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
    podman

curl -fsSL https://tailscale.com/install.sh | sh

if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    mkdir -p "$HOME/.local/bin"
    ln -s "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi

fish -c 'curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source; and fisher install jorgebucaran/fisher'
fish -c 'fisher install jorgebucaran/nvm.fish; and nvm install latest; and set --universal nvm_default_version latest; and npm install --global --prefix "$HOME/.local" @kilocode/cli @opencode-ai/cli'
curl -fsSL https://raw.githubusercontent.com/oh-my-fish/oh-my-fish/master/bin/install | fish

FISH_CONFIG_DIR="$HOME/.config/fish"
mkdir -p "$FISH_CONFIG_DIR/conf.d" "$FISH_CONFIG_DIR/functions"
mkdir -p "$HOME/.local/bin"
install -m 0644 "$SCRIPT_DIR"/fish/functions/*.fish "$FISH_CONFIG_DIR/functions/"
install -m 0755 "$SCRIPT_DIR/scripts/ai-chat.py" "$HOME/.local/bin/ai-chat"
if [[ -x "$HOME/.local/bin/opencode2" && ! -e "$HOME/.local/bin/opencode" ]]; then
    ln -s opencode2 "$HOME/.local/bin/opencode"
fi
fish -c 'fish_add_path --prepend "$HOME/.local/bin"; and fisher install ryotako/fish-completion-generator PatrickF1/fzf.fish; and gencomp fish fd ag exa fzf rg nano curl python3 podman tailscale tailscaled node npm nvm kilo opencode'
cat > "$FISH_CONFIG_DIR/conf.d/dotfiles-setup.fish" <<'FISH_CONFIG'
fish_add_path --prepend "$HOME/.local/bin"

set -gx FZF_DEFAULT_COMMAND 'fd --hidden --strip-cwd-prefix --exclude .git'
fzf_configure_bindings --directory=ctrl-t
FISH_CONFIG

FISH_PATH="$(command -v fish)"
if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$FISH_PATH" ]]; then
    sudo chsh -s "$FISH_PATH" "$USER"
fi

curl -fsSL https://raw.githubusercontent.com/galenguyer/nano-syntax-highlighting/master/install.sh | bash

NANORC="$HOME/.nanorc"
if ! grep -Fq '# >>> dotfiles setup >>>' "$NANORC" 2>/dev/null; then
    cat >> "$NANORC" <<'NANO_CONFIG'

# >>> dotfiles setup >>>
set titlecolor brightwhite,blue
set statuscolor brightwhite,green
set errorcolor brightwhite,red
set selectedcolor brightwhite,magenta
set stripecolor ,yellow
set numbercolor cyan
set keycolor cyan
set functioncolor green
set linenumbers
set mouse
set tabstospaces
set tabsize 2
set jumpyscrolling
set autoindent
set matchbrackets "(<[{)>]}"
# <<< dotfiles setup <<<
NANO_CONFIG
fi

echo "Fish, FZF, search tools, Oh My Fish, Fisher, and Nano configuration are installed."
