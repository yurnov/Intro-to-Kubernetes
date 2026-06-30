#!/usr/bin/env bash
# argocd-lab-prep.sh — stand up Gitea + Argo CD on the training kind cluster.
#
# What this does (idempotent — safe to re-run):
#   1. Verifies kubectl, helm, and a reachable cluster.
#   2. Installs Gitea v12.5.3 (chart) in `gitea/` namespace, SQLite mode, no persistence.
#      Admin user: labuser / labuser-pass (override via env).
#   3. Seeds a sample Git repo `labuser/gitops-demo` via the Gitea HTTP API
#      with a Deployment + Service so Argo CD has something to sync.
#   4. Installs Argo CD v3.4.1 in `argocd/`.
#   5. Registers an Argo CD Repository Secret pointing at the in-cluster
#      Gitea URL with the user's credentials.
#   6. Creates an Argo CD Application `gitops-demo` set to auto-sync.
#   7. Prints the URLs and port-forward commands you need on lab day.
#
# Usage:
#   ./scripts/argocd-lab-prep.sh
#   GITEA_USER=foo GITEA_PASS='secret-pass' ./scripts/argocd-lab-prep.sh
#
# Tear down with: ./scripts/argocd-lab-teardown.sh

set -uo pipefail

# Pinned versions ----------------------------------------------------------
GITEA_CHART_VERSION="${GITEA_CHART_VERSION:-12.5.3}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.1}"

# Tunable defaults ---------------------------------------------------------
GITEA_USER="${GITEA_USER:-labuser}"
GITEA_PASS="${GITEA_PASS:-labuser-pass}"
GITEA_EMAIL="${GITEA_EMAIL:-labuser@training.local}"
GITEA_REPO="${GITEA_REPO:-gitops-demo}"
GITEA_NS="${GITEA_NS:-gitea}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
DEMO_NS="${DEMO_NS:-gitops-demo}"

# In-cluster URL Argo CD uses to reach Gitea
GITEA_INCLUSTER_URL="http://gitea-http.${GITEA_NS}.svc.cluster.local:3000"
GITEA_REPO_URL="${GITEA_INCLUSTER_URL}/${GITEA_USER}/${GITEA_REPO}.git"

if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BLUE=""; RESET=""
fi
ok()    { echo "${GREEN}✓${RESET} $*"; }
warn()  { echo "${YELLOW}!${RESET} $*"; }
fail()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }
step()  { echo; echo "${BLUE}▸${RESET} $*"; }

cleanup_pf() {
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
  PF_PID=""
}
trap cleanup_pf EXIT

# Cross-platform base64 (no line wrapping) ---------------------------------
b64() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

# 1. Prerequisites ---------------------------------------------------------
step "Checking prerequisites"
command -v kubectl >/dev/null || fail "kubectl not on PATH (run scripts/install-tools.sh)"
command -v helm    >/dev/null || fail "helm not on PATH (run scripts/install-tools.sh)"
command -v curl    >/dev/null || fail "curl is required"
kubectl cluster-info >/dev/null 2>&1 || fail "no Kubernetes cluster reachable"
ok "kubectl, helm, curl, and cluster reachable"

# 2. Install Gitea ---------------------------------------------------------
step "Installing Gitea v${GITEA_CHART_VERSION} into namespace '${GITEA_NS}' (SQLite mode)"
helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null 2>&1 || true
helm repo update gitea-charts >/dev/null

if helm status gitea -n "$GITEA_NS" >/dev/null 2>&1; then
  ok "Gitea release already exists — skipping helm install"
else
  helm install gitea gitea-charts/gitea \
    --version "$GITEA_CHART_VERSION" \
    -n "$GITEA_NS" --create-namespace \
    --set "gitea.admin.username=${GITEA_USER}" \
    --set "gitea.admin.password=${GITEA_PASS}" \
    --set "gitea.admin.email=${GITEA_EMAIL}" \
    --set "valkey-cluster.enabled=false" \
    --set "valkey.enabled=false" \
    --set "postgresql.enabled=false" \
    --set "postgresql-ha.enabled=false" \
    --set "persistence.enabled=false" \
    --set "gitea.config.database.DB_TYPE=sqlite3" \
    --set "gitea.config.session.PROVIDER=memory" \
    --set "gitea.config.cache.ADAPTER=memory" \
    --set "gitea.config.queue.TYPE=level" \
    --wait --timeout 5m
  ok "Gitea installed"
fi

step "Waiting for Gitea Pod to become Ready"
kubectl -n "$GITEA_NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=gitea --timeout=180s
ok "Gitea is Ready"

# 3. Seed the Git repo via the Gitea API ----------------------------------
step "Port-forwarding Gitea (localhost:3000)"
kubectl -n "$GITEA_NS" port-forward svc/gitea-http 3000:3000 >/dev/null 2>&1 &
PF_PID=$!
# Wait until the API answers
for i in $(seq 1 30); do
  if curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" http://localhost:3000/api/v1/version >/dev/null 2>&1; then
    ok "Gitea API reachable at http://localhost:3000"
    break
  fi
  sleep 2
  [ "$i" = "30" ] && fail "Gitea API did not respond after 60s"
done

step "Ensuring repo '${GITEA_USER}/${GITEA_REPO}' exists"
http_code=$(curl -s -o /dev/null -w '%{http_code}' \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  "http://localhost:3000/api/v1/repos/${GITEA_USER}/${GITEA_REPO}")
if [ "$http_code" = "200" ]; then
  ok "Repo already exists — leaving content untouched"
  REPO_EXISTS=1
