# Lab 5: Networking — DNS, Gateway API, and NetworkPolicies

> **Duration:** 30 min  
> **Prerequisites:** Module 5 theory, working `kind` + `helm` install (you'll recreate the cluster with Cilium in "Before You Begin")

## Objectives

1. Explore DNS-based service discovery across namespaces
2. Implement NetworkPolicies to control Pod-to-Pod traffic
3. *(Optional)* Install Gateway API CRDs + Envoy Gateway and route with HTTPRoute

## Before You Begin

NetworkPolicy enforcement (Exercise 2) requires a CNI that implements policy — kind's default `kindnet` does **not**. To keep the whole lab on one cluster, recreate the training cluster with the bundled Cilium profile up front. DNS (Exercise 1) and Gateway API (Exercise 3) work identically on Cilium, so a single recreate covers all three exercises.

> **⚠️ This step replaces your previous `training` cluster.** Anything you built in Labs 1–4 will be lost. If you want to preserve those resources, run this lab on a separate cluster name (`--name training-networkpolicy`) and switch context — every command below uses the default context.

```bash
# Tear down the previous cluster
kind delete cluster --name training 2>/dev/null

# Bring up a fresh cluster with the default CNI disabled
kind create cluster --name training --config kind-config-cilium.yaml

# (Optional but fast) Pre-load the Cilium image to skip a large pull
docker pull quay.io/cilium/cilium:v1.19.3
kind load docker-image quay.io/cilium/cilium:v1.19.3 --name training

# Install Cilium via Helm
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --version 1.19.3 \
  --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes

# Wait for Cilium to be Ready (1–2 minutes)
kubectl wait --for=condition=Ready pod -l k8s-app=cilium -n kube-system --timeout=180s

# Create the namespace + default context for the rest of the lab
kubectl create namespace training
kubectl config set-context --current --namespace=training

# Sanity check — nodes Ready, Cilium running, no kindnet Pods
kubectl get nodes -o wide
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system get pods -l app=kindnet 2>/dev/null  # expected: No resources found
```

> **⏱️ Time check:** Exercise 1 (DNS) and Exercise 2 (NetworkPolicies) are core (~25 min on a pre-warmed cluster). Exercise 3 (Gateway API + Envoy Gateway install) is **optional / take-home** because the install + readiness wait alone consumes most of the lab budget.

---

## Exercise 1: DNS and Service Discovery

In this exercise, you'll deploy applications across namespaces and explore how Kubernetes DNS enables service discovery.

### Step 1: Deploy Web App A in the Training Namespace

Create the Deployment and Service for app A:

```bash
kubectl apply -f manifests/web-app-a.yaml
```

Verify the Deployment is running:

```bash
kubectl get deployments -n training
kubectl get services -n training
```

Expected output:
```
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
web-app-a   2/2     2            2           30s

NAME        TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web-app-a   ClusterIP   10.96.x.x      <none>        80/TCP    30s
```

### Step 2: Deploy Web App B in a Separate Namespace

App B is deployed in the `app-b` namespace to demonstrate cross-namespace DNS:

```bash
kubectl apply -f manifests/web-app-b.yaml
```

Verify:

```bash
kubectl get deployments -n app-b
kubectl get services -n app-b
```

Expected output:
```
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
web-app-b   2/2     2            2           30s

NAME        TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web-app-b   ClusterIP   10.96.x.x      <none>        80/TCP    30s
```

### Step 3: Deploy a Debug Pod

Launch a Pod with networking tools for DNS exploration:

```bash
kubectl apply -f manifests/debug-netshoot.yaml
```

Wait for it to be ready:

```bash
kubectl wait --for=condition=Ready pod/netshoot-debug -n training --timeout=60s
```

### Step 4: Explore DNS Resolution

Open a shell in the debug Pod:

```bash
kubectl exec -it netshoot-debug -n training -- bash
```

Inside the Pod, test DNS resolution:

```bash
# 1. Resolve a Service in the SAME namespace (short name works)
nslookup web-app-a
```

Expected output:
```
Server:    10.96.0.10
Address:   10.96.0.10#53

Name:   web-app-a.training.svc.cluster.local
Address: 10.96.x.x
```

```bash
# 2. Resolve a Service in a DIFFERENT namespace (must use at least <svc>.<ns>)
nslookup web-app-b.app-b
```

Expected output:
```
Server:    10.96.0.10
Address:   10.96.0.10#53

Name:   web-app-b.app-b.svc.cluster.local
Address: 10.96.x.x
```

```bash
# 3. Try the full FQDN
nslookup web-app-b.app-b.svc.cluster.local
```

```bash
# 4. Verify a short name from a DIFFERENT namespace does NOT resolve
nslookup web-app-b
```

This should fail — short names only work within the same namespace.

```bash
# 5. Test connectivity
curl -s web-app-a
curl -s web-app-b.app-b
```

You should see responses like `"web-app-a"` and `"web-app-b"` respectively.

### Step 5: Examine /etc/resolv.conf

Still inside the debug Pod:

```bash
cat /etc/resolv.conf
```

Expected output:
```
nameserver 10.96.0.10
search training.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

Notice how the `search` line includes `training.svc.cluster.local` — this is why short names like `web-app-a` resolve within the `training` namespace.

```bash
# Exit the debug Pod
exit
```

### Step 6: Query CoreDNS Directly

You can also query CoreDNS from outside a Pod if you know the CoreDNS Service IP:

```bash
# Find the CoreDNS Service IP
kubectl get service kube-dns -n kube-system
```

Expected output:
```
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   Xd
```

> **💡 Tip:** CoreDNS Service is always called `kube-dns` for backward compatibility with the older kube-dns component, even though CoreDNS runs behind it.

---

## Exercise 2: NetworkPolicies

You're already on the Cilium cluster set up in "Before You Begin", so NetworkPolicy enforcement works out of the box. In this exercise, you'll implement firewall rules for Pod traffic using core `NetworkPolicy` resources.

> **💡 Tip:** Cilium also ships its own L7 `CiliumNetworkPolicy` CRD if you want to filter by HTTP method or path — out of scope here, but worth a look after the course.

### Step 1: Deploy Frontend and Backend Pods

Create a simple frontend, backend, and a "rogue" Pod to exercise the policies. The frontend uses `nicolaka/netshoot` so we have `wget`/`curl` available without `kubectl exec` gymnastics.

```bash
# Backend — http-echo answers any request with a fixed string on :5678
kubectl run backend --image=hashicorp/http-echo:0.2.3 \
  --labels="role=backend" \
  --port=5678 \
  -n training \
  -- -text="Hello from backend" -listen=:5678

# Backend Service
kubectl expose pod backend --port=5678 --name=backend -n training

# Frontend — netshoot, so we can curl/wget the backend
kubectl run frontend --image=nicolaka/netshoot:v0.14 \
  --labels="role=frontend" \
  -n training \
  -- sleep 3600

# Rogue Pod — also netshoot, simulates an unauthorized client
kubectl run rogue --image=nicolaka/netshoot:v0.14 \
  --labels="role=rogue" \
  -n training \
  -- sleep 3600
```

Wait for all Pods to be running:

```bash
kubectl get pods -n training --show-labels
```

Expected output:
```
NAME       READY   STATUS    RESTARTS   AGE   LABELS
backend    1/1     Running   0          30s   role=backend
frontend   1/1     Running   0          20s   role=frontend
rogue      1/1     Running   0          10s   role=rogue
...
```

### Step 2: Verify Open Communication (Default Behavior)

By default, all Pods can communicate freely:

```bash
# Frontend can reach backend
kubectl exec frontend -n training -- curl -s --max-time 3 http://backend:5678

# Rogue can also reach backend (this is the problem!)
kubectl exec rogue -n training -- curl -s --max-time 3 http://backend:5678
```

Expected output (both should succeed):
```
Hello from backend
```

### Step 3: Apply Default Deny NetworkPolicy

Block all ingress traffic to Pods in the training namespace:

```bash
kubectl apply -f manifests/networkpolicy-default-deny.yaml
```

Verify the policy was created:

```bash
kubectl get networkpolicies -n training
```

Expected output:
```
NAME                   POD-SELECTOR   AGE
default-deny-ingress   <none>         10s
```

### Step 4: Verify Communication is Blocked

Now test connectivity — all traffic should be blocked:

```bash
# Frontend to backend — should FAIL (timeout)
kubectl exec frontend -n training -- curl -s --max-time 3 http://backend:5678 || echo "blocked as expected"
```

Expected behaviour: the curl times out after 3 seconds and returns a non-zero exit code; the `|| echo` fallback prints `blocked as expected`.

```bash
# Rogue to backend — should also FAIL
kubectl exec rogue -n training -- curl -s --max-time 3 http://backend:5678 || echo "blocked as expected"
```

> **🔑 Key Concept:** The default-deny policy selects ALL Pods (`podSelector: {}`) and specifies no ingress rules, which means no incoming traffic is allowed for any Pod in the namespace.

### Step 5: Allow Frontend to Backend Traffic

Apply a policy that specifically allows frontend Pods to reach the backend:

```bash
kubectl apply -f manifests/networkpolicy-allow-frontend.yaml
```

Verify:

```bash
kubectl get networkpolicies -n training
```

Expected output:
```
NAME                      POD-SELECTOR     AGE
default-deny-ingress      <none>           2m
allow-frontend-to-backend role=backend     10s
```

### Step 6: Test Selective Communication

```bash
# Frontend to backend — should SUCCEED now
kubectl exec frontend -n training -- curl -s --max-time 3 http://backend:5678
```

Expected output:
```
Hello from backend
```

```bash
# Rogue to backend — should still FAIL
kubectl exec rogue -n training -- curl -s --max-time 3 http://backend:5678 || echo "blocked as expected"
```

> **🔑 Key Concept:** NetworkPolicies are additive. The `allow-frontend-to-backend` policy added an ingress rule for the backend Pod, allowing traffic specifically from Pods labeled `role=frontend`. The rogue Pod doesn't match that label, so it's still blocked by the default deny policy.

### Step 7: Examine the Policies

Inspect the allow policy to understand its structure:

```bash
kubectl describe networkpolicy allow-frontend-to-backend -n training
```

Look at:
- **PodSelector:** which Pods this policy applies to (backend)
- **Allowing ingress:** from which Pods (frontend) on which ports (5678)

---

## Exercise 3 (Optional): Gateway API and Routing

> **📝 Note:** This exercise installs Envoy Gateway (which bundles the Gateway API CRDs). Together they take 3–5 minutes to come up on a kind cluster, plus the time to apply routing resources. Skip during the timed lab and revisit at home — or have the instructor demo it.

### Step 1: Install Envoy Gateway (CRDs included)

The Envoy Gateway Helm chart bundles a compatible set of Gateway API CRDs in its `crds/` directory, so a single `helm install` installs both the CRDs and the controller. Do **not** apply the upstream `gateway-api` CRDs separately — installing a newer Gateway API release alongside an older Envoy Gateway version is a common source of `no matches for kind "GRPCRoute" in version "gateway.networking.k8s.io/v1alpha2"` errors.

> **⚠️ The chart does NOT create a `GatewayClass`.** A `Gateway` only gets reconciled if a `GatewayClass` ties it to the controller; without one the controller logs `no accepted gatewayclass` and the Gateway never programs. The lab's `manifests/gateway-routing.yaml` creates the `envoy-gateway` GatewayClass for you (applied in Step 3), so there's nothing extra to do here — just be aware of why it's there.

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.5.9 \
  -n envoy-gateway-system \
  --create-namespace
```

Wait for Envoy Gateway to be ready:

```bash
kubectl wait --for=condition=Available deployment/envoy-gateway \
  -n envoy-gateway-system \
  --timeout=180s
```

### Step 2: Verify the Backend Applications

Make sure both web applications are running:

```bash
kubectl get pods -n training
kubectl get services -n training
```

Both `web-app-a` Pods should be running in the `training` namespace.

### Step 3: Create the Gateway and HTTPRoute

Apply the Gateway API manifest with path-based routing. This single file creates
the `GatewayClass`, the `Gateway`, the `HTTPRoute`, and a `ReferenceGrant` (so the
route can reach `web-app-b` in the `app-b` namespace):

```bash
kubectl apply -f manifests/gateway-routing.yaml
```

Verify the resources were created:

```bash
kubectl get gatewayclass
kubectl get gateway -n envoy-gateway-system
kubectl get httproute -n training
```

Expected output:
```
NAME            CONTROLLER                                      ACCEPTED   AGE
envoy-gateway   gateway.envoyproxy.io/gatewayclass-controller   True       30s

NAME               CLASS           ADDRESS   PROGRAMMED   AGE
training-gateway   envoy-gateway             False        30s

NAME             HOSTNAMES   AGE
web-app-routing              30s
```

> **📝 Why `PROGRAMMED` is `False` on kind.** Envoy Gateway exposes its data plane
> through a `LoadBalancer` Service. kind has no cloud load-balancer, so that Service
> stays `<pending>` and the Gateway reports `Programmed=False (AddressNotAssigned)`.
> This is expected here and does **not** stop routing — the data-plane Pod is created
> and serves traffic, which is exactly why the next step uses `port-forward` instead
> of the Gateway's external address. (In a real cloud cluster, or with MetalLB
> installed, an address is assigned and `PROGRAMMED` flips to `True`.)

