#!/usr/bin/env bash
# install-tools.sh — install kubectl, kind, helm at the course-pinned versions.
#
# Usage:
#   ./scripts/install-tools.sh              # install missing/outdated tools to /usr/local/bin
#   PREFIX=$HOME/.local/bin ./scripts/install-tools.sh   # install to a user-writable dir
#   ./scripts/install-tools.sh --check      # just report versions and exit
#
# Idempotent: re-running is safe. Tools already at the pinned version are skipped.
# Supports Linux and macOS, on amd64 / arm64.

set -uo pipefail

# Course-pinned minimal versions --------------------------------------------
KUBECTL_VERSION="v1.36.1"
KIND_VERSION="v0.31.0"
HELM_VERSION="v4.2.0"

PREFIX="${PREFIX:-/usr/local/bin}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BLUE=""; RESET=""
fi
ok()    { echo "${GREEN}✓${RESET} $*"; }
warn()  { echo "${YELLOW}!${RESET} $*"; }
fail()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }
step()  { echo "${BLUE}▸${RESET} $*"; }

# version_ge A B → 0 if A >= B (semver-aware via `sort -V`), 1 otherwise.
# Stripping a leading "v" keeps comparisons stable regardless of how each tool
# reports its version (e.g. `v1.36.1` vs `1.36.1`).
version_ge() {
  local a="${1#v}" b="${2#v}"
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$b" ]
}

# OS / arch detection -------------------------------------------------------
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) fail "Unsupported OS: $(uname -s). Supported: Linux, macOS." ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) fail "Unsupported architecture: $(uname -m). Supported: amd64, arm64." ;;
esac

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# Install helper — picks `install` (Linux), falls back to mv+chmod (macOS) ---
install_bin() {
  local src="$1" dst="$2"
  if [ -w "$(dirname "$dst")" ]; then
    install -m 0755 "$src" "$dst" 2>/dev/null || { chmod +x "$src" && mv "$src" "$dst"; }
  else
    sudo install -m 0755 "$src" "$dst" 2>/dev/null || { chmod +x "$src" && sudo mv "$src" "$dst"; }
  fi
}

# kubectl -------------------------------------------------------------------
install_kubectl() {
  local current=""
  if command -v kubectl >/dev/null 2>&1; then
    current=$(kubectl version --client -o json 2>/dev/null | grep -oE '"gitVersion":[^,]*' | head -n1 | awk -F'"' '{print $4}')
  fi
  if [ -n "$current" ] && version_ge "$current" "$KUBECTL_VERSION"; then
    if [ "$current" = "$KUBECTL_VERSION" ]; then
      ok "kubectl ${current} already installed (matches pinned ${KUBECTL_VERSION})"
    else
      ok "kubectl ${current} already installed (newer than pinned ${KUBECTL_VERSION}; not downgrading)"
    fi
    return
  fi
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "kubectl: have '${current:-none}', need >= ${KUBECTL_VERSION}"
    return
  fi
  step "Installing kubectl ${KUBECTL_VERSION} (${OS}/${ARCH})"
  curl -fsSL --retry 3 -o "$TMPDIR/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl" \
    || fail "kubectl download failed"
  install_bin "$TMPDIR/kubectl" "$PREFIX/kubectl"
  ok "kubectl ${KUBECTL_VERSION} installed at $PREFIX/kubectl"
}

# kind ----------------------------------------------------------------------
install_kind() {
  local current=""
  if command -v kind >/dev/null 2>&1; then
    current="v$(kind version 2>/dev/null | awk '{print $2}' | sed 's/^v//')"
  fi
  if [ -n "$current" ] && version_ge "$current" "$KIND_VERSION"; then
    if [ "$current" = "$KIND_VERSION" ]; then
      ok "kind ${current} already installed (matches pinned ${KIND_VERSION})"
    else
      ok "kind ${current} already installed (newer than pinned ${KIND_VERSION}; not downgrading)"
    fi
    return
  fi
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "kind: have '${current:-none}', need >= ${KIND_VERSION}"
    return
  fi
  step "Installing kind ${KIND_VERSION} (${OS}/${ARCH})"
  curl -fsSL --retry 3 -o "$TMPDIR/kind" \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" \
    || fail "kind download failed"
  install_bin "$TMPDIR/kind" "$PREFIX/kind"
  ok "kind ${KIND_VERSION} installed at $PREFIX/kind"
}

# helm ----------------------------------------------------------------------
install_helm() {
  local current=""
  if command -v helm >/dev/null 2>&1; then
    current=$(helm version --short 2>/dev/null | awk '{print $1}' | cut -d+ -f1)
  fi
  if [ -n "$current" ] && version_ge "$current" "$HELM_VERSION"; then
    if [ "$current" = "$HELM_VERSION" ]; then
      ok "helm ${current} already installed (matches pinned ${HELM_VERSION})"
    else
      ok "helm ${current} already installed (newer than pinned ${HELM_VERSION}; not downgrading)"
    fi
    return
  fi
  if [ "$CHECK_ONLY" = "1" ]; then
    warn "helm: have '${current:-none}', need >= ${HELM_VERSION}"
    return
  fi
  step "Installing helm ${HELM_VERSION} (${OS}/${ARCH})"
  local helm_archive="helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  curl -fsSL --retry 3 -o "$TMPDIR/${helm_archive}" \
    "https://get.helm.sh/${helm_archive}" \
    || fail "helm download failed"
  tar -xzf "$TMPDIR/${helm_archive}" -C "$TMPDIR" || fail "helm extract failed"
  install_bin "$TMPDIR/${OS}-${ARCH}/helm" "$PREFIX/helm"
  ok "helm ${HELM_VERSION} installed at $PREFIX/helm"
}

# Run ----------------------------------------------------------------------
echo "Target prefix: $PREFIX"
echo "Platform:      ${OS}/${ARCH}"
[ "$CHECK_ONLY" = "1" ] && echo "Mode:          check only (no installs)"
echo

install_kubectl
install_kind
install_helm

echo
ok "Done. Run ./scripts/preflight.sh to verify your environment."