else
  curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -X POST http://localhost:3000/api/v1/user/repos \
    -d "{\"name\":\"${GITEA_REPO}\",\"description\":\"GitOps demo for Module 7\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" \
    >/dev/null
  ok "Repo created with auto_init"
  REPO_EXISTS=0
fi

# Helper to upload (or replace) a file via API ----------------------------
push_file() {
  local path="$1" content="$2" message="$3"
  local payload existing_sha existing_resp
  # GET existing file to detect prior content (lets us PUT with a sha)
  existing_resp=$(curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
    "http://localhost:3000/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/contents/${path}" 2>/dev/null || true)
  existing_sha=$(echo "$existing_resp" | grep -oE '"sha":[^,]*' | head -n1 | awk -F'"' '{print $4}')
  payload=$(printf '{"content":"%s","message":"%s","branch":"main"%s}' \
    "$(printf '%s' "$content" | b64)" \
    "$message" \
    "${existing_sha:+,\"sha\":\"${existing_sha}\"}")
  local method=POST
  [ -n "$existing_sha" ] && method=PUT
  curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -X "$method" \
    "http://localhost:3000/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/contents/${path}" \
    -d "$payload" >/dev/null
}

if [ "$REPO_EXISTS" = "0" ]; then
  step "Seeding initial manifests"

  push_file "README.md" \
"# GitOps demo

This repo is the source of truth for the Argo CD Application '${DEMO_NS}'.
Edit \`deployment.yaml\` or \`service.yaml\`, push to main, and watch Argo CD
sync within seconds.
" "Initial README"

  push_file "deployment.yaml" \
"apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitops-demo
  namespace: ${DEMO_NS}
  labels:
    app: gitops-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: gitops-demo
  template:
    metadata:
      labels:
        app: gitops-demo
    spec:
      containers:
      - name: app
        image: hashicorp/http-echo:0.2.3
        args:
        - -text=Hello from GitOps!
        - -listen=:5678
        ports:
        - containerPort: 5678
        resources:
          requests: {cpu: 25m, memory: 32Mi}
          limits:   {cpu: 50m, memory: 64Mi}
" "Add demo Deployment"

  push_file "service.yaml" \
"apiVersion: v1
kind: Service
metadata:
  name: gitops-demo
  namespace: ${DEMO_NS}
spec:
  type: ClusterIP
  selector:
    app: gitops-demo
  ports:
  - port: 80
    targetPort: 5678
" "Add demo Service"

  ok "Seeded README.md, deployment.yaml, service.yaml on main"
fi

cleanup_pf

# 4. Install Argo CD ------------------------------------------------------
step "Installing Argo CD ${ARGOCD_VERSION} into namespace '${ARGOCD_NS}'"
kubectl get ns "$ARGOCD_NS" >/dev/null 2>&1 || kubectl create namespace "$ARGOCD_NS"
kubectl apply -n "$ARGOCD_NS" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
ok "Argo CD manifests applied"

step "Waiting for Argo CD components to roll out"
for d in argocd-server argocd-repo-server argocd-redis argocd-dex-server argocd-notifications-controller; do
  kubectl -n "$ARGOCD_NS" rollout status "deploy/$d" --timeout=180s >/dev/null 2>&1 || warn "$d not Ready (continuing)"
done
kubectl -n "$ARGOCD_NS" rollout status statefulset/argocd-application-controller --timeout=180s >/dev/null
ok "Argo CD ready"

# 5. Register the Gitea repo with Argo CD ---------------------------------
step "Registering the Gitea repository with Argo CD"
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: gitea-${GITEA_REPO}
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${GITEA_REPO_URL}
  username: ${GITEA_USER}
  password: ${GITEA_PASS}
EOF
ok "Repository Secret created"

# 6. Argo CD Application --------------------------------------------------
step "Creating Argo CD Application '${GITEA_REPO}'"
kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${GITEA_REPO}
  namespace: ${ARGOCD_NS}
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITEA_REPO_URL}
    targetRevision: HEAD
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: ${DEMO_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
ok "Application created"

# 7. Summary --------------------------------------------------------------
ARGOCD_PASS=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

cat <<EOF

${GREEN}━━━ ArgoCD lab is ready ━━━${RESET}

  Gitea
    in-cluster URL : ${GITEA_INCLUSTER_URL}
    web (port-fwd) : kubectl -n ${GITEA_NS} port-forward svc/gitea-http 3000:3000
                     → http://localhost:3000
    user / pass    : ${GITEA_USER} / ${GITEA_PASS}
    repo           : ${GITEA_USER}/${GITEA_REPO}  (branch: main)

  Argo CD
    web (port-fwd) : kubectl -n ${ARGOCD_NS} port-forward svc/argocd-server 8080:443
                     → https://localhost:8080  (accept self-signed cert)
    user / pass    : admin / ${ARGOCD_PASS:-<read with: kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d>}

  Application
    name           : ${GITEA_REPO}  (auto-sync, prune, self-heal enabled)
    target ns      : ${DEMO_NS}

  Try a sync demo
    1. Edit deployment.yaml in Gitea (e.g. bump replicas to 3)
    2. Watch Argo CD reconcile within ~60s:
         kubectl -n ${ARGOCD_NS} get app ${GITEA_REPO} -w
    3. Or break drift:
         kubectl -n ${DEMO_NS} scale deploy/gitops-demo --replicas=5
       and watch self-heal pull it back.

  Tear down with: scripts/argocd-lab-teardown.sh
EOF