### Step 4: Test Path-Based Routing

Find the generated Envoy service and port-forward it locally:

```bash
export ENVOY_SERVICE=$(kubectl get svc -n envoy-gateway-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^envoy-' | head -n1)
kubectl -n envoy-gateway-system port-forward service/$ENVOY_SERVICE 8888:80
```

In a second terminal, test routing to each application:

```bash
# Route to app A via /app-a
curl -s http://localhost:8888/app-a
```

Expected output:
```
"web-app-a"
```

```bash
# Route to app B via /app-b
curl -s http://localhost:8888/app-b
```

Expected output:
```
"web-app-b"
```

> **⚠️ If `/app-a` hangs or returns nothing while `/app-b` works:** you're seeing
> the `default-deny-ingress` policy from Exercise 2 in action. It selects **every**
> Pod in the `training` namespace, so it blocks the Gateway from reaching `web-app-a`
> there — but `web-app-b` lives in the unguarded `app-b` namespace and is unaffected.
> This is a great real-world illustration of how an overly broad NetworkPolicy
> silently breaks connectivity. To confirm that's the cause and unblock routing:
>
> ```bash
> # Temporarily open up the namespace (DEV ONLY — see Troubleshooting below)
> kubectl apply -f manifests/networkpolicy-allow-all-troubleshooting.yaml
> curl -s http://localhost:8888/app-a          # now returns "web-app-a"
> kubectl delete -f manifests/networkpolicy-allow-all-troubleshooting.yaml
> ```
>
> The proper fix is a scoped ingress policy that allows the Gateway's Pods to reach
> `web-app-a`, rather than leaving the namespace wide open.

