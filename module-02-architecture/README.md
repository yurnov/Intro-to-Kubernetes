# Lab 2: Exploring Kubernetes Architecture and kubectl Mastery

> **Duration:** 30 min
> **Prerequisites:** Module 2 theory, running Kubernetes cluster (kind with 3 nodes from Lab 1)

## Objectives

1. Explore cluster components and understand what runs on each node
2. Create and manage namespaces with resource quotas
3. Master kubectl output formatting and manifest generation
4. Navigate the Kubernetes API and explore resource schemas

## Before You Begin

Ensure your kind cluster from Lab 1 is still running:

```bash
kubectl get nodes
```

Expected output:
```
NAME                     STATUS   ROLES           AGE   VERSION
training-control-plane   Ready    control-plane   1d    v1.36.1
training-worker          Ready    <none>          1d    v1.36.1
training-worker2         Ready    <none>          1d    v1.36.1
```

> **🔧 Troubleshooting:** If the cluster is not running, recreate it from the repository root:
> ```bash
> kind create cluster --name training --config kind-config.yaml
> ```

> **⏱️ Time check:** Exercises 1–3 are core (~25 min). Exercise 4 (API proxy) and the bonus challenges are take-home.

---

## Exercise 1: Explore Cluster Components

### Step 1: Examine Node Details

Use `kubectl describe` to see the full details of a node, including its capacity, allocated resources, and conditions:

```bash
kubectl describe node training-control-plane
```

Key sections to examine:
- **Roles:** `control-plane` — this node runs the control plane components
- **Conditions:** `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure`
- **Capacity vs. Allocatable:** total resources vs. what's available for Pods
- **Non-terminated Pods:** system Pods running on this node

```bash
# Compare with a worker node
kubectl describe node training-worker
```

> **📝 Note:** Worker nodes show `<none>` for roles by default. The control plane node runs system Pods (API server, etcd, scheduler, controller manager) while worker nodes run your application workloads.

### Step 2: Explore the kube-system Namespace

List all Pods in the `kube-system` namespace:

```bash
kubectl get pods -n kube-system -o wide
```

Expected output:
```
NAME                                             READY   STATUS    RESTARTS   AGE   IP            NODE
coredns-xxxxxxxxxx-xxxxx                         1/1     Running   0          1d    10.244.0.x    training-control-plane
coredns-xxxxxxxxxx-xxxxx                         1/1     Running   0          1d    10.244.0.x    training-control-plane
etcd-training-control-plane                      1/1     Running   0          1d    172.18.0.x    training-control-plane
kindnet-xxxxx                                    1/1     Running   0          1d    172.18.0.x    training-control-plane
kindnet-xxxxx                                    1/1     Running   0          1d    172.18.0.x    training-worker
kindnet-xxxxx                                    1/1     Running   0          1d    172.18.0.x    training-worker2
kube-apiserver-training-control-plane            1/1     Running   0          1d    172.18.0.x    training-control-plane
kube-controller-manager-training-control-plane   1/1     Running   0          1d    172.18.0.x    training-control-plane
kube-proxy-xxxxx                                 1/1     Running   0          1d    172.18.0.x    training-control-plane
kube-proxy-xxxxx                                 1/1     Running   0          1d    172.18.0.x    training-worker
kube-proxy-xxxxx                                 1/1     Running   0          1d    172.18.0.x    training-worker2
kube-scheduler-training-control-plane            1/1     Running   0          1d    172.18.0.x    training-control-plane
```

Identify which components run where:
- **Control plane only:** etcd, kube-apiserver, kube-controller-manager, kube-scheduler, coredns
- **Every node:** kube-proxy, kindnet (CNI plugin)

### Step 3: View the API Server Pod Spec

Examine the kube-apiserver Pod to understand how control plane components are configured:

```bash
kubectl get pod kube-apiserver-training-control-plane -n kube-system -o yaml | head -80
```

Look for:
- The container image version
- Command-line flags (e.g., `--etcd-servers`, `--service-cluster-ip-range`)
- Volume mounts (certificates, etcd data)

> **🔑 Key Concept:** Control plane components on kubeadm-based clusters (including kind) run as **static Pods** — the kubelet reads their manifests directly from `/etc/kubernetes/manifests/` on the control plane node.

### Step 4: Check Component Health

```bash
# Check node conditions
kubectl get nodes -o wide

# View events across the cluster
kubectl get events -n kube-system --sort-by='.lastTimestamp' | tail -10
```

---

## Exercise 2: Working with Namespaces

### Step 1: List Existing Namespaces

```bash
kubectl get namespaces
```

Expected output:
```
NAME                 STATUS   AGE
default              Active   3d
kube-node-lease      Active   3d
kube-public          Active   3d
kube-system          Active   3d
local-path-storage   Active   3d
```

### Step 2: Create the Training Namespace

