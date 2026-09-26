#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

link() {
  local src="$DOTFILES_DIR/$1"
  local dst="$HOME/$2"

  mkdir -p "$(dirname "$dst")"

  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "Backing up existing $dst -> ${dst}.bak"
    mv "$dst" "${dst}.bak"
  fi

  ln -sf "$src" "$dst"
  echo "Linked $dst"
}

link git/gitconfig .gitconfig
link tmux/tmux.conf .tmux.conf
link vim/vimrc .vimrc
link bash/bashrc .bashrc
link bash/bash_profile .bash_profile