> **📝 Note:** The canonical `kind-config.yaml` already includes the host port mappings and `ingress-ready=true` label used elsewhere in the course. This lab still uses port-forward because Envoy Gateway generates its local data-plane Service name dynamically.

### Step 5: Inspect the Route

Examine the HTTPRoute in detail:

```bash
kubectl describe httproute web-app-routing -n training
```

Look for:
- **ParentRefs:** the attached Gateway
- **Rules:** path-to-Service mapping
- **BackendRefs:** cross-namespace backend routing

---

## Verification

Confirm all lab exercises completed successfully:

```bash
# 1. DNS resolution works across namespaces
kubectl exec netshoot-debug -n training -- nslookup web-app-b.app-b.svc.cluster.local

# 2. Gateway API routing is configured
kubectl get gateway -n envoy-gateway-system
kubectl get httproute -n training

# 3. NetworkPolicies are in place
kubectl get networkpolicies -n training
# Expected: default-deny-ingress and allow-frontend-to-backend

# 4. Frontend can reach backend, rogue cannot
kubectl exec frontend -n training -- curl -s --max-time 3 http://backend:5678
```

---

## Troubleshooting: NetworkPolicy Connectivity

A **misconfigured or forgotten NetworkPolicy is one of the most common causes of
"my Pod can't reach X"** in Kubernetes — and one of the most confusing, because the
API server still happily *accepts* the broken policy. There's no error; traffic just
silently disappears. You saw this exact failure mode in Exercise 3, where the
Exercise 2 `default-deny-ingress` quietly blocked the Gateway from reaching
`web-app-a`.

