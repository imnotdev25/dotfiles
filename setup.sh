#!/usr/bin/env bash
# Note: macOS ships Bash 3.2, so avoid mapfile, associative arrays, and empty array expansion.
set -euo pipefail

if [[ "$EUID" -eq 0 ]]; then
    echo "Run this script as your normal user, without sudo; it will use sudo for system packages." >&2
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    echo "This installer requires sudo to install system packages and change the login shell." >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin)
        OS=macos
        ;;
    Linux)
        if [[ ! -r /etc/os-release ]]; then
            echo "Cannot identify the operating system; this installer requires macOS, Debian, or Ubuntu." >&2
            exit 1
        fi
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" ]]; then
            echo "This installer supports macOS, Debian, and Ubuntu only (found: ${ID:-unknown})." >&2
            exit 1
        fi
        OS=linux
        ;;
    *)
        echo "This installer supports macOS, Debian, and Ubuntu only (found: $(uname -s))." >&2
        exit 1
        ;;
esac

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi

# When run without a clone (bash -c "$(curl ...)"), download the rest of the repository first.
if [[ -z "$SCRIPT_DIR" || ! -f "$SCRIPT_DIR/packages/install.sh" ]]; then
    DOTFILES_REPO="${DOTFILES_REPO:-imnotdev25/dotfiles}"
    SCRIPT_DIR="$(mktemp -d)"
    trap 'rm -rf "$SCRIPT_DIR"' EXIT
    echo "Downloading $DOTFILES_REPO..."
    curl -fsSL "https://github.com/$DOTFILES_REPO/archive/HEAD.tar.gz" \
        | tar -xzf - --strip-components=1 -C "$SCRIPT_DIR"
    if [[ ! -f "$SCRIPT_DIR/packages/install.sh" ]]; then
        echo "The download from $DOTFILES_REPO does not contain packages/install.sh." >&2
        exit 1
    fi
fi

mkdir -p "$HOME/.local/bin"

# System packages (Homebrew and packages/Brewfile on macOS, apt on Debian and Ubuntu).
bash "$SCRIPT_DIR/packages/install.sh"

if [[ "$OS" == macos ]]; then
    # packages/install.sh runs in a child process, so load Homebrew's environment into this one too.
    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$brew_bin" ]]; then
            BREW="$brew_bin"
            break
        fi
    done
    eval "$("$BREW" shellenv)"

    LIST_TOOL=eza
else
    LIST_TOOL=exa
fi

export PATH="$HOME/.local/bin:$PATH"

fish -c 'curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source; and fisher install jorgebucaran/fisher'
fish -c 'fisher install jorgebucaran/nvm.fish; and nvm install latest; and set --universal nvm_default_version latest; and npm install --global --prefix "$HOME/.local" @kilocode/cli @opencode-ai/cli'
curl -fsSL https://raw.githubusercontent.com/oh-my-fish/oh-my-fish/master/bin/install | fish

FISH_CONFIG_DIR="$HOME/.config/fish"
mkdir -p "$FISH_CONFIG_DIR/conf.d" "$FISH_CONFIG_DIR/functions"
install -m 0644 "$SCRIPT_DIR"/fish/functions/*.fish "$FISH_CONFIG_DIR/functions/"
install -m 0755 "$SCRIPT_DIR/scripts/ai-chat.py" "$HOME/.local/bin/ai-chat"
if [[ -x "$HOME/.local/bin/opencode2" && ! -e "$HOME/.local/bin/opencode" ]]; then
    ln -s opencode2 "$HOME/.local/bin/opencode"
fi

GENCOMP_TOOLS="fd ag $LIST_TOOL fzf rg nano curl python3 podman tailscale tailscaled node npm nvm kilo opencode nvim lazygit"
fish -c "fish_add_path --prepend \"\$HOME/.local/bin\"; and fisher install ryotako/fish-completion-generator PatrickF1/fzf.fish; and gencomp fish $GENCOMP_TOOLS"

{
    if [[ "$OS" == macos ]]; then
        echo "$BREW shellenv | source"
    fi
    cat <<'FISH_CONFIG'
fish_add_path --prepend "$HOME/.local/bin"

set -gx FZF_DEFAULT_COMMAND 'fd --hidden --strip-cwd-prefix --exclude .git'
fzf_configure_bindings --directory=ctrl-t
FISH_CONFIG
} > "$FISH_CONFIG_DIR/conf.d/dotfiles-setup.fish"

FISH_PATH="$(command -v fish)"
if [[ "$OS" == macos ]]; then
    # macOS only allows login shells listed in /etc/shells.
    if ! grep -Fxq "$FISH_PATH" /etc/shells; then
        echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
    fi
    CURRENT_SHELL="$(dscl . -read "/Users/$USER" UserShell | awk '{print $2}')"
else
    CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
fi
if [[ "$CURRENT_SHELL" != "$FISH_PATH" ]]; then
    sudo chsh -s "$FISH_PATH" "$USER"
fi

# AstroNvim: install the starter template only when there is no existing Neovim config.
NVIM_CONFIG="$HOME/.config/nvim"
if [[ -e "$NVIM_CONFIG" ]]; then
    echo "Skipping AstroNvim: $NVIM_CONFIG already exists. Move it aside and rerun to install AstroNvim." >&2
else
    # Plugin data from a previous config can conflict with AstroNvim, so back it up.
    BACKUP_SUFFIX="bak.$(date +%Y%m%d%H%M%S)"
    for dir in "$HOME/.local/share/nvim" "$HOME/.local/state/nvim" "$HOME/.cache/nvim"; do
        if [[ -e "$dir" ]]; then
            mv "$dir" "$dir.$BACKUP_SUFFIX"
            echo "Backed up $dir to $dir.$BACKUP_SUFFIX"
        fi
    done
    git clone --depth 1 https://github.com/AstroNvim/template "$NVIM_CONFIG"
    rm -rf "$NVIM_CONFIG/.git"
    # Install plugins now so the first launch is ready to use.
    nvim --headless '+Lazy! sync' +qa \
        || echo "AstroNvim plugin sync did not finish; it will resume the next time you start nvim." >&2
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

echo "Fish, FZF, search tools, Oh My Fish, Fisher, Neovim with AstroNvim, and Nano configuration are installed."
if [[ "$OS" == macos ]]; then
    echo "Next steps on macOS:"
    echo "  - Set your terminal font to 'JetBrainsMono Nerd Font' (use iTerm2, WezTerm, Kitty, or Ghostty for true color)."
    echo "  - Run 'podman machine init && podman machine start' before using Podman."
    echo "  - Run 'sudo brew services start tailscale' and then 'tailscale up' to connect Tailscale."
fi
