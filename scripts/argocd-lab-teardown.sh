#!/usr/bin/env bash
# argocd-lab-teardown.sh — reverse of argocd-lab-prep.sh.
#
# Removes:
#   - the Argo CD Application (with the resources-finalizer, so synced workloads go too)
#   - the gitea-* repository Secret in argocd
#   - all Argo CD manifests installed by the prep script
#   - the gitops-demo namespace (the synced workload)
#   - the Gitea Helm release and namespace
#
# Idempotent: missing pieces are skipped quietly. Other parts of the cluster
# are left alone.

set -uo pipefail

ARGOCD_NS="${ARGOCD_NS:-argocd}"
GITEA_NS="${GITEA_NS:-gitea}"
DEMO_NS="${DEMO_NS:-gitops-demo}"
GITEA_REPO="${GITEA_REPO:-gitops-demo}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.1}"

if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BLUE=""; RESET=""
fi
ok()    { echo "${GREEN}✓${RESET} $*"; }
warn()  { echo "${YELLOW}!${RESET} $*"; }
step()  { echo; echo "${BLUE}▸${RESET} $*"; }

command -v kubectl >/dev/null || { echo "kubectl required" >&2; exit 1; }
command -v helm    >/dev/null || { echo "helm required"    >&2; exit 1; }

# 1. Argo CD Application + repo secret ---------------------------------------
step "Deleting Argo CD Application and Repository Secret"
if kubectl -n "$ARGOCD_NS" get application "$GITEA_REPO" >/dev/null 2>&1; then
  # Wait briefly for the resources-finalizer to clean up synced workloads
  kubectl -n "$ARGOCD_NS" delete application "$GITEA_REPO" --wait=true --timeout=120s \
    && ok "Application '${GITEA_REPO}' deleted" \
    || warn "Application delete returned non-zero (continuing)"
else
  ok "Application '${GITEA_REPO}' not present"
fi

kubectl -n "$ARGOCD_NS" delete secret "gitea-${GITEA_REPO}" --ignore-not-found >/dev/null
ok "Repository Secret 'gitea-${GITEA_REPO}' removed"

# 2. Argo CD itself ----------------------------------------------------------
step "Removing Argo CD installation"
if kubectl get ns "$ARGOCD_NS" >/dev/null 2>&1; then
  # Best effort: delete the same manifest the prep script applied
  kubectl delete \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    -n "$ARGOCD_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  # Then drop the namespace, which removes any leftovers (CRDs are cluster-
  # scoped and intentionally kept — uncomment below to also nuke them).
  kubectl delete namespace "$ARGOCD_NS" --wait=true --timeout=120s \
    && ok "Namespace '${ARGOCD_NS}' deleted" \
    || warn "Namespace '${ARGOCD_NS}' delete timed out (continuing)"
else
  ok "Namespace '${ARGOCD_NS}' not present"
fi

# Optional: also remove Argo CD CRDs. Default is to keep them so a future
# prep run is fast. Set ARGOCD_REMOVE_CRDS=1 to delete them.
if [ "${ARGOCD_REMOVE_CRDS:-0}" = "1" ]; then
  step "Deleting Argo CD CRDs (ARGOCD_REMOVE_CRDS=1)"
  kubectl get crd -o name 2>/dev/null \
    | grep -E '(argoproj|argo-cd)\.io' \
    | xargs -r kubectl delete --ignore-not-found >/dev/null
  ok "Argo CD CRDs removed"
fi

# 3. Gitops-demo workload namespace -----------------------------------------
step "Deleting demo namespace '${DEMO_NS}'"
kubectl delete namespace "$DEMO_NS" --ignore-not-found --wait=false >/dev/null
ok "Namespace '${DEMO_NS}' delete requested"

# 4. Gitea -------------------------------------------------------------------
step "Uninstalling Gitea"
if helm status gitea -n "$GITEA_NS" >/dev/null 2>&1; then
  helm uninstall gitea -n "$GITEA_NS" --wait >/dev/null
  ok "Gitea release uninstalled"
else
  ok "Gitea release not present"
fi

if kubectl get ns "$GITEA_NS" >/dev/null 2>&1; then
  kubectl delete namespace "$GITEA_NS" --wait=true --timeout=120s \
    && ok "Namespace '${GITEA_NS}' deleted" \
    || warn "Namespace '${GITEA_NS}' delete timed out (continuing)"
else
  ok "Namespace '${GITEA_NS}' not present"
fi

echo
ok "Teardown complete. The base training cluster is otherwise untouched."