A few things that make NetworkPolicies easy to get wrong:

- **Policies are additive and default-deny is sticky.** Once *any* policy selects a
  Pod for a given direction (Ingress/Egress), everything not explicitly allowed is
  denied. A single broad `default-deny` plus a forgotten allow rule = blackout.
- **Selectors must match exactly.** A typo in a `podSelector`/`namespaceSelector`
  label, or the wrong port/protocol, silently drops the traffic you meant to allow.
- **Egress is easy to forget.** A default-deny-egress policy that doesn't allow DNS
  (port 53 to `kube-system`) breaks name resolution for every Pod it selects.

### The "allow-all" diagnostic

When you suspect a NetworkPolicy is the culprit, temporarily **open up the whole
namespace** and see if connectivity returns. If it does, you've confirmed the
problem is policy-related and can narrow it down to a properly scoped allow rule.

```bash
# DEV / TROUBLESHOOTING ONLY — opens ALL ingress + egress for every Pod
kubectl apply -f manifests/networkpolicy-allow-all-troubleshooting.yaml

# ...re-test the connection that was failing...

# Lock the namespace back down the moment you're done
kubectl delete -f manifests/networkpolicy-allow-all-troubleshooting.yaml
```

> **🚨 Never leave `allow-all` in production.** It disables NetworkPolicy enforcement
> for the entire namespace — the security equivalent of `chmod 777`. It's a
> *diagnostic to confirm the cause*, not a fix. The fix is always a narrowly scoped
> allow policy. Treat any `allow-all` policy in a prod cluster as an incident.

