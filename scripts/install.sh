#!/usr/bin/env sh
set -eu

REPO="Nailington/Locally-Remote"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
TAG="${1:-}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "locally-remote only runs on macOS." >&2
  exit 1
fi

if [ -z "$TAG" ]; then
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
fi

if [ -z "$TAG" ]; then
  echo "Could not resolve latest release tag from GitHub." >&2
  exit 1
fi

VERSION="${TAG#v}"
TAR_NAME="locally-remote-${VERSION}-macos-universal.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

echo "Downloading ${TAR_NAME} (${TAG})..."
curl -fsSL "${BASE_URL}/${TAR_NAME}" -o "${TMPDIR_WORK}/${TAR_NAME}"
curl -fsSL "${BASE_URL}/SHA256SUMS.txt" -o "${TMPDIR_WORK}/SHA256SUMS.txt"

EXPECTED="$(awk -v f="${TAR_NAME}" '$2 == f {print $1}' "${TMPDIR_WORK}/SHA256SUMS.txt")"
ACTUAL="$(shasum -a 256 "${TMPDIR_WORK}/${TAR_NAME}" | awk '{print $1}')"

if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "Checksum verification failed for ${TAR_NAME}." >&2
  exit 1
fi

tar -xzf "${TMPDIR_WORK}/${TAR_NAME}" -C "${TMPDIR_WORK}"
mkdir -p "${INSTALL_DIR}"
cp "${TMPDIR_WORK}/locally-remote-${VERSION}-macos-universal/locally-remote" "${INSTALL_DIR}/locally-remote.new"
chmod 0755 "${INSTALL_DIR}/locally-remote.new"
mv -f "${INSTALL_DIR}/locally-remote.new" "${INSTALL_DIR}/locally-remote"

echo "Installed locally-remote ${VERSION} to ${INSTALL_DIR}/locally-remote"