Create a namespace using a YAML manifest:

```bash
kubectl apply -f manifests/namespace.yaml
```

Verify:
```bash
kubectl get namespaces
```

You should see `training` in the list.

### Step 3: Set the Default Namespace

Instead of typing `-n training` on every command, set it as the default for your context:

```bash
kubectl config set-context --current --namespace=training

# Verify the change
kubectl config get-contexts
```

Expected output (notice the NAMESPACE column):
```
CURRENT   NAME            CLUSTER         AUTHINFO        NAMESPACE
*         kind-training   kind-training   kind-training   training
```

### Step 4: Deploy a Pod in the Training Namespace

```bash
kubectl apply -f manifests/sample-pod.yaml
```

Verify:
```bash
# Shows Pods in the training namespace (now the default)
kubectl get pods

# Show Pods across ALL namespaces
kubectl get pods -A
```

### Step 5: Apply a Resource Quota

Enforce resource limits on the training namespace:

```bash
kubectl apply -f manifests/resource-quota.yaml
```

Check the quota:
```bash
kubectl describe resourcequota training-quota -n training
```

Expected output:
```
Name:                   training-quota
Namespace:              training
Resource                Used  Hard
--------                ----  ----
limits.cpu              0     8
limits.memory           0     16Gi
pods                    1     10
persistentvolumeclaims  0     5
requests.cpu            0     4
requests.memory         0     8Gi
```

> **📝 Note:** With a ResourceQuota that specifies CPU/memory limits, all Pods in this namespace will be required to have resource requests and limits set. Without them, Pod creation will be rejected.

---

## Exercise 3: kubectl Power User

### Step 1: Output Formatting

Use different output formats to extract information:

```bash
# Default table
kubectl get pods

# Wide output — shows IP, node, and nominated node
kubectl get pods -o wide

# Full YAML
kubectl get pod explore-pod -o yaml

# JSONPath — extract just the Pod IP
kubectl get pod explore-pod -o jsonpath='{.status.podIP}'
echo  # newline

# JSONPath — extract the container image
kubectl get pod explore-pod -o jsonpath='{.spec.containers[0].image}'
echo

# Custom columns
kubectl get pods -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.phase,\
IP:.status.podIP,\
NODE:.spec.nodeName
```