Other quick checks when traffic is being dropped:

```bash
# List every policy that could be affecting the namespace
kubectl get networkpolicies -n training

# See exactly which Pods a policy selects and what it allows
kubectl describe networkpolicy <name> -n training

# Confirm the source/target Pods actually carry the labels your selectors expect
kubectl get pods -n training --show-labels
```

---

## Cleanup

Remove all resources created during this lab:

```bash
# Delete resources in training namespace
kubectl delete pod frontend backend rogue netshoot-debug -n training --ignore-not-found
kubectl delete service backend -n training --ignore-not-found
kubectl delete -f manifests/ -n training --ignore-not-found

# Delete Gateway API routing resources and Envoy Gateway
# (gateway-routing.yaml also removes the cluster-scoped `envoy-gateway` GatewayClass —
#  deleting namespaces alone would leave it dangling)
kubectl delete -f manifests/gateway-routing.yaml --ignore-not-found
kubectl delete -f manifests/networkpolicy-allow-all-troubleshooting.yaml --ignore-not-found
helm uninstall eg -n envoy-gateway-system 2>/dev/null
kubectl delete namespace envoy-gateway-system --ignore-not-found

# Delete the app-b namespace (and everything in it)
kubectl delete namespace app-b --ignore-not-found

# Delete NetworkPolicies
kubectl delete networkpolicies --all -n training --ignore-not-found
```

