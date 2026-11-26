#!/usr/bin/env sh
set -eu

SHELL_ARG="${1:-}"

find_binary() {
  if command -v locally-remote >/dev/null 2>&1; then
    command -v locally-remote
    return 0
  fi
  for candidate in \
    /opt/homebrew/bin/locally-remote \
    /usr/local/bin/locally-remote \
    "$HOME/.local/bin/locally-remote"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

BIN="$(find_binary || true)"
if [ -z "$BIN" ]; then
  echo "locally-remote binary not found on PATH or standard install locations." >&2
  exit 1
fi

if [ -n "$SHELL_ARG" ]; then
  "$BIN" completions install --shell "$SHELL_ARG"
  TARGET_SHELL="$SHELL_ARG"
else
  "$BIN" completions install
  case "${SHELL:-zsh}" in
    */fish|fish) TARGET_SHELL="fish" ;;
    */bash|bash) TARGET_SHELL="bash" ;;
    *) TARGET_SHELL="zsh" ;;
  esac
fi

# If zsh completions landed in ~/.zsh/completions, ensure ~/.zshrc loads that directory.
if [ "$TARGET_SHELL" = "zsh" ] && [ -f "$HOME/.zsh/completions/_locally-remote" ]; then
  ZSHRC="$HOME/.zshrc"
  if [ ! -f "$ZSHRC" ] || ! grep -Fq '.zsh/completions' "$ZSHRC"; then
    {
      echo ""
      echo "# Added by locally-remote completions installer"
      echo 'fpath=("$HOME/.zsh/completions" $fpath)'
      echo 'autoload -Uz compinit && compinit'
    } >> "$ZSHRC"
    echo "Updated $ZSHRC to include ~/.zsh/completions in fpath."
  fi
fi