> **💡 Tip:** Kubernetes v1.34 introduced **KYAML** (alpha) as a stricter YAML output dialect; it graduated to beta and is enabled by default in v1.35. Try it:
> ```bash
> kubectl get pod explore-pod -o kyaml
> ```
> See the [KYAML reference](https://kubernetes.io/docs/reference/encodings/kyaml/) for details. KYAML round-trips cleanly through `kubectl apply`.

### Step 2: Generate Manifests with Dry-Run

Use `--dry-run=client` to generate YAML without creating resources:

> **⚠️ Important:** With `kubectl run`, all kubectl flags must come **before** the `--` separator. Everything after `--` is passed to the container as its command/arguments. If you accidentally place `--dry-run=client -o yaml` after `--`, `kubectl` will try to create a real Pod instead of just printing YAML.
>
> In this lab, your current namespace is `training`, and `training-quota` requires every Pod to define CPU and memory requests/limits. That means the incorrectly ordered command can fail with an error like:
> ```text
> Error from server (Forbidden): pods "test-pod" is forbidden: failed quota: training-quota: must specify limits.cpu for: test-pod; limits.memory for: test-pod; requests.cpu for: test-pod; requests.memory for: test-pod
> ```
> Use the corrected flag order below. If you later want to apply the generated Pod manifest in `training`, add `resources.requests` and `resources.limits` first.

```bash
# Generate a Pod manifest
kubectl run test-pod --image=busybox:1.37.0 \
  --dry-run=client -o yaml \
  --command -- sleep 3600

# Generate a Deployment manifest
kubectl create deployment test-deploy --image=nginx:1.30.0 --replicas=2 \
  --dry-run=client -o yaml

# Save a generated manifest to a file
kubectl run generated-pod --image=nginx:1.30.0 --port=80 \
  --dry-run=client -o yaml > /tmp/generated-pod.yaml

# Inspect the generated file
cat /tmp/generated-pod.yaml
```

If you want to stay in the `training` namespace, use a quota-compliant manifest:

```bash
cat > /tmp/quota-aware-test-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: quota-aware-test-pod
  namespace: training
spec:
  restartPolicy: Never
  containers:
    - name: quota-aware-test-pod
      image: busybox:1.37.0
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "200m"
          memory: "256Mi"
EOF

# Validate against the API server without creating the Pod
kubectl apply --dry-run=server -f /tmp/quota-aware-test-pod.yaml
```

This works because the manifest satisfies the `training-quota` requirements for CPU and memory requests/limits.

### Step 3: Explore Resource Specs with kubectl explain

`kubectl explain` is like built-in documentation for resource fields:

```bash
# Top-level fields for a Pod
kubectl explain pod

# Drill into the spec
kubectl explain pod.spec

# Drill into containers
kubectl explain pod.spec.containers

# See all fields recursively
kubectl explain pod.spec.containers --recursive | head -50
```

> **💡 Tip:** Use `kubectl explain` when writing YAML manifests — it's faster than searching the documentation and always matches your cluster's API version.

### Step 4: List API Resources

```bash
# All resources, their short names, API versions, and scope
kubectl api-resources

# Filter by API group
kubectl api-resources --api-group=apps

# Only namespaced resources
kubectl api-resources --namespaced=true

# Only cluster-scoped resources
kubectl api-resources --namespaced=false
```

---

## Exercise 4: Explore the API

### Step 1: List API Versions

```bash
kubectl api-versions
```

You'll see a list of all available API group/versions, e.g.:
```
admissionregistration.k8s.io/v1
apps/v1
batch/v1
networking.k8s.io/v1
v1
...
```

### Step 2: Drill Into Resource Schema

Use `kubectl explain` to explore nested resource specifications:

```bash
# Explore Deployment spec
kubectl explain deployment.spec

# Explore the template within a Deployment
kubectl explain deployment.spec.template.spec.containers

# Explore specific fields
kubectl explain deployment.spec.strategy
kubectl explain deployment.spec.strategy.rollingUpdate
```

### Step 3: (Optional) Access the API Server Directly

Start a kubectl proxy to access the API server directly:

```bash
# Start the proxy in the background
kubectl proxy --port=8001 &

# List available API paths
curl -s http://localhost:8001/ | head -20

# Get cluster info
curl -s http://localhost:8001/api/v1/namespaces | python3 -m json.tool | head -30

# List Pods in the training namespace
curl -s http://localhost:8001/api/v1/namespaces/training/pods | python3 -m json.tool | head -30

# Stop the proxy
kill %1
```

> **🔑 Key Concept:** Every `kubectl` command is just a REST API call to the API server. The proxy lets you explore the API directly, which helps when building integrations or debugging.

---

## Verification

Confirm everything works correctly:

```bash
# 1. Your context is set to the training namespace
kubectl config get-contexts
# Expected: NAMESPACE column shows "training"

# 2. The sample Pod is running in training
kubectl get pods -n training
# Expected: explore-pod in Running status

# 3. Resource quota is applied
kubectl describe resourcequota training-quota -n training
# Expected: shows the used/hard limits

# 4. You can use JSONPath output
kubectl get pod explore-pod -o jsonpath='{.metadata.name} is {.status.phase}'
echo
# Expected: "explore-pod is Running"
```

---

## Cleanup

Remove all resources created during this lab:

```bash
# Delete all resources in the training namespace
kubectl delete -f manifests/

# Verify cleanup
kubectl get all -n training
# Expected: No resources found
```

Or reset the entire namespace:

```bash
kubectl delete namespace training
kubectl create namespace training
kubectl config set-context --current --namespace=training
```

---

## Bonus Challenges

### Challenge 1: Install k9s and Explore

Install k9s and use it to navigate the cluster:

1. Install k9s on your machine
2. Run `k9s` and explore Pods, nodes, and namespaces
3. Use `:pods` to view Pods, `:no` for nodes, `:ns` for namespaces
4. Try pressing `l` on a Pod to view its logs, `d` to describe it

<details>
<summary>💡 Hint</summary>

```bash
# Install k9s
curl -sS https://webi.sh/k9s | sh

# Run it
k9s

# Navigation:
# : — command mode (type resource names)
# / — filter/search
# d — describe
# l — logs
# e — edit
# Ctrl+d — delete
# ? — help
```
</details>

### Challenge 2: Create a Custom kubeconfig Context

Create a new context in your kubeconfig that points to the `kube-system` namespace:

<details>
<summary>💡 Hint</summary>

```bash
# Create a new context
kubectl config set-context kube-system-ctx \
  --cluster=kind-training \
  --user=kind-training \
  --namespace=kube-system

# Switch to the new context
kubectl config use-context kube-system-ctx

# Verify — should show kube-system Pods by default
kubectl get pods

# Switch back to the training context
kubectl config use-context kind-training
```
</details>

<details>
<summary>✅ Solution</summary>

After creating the context and switching to it, `kubectl get pods` should show the system Pods (coredns, etcd, kube-apiserver, etc.) without needing to specify `-n kube-system`.

```bash
# Verify
kubectl config get-contexts
# Should show two contexts with different namespaces
```

Remember to switch back to your training context when done!
</details>

---

> **🎉 Congratulations!** You now understand how Kubernetes works under the hood and have mastered essential kubectl skills. In **Module 3**, we'll use these skills to deploy and orchestrate real applications with Deployments, Services, and health probes.