Or delete and recreate the namespace:

```bash
kubectl delete namespace training
kubectl create namespace training
```

---

## Bonus Challenges

### Challenge 1: Comprehensive NetworkPolicy Setup

Create a complete security setup for a three-tier application:

1. **Default deny** all ingress and egress in the `training` namespace
2. Allow **frontend → backend** on port 8080
3. Allow **backend → database** on port 5432
4. Allow **all Pods → CoreDNS** (port 53 UDP/TCP in `kube-system` namespace)

<details>
<summary>💡 Hint</summary>

You need four policies:
1. Default deny (both ingress and egress)
2. An ingress policy on the backend allowing from frontend
3. An ingress policy on the database allowing from backend
4. An egress policy on all Pods allowing DNS (port 53) to the `kube-system` namespace

For the DNS egress rule, use a `namespaceSelector` to target `kube-system`:
```yaml
egress:
- to:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: kube-system
  ports:
  - protocol: UDP
    port: 53
  - protocol: TCP
    port: 53
```
</details>

<details>
<summary>✅ Solution</summary>

```yaml
# 1. Default deny all
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: training
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
# 2. Allow DNS for all Pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: training
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
---
# 3. Allow frontend → backend
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-frontend
  namespace: training
spec:
  podSelector:
    matchLabels:
      role: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    ports:
    - protocol: TCP
      port: 8080
---
# 4. Allow backend → database
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-allow-backend
  namespace: training
spec:
  podSelector:
    matchLabels:
      role: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: backend
    ports:
    - protocol: TCP
      port: 5432
---
# 5. Frontend egress to backend
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress-backend
  namespace: training
spec:
  podSelector:
    matchLabels:
      role: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          role: backend
    ports:
    - protocol: TCP
      port: 8080
---
# 6. Backend egress to database
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-egress-database
  namespace: training
spec:
  podSelector:
    matchLabels:
      role: backend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          role: database
    ports:
    - protocol: TCP
      port: 5432
```

Apply all at once by saving to a file and running:
```bash
kubectl apply -f bonus-networkpolicy.yaml
```
</details>

### Challenge 2: Host-Based Gateway Routing

Modify the HTTPRoute to use **host-based routing** instead of path-based:
- `app-a.training.local` → web-app-a Service
- `app-b.training.local` → web-app-b Service in the `app-b` namespace

Test with:
```bash
curl -H "Host: app-a.training.local" http://localhost:8888/
curl -H "Host: app-b.training.local" http://localhost:8888/
```

<details>
<summary>💡 Hint</summary>

Use the `hostnames` field in the HTTPRoute spec. The simplest approach is to create one HTTPRoute per hostname:
```yaml
hostnames:
- app-a.training.local
```
</details>

<details>
<summary>✅ Solution</summary>

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-a-host-route
  namespace: training
spec:
  parentRefs:
  - name: training-gateway
    namespace: envoy-gateway-system
  hostnames:
  - app-a.training.local
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web-app-a
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-b-host-route
  namespace: training
spec:
  parentRefs:
  - name: training-gateway
    namespace: envoy-gateway-system
  hostnames:
  - app-b.training.local
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web-app-b
      namespace: app-b
      port: 80
```

Apply and test:
```bash
kubectl apply -f host-route.yaml
curl -H "Host: app-a.training.local" http://localhost:8888/
curl -H "Host: app-b.training.local" http://localhost:8888/
```
</details>

---

> **🎉 Congratulations!** You've explored Kubernetes DNS, configured Gateway API routing, and implemented NetworkPolicies for traffic control. In **Module 6**, we'll dive into RBAC (Role-Based Access Control) and node management to secure and control your cluster.
