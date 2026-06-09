#!/usr/bin/env bash
# preflight.sh — verify the local environment is ready for the training cluster.
#
# Usage:
#   ./scripts/preflight.sh                 # generic check (all modules)
#   ./scripts/preflight.sh module-3        # module-specific extras (e.g. metrics-server, helm)
#
# Exits 0 if everything looks good, 1 if any required check fails.

set -uo pipefail

# Versions the course standardizes on. Update here when you bump the course.
KUBECTL_MIN_MINOR=35           # accept >= 1.35 (1.36 is the course default)
KIND_MIN="0.31.0"
HELM_MIN_MAJOR=4               # course uses Helm 4
KIND_NODE_IMAGE="kindest/node:v1.35.1"

# ANSI helpers (no colour outside a TTY)
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; RESET=""
fi

ok()    { echo "${GREEN}✓${RESET} $*"; }
warn()  { echo "${YELLOW}!${RESET} $*"; }
fail()  { echo "${RED}✗${RESET} $*"; FAILED=1; }

FAILED=0
MODULE="${1:-}"

# --- Tooling versions ----------------------------------------------------------

if command -v kubectl >/dev/null 2>&1; then
  KCV=$(kubectl version --client -o json 2>/dev/null | grep -oE '"gitVersion":[^,]*' | head -n1 | awk -F'"' '{print $4}')
  KCV_MINOR=$(echo "${KCV#v}" | awk -F. '{print $2}')
  if [ -n "$KCV_MINOR" ] && [ "$KCV_MINOR" -ge "$KUBECTL_MIN_MINOR" ]; then
    ok "kubectl ${KCV} (>= 1.${KUBECTL_MIN_MINOR})"
  else
    fail "kubectl ${KCV:-not found}; need >= 1.${KUBECTL_MIN_MINOR}"
  fi
else
  fail "kubectl not on PATH"
fi

if command -v kind >/dev/null 2>&1; then
  KV=$(kind version 2>/dev/null | awk '{print $2}' | sed 's/^v//')
  if [ -n "$KV" ]; then
    if [ "$(printf '%s\n' "$KIND_MIN" "$KV" | sort -V | head -n1)" = "$KIND_MIN" ]; then
      ok "kind v${KV} (>= ${KIND_MIN})"
    else
      fail "kind v${KV}; need >= ${KIND_MIN}"
    fi
  else
    fail "kind installed but version could not be parsed"
  fi
else
  fail "kind not on PATH"
fi

# Helm only required from Module 5 onwards (Cilium / Helm / kube-prom-stack).
if command -v helm >/dev/null 2>&1; then
  HV=$(helm version --short 2>/dev/null | awk '{print $1}' | sed 's/^v//')
  HV_MAJOR=$(echo "$HV" | cut -d. -f1)
  if [ -n "$HV_MAJOR" ] && [ "$HV_MAJOR" -ge "$HELM_MIN_MAJOR" ]; then
    ok "helm v${HV} (>= ${HELM_MIN_MAJOR}.x)"
  else
    warn "helm v${HV:-?} found; course expects v${HELM_MIN_MAJOR}.x. Helm 3 will work for most labs but a few examples assume v4."
  fi
else
  warn "helm not on PATH (required from Module 5 onwards)"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ok "docker daemon reachable"
else
  fail "docker daemon not reachable (kind needs it)"
fi

# --- Cluster state -------------------------------------------------------------

if kubectl cluster-info >/dev/null 2>&1; then
  CTX=$(kubectl config current-context 2>/dev/null || echo "?")
  ok "cluster reachable (context: ${CTX})"

  NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  if [ "$NODES" -gt 0 ] && [ "$NODES" = "$READY" ]; then
    ok "${NODES} node(s) Ready"
  else
    fail "${READY}/${NODES} nodes Ready"
  fi

  if kubectl get ns training >/dev/null 2>&1; then
    ok "namespace 'training' exists"
  else
    warn "namespace 'training' missing — create it with: kubectl create ns training"
  fi
else
  fail "no cluster reachable. Create one with:\n    kind create cluster --name training --config kind-config.yaml"
fi

# --- Module-specific checks ----------------------------------------------------

case "$MODULE" in
  ""|module-1|module-2)
    ;;
  module-3)
    if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
      ok "metrics-server installed (kubectl top will work)"
    else
      warn "metrics-server not installed (Module 3 'kubectl top' step). See Module 6/8 for the install snippet."
    fi
    ;;
  module-5)
    CNI=$(kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | head -n1)
    if [ -n "$CNI" ]; then
      ok "Cilium pods detected — NetworkPolicy enforcement available"
    else
      warn "Cilium not installed. NetworkPolicy section needs the kind-config-cilium.yaml profile + Cilium install (see Lab 5)."
    fi
    ;;
  module-7)
    if helm version >/dev/null 2>&1; then
      ok "helm reachable"
    else
      fail "Module 7 needs Helm — install it before starting"
    fi
    ;;
  module-8)
    if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
      ok "metrics-server installed"
    else
      warn "metrics-server not installed — install it during Exercise 3 of Lab 8."
    fi
    ;;
  *)
    warn "unknown module key '${MODULE}'. Valid: module-1 .. module-8 (or omit)."
    ;;
esac

if [ "$FAILED" = "1" ]; then
  echo
  echo "${RED}Preflight failed.${RESET} Fix the items above before continuing."
  exit 1
fi

echo
echo "${GREEN}Preflight passed.${RESET}"
exit 0
