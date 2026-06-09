# Lab 1: Getting Started with Kubernetes

> **Duration:** 45 min
> **Prerequisites:** Docker installed and running, internet access for pulling images

## Objectives

1. Install `kubectl` and `kind` on your workstation
2. Create a multi-node Kubernetes cluster using kind
3. Verify cluster health and explore built-in components
4. Deploy your first Pod from a YAML manifest
5. Interact with running Pods using kubectl
6. Understand the difference between imperative and declarative approaches

## Before You Begin

Ensure you have the following installed:
- **Docker** (or Podman) — required as the container runtime for kind
- A terminal with `bash` or `zsh`
- `curl` or `wget`

> **💡 Tip:** If you're using Podman, set `export KIND_EXPERIMENTAL_PROVIDER=podman` before running kind commands.

> **⏱️ Time check:** Exercises 1–3 are core (~35 min). Treat the bonus challenge at the end as take-home.

---

## Exercise 1: Set Up Your Lab Environment

### Step 1: Install kubectl

`kubectl` is the command-line tool for interacting with Kubernetes clusters.

```bash
# Download the latest stable kubectl binary
curl -LO "https://dl.k8s.io/release/v1.36.1/bin/linux/amd64/kubectl"

# Make it executable and move to PATH
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Verify the installation
kubectl version --client
```

Expected output:
```
Client Version: v1.36.1
Kustomize Version: v5.x.x
```

### Step 2: Install kind

**kind** (Kubernetes IN Docker) runs Kubernetes cluster nodes as Docker containers.

```bash
# Download kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64

# Make it executable and move to PATH
chmod +x ./kind
sudo mv ./kind /usr/local/bin/

# Verify
kind version
```

Expected output:
```
kind v0.31.0 go1.25.x linux/amd64
```

### Step 3: Create a 3-Node Cluster

From the repository root, use the canonical course `kind-config.yaml`. It already includes the pinned node image, host port mappings for `80/443`, and the `ingress-ready=true` node label used in later labs.

```bash
cat kind-config.yaml
```

Now create the cluster:

```bash
kind create cluster --name training --config kind-config.yaml
```

Expected output:
```
Creating cluster "training" ...
 ✓ Ensuring node image (kindest/node:v1.35.1) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-training"
```

> **📝 Note:** This may take 2-5 minutes depending on your internet speed (it pulls the Kubernetes node image).

### Step 4: Verify the Cluster

```bash
# Check cluster information
kubectl cluster-info

# List all nodes
kubectl get nodes
```

Expected output:
```
NAME                     STATUS   ROLES           AGE   VERSION
training-control-plane   Ready    control-plane   2m    v1.35.1
training-worker          Ready    <none>          90s   v1.35.1
training-worker2         Ready    <none>          90s   v1.35.1
```

> **⚠️ Warning:** If nodes show `NotReady`, wait 30-60 seconds for the networking components to initialize, then run `kubectl get nodes` again.

### Step 5: Explore the kube-system Namespace

Kubernetes has built-in system components running in the `kube-system` namespace:

```bash
kubectl get pods -n kube-system
```

Expected output (will vary slightly):
```
NAME                                             READY   STATUS    RESTARTS   AGE
coredns-xxxxxxxxxx-xxxxx                         1/1     Running   0          3m
coredns-xxxxxxxxxx-xxxxx                         1/1     Running   0          3m
etcd-training-control-plane                      1/1     Running   0          3m
kindnet-xxxxx                                    1/1     Running   0          3m
kindnet-xxxxx                                    1/1     Running   0          3m
kindnet-xxxxx                                    1/1     Running   0          3m
kube-apiserver-training-control-plane            1/1     Running   0          3m
kube-controller-manager-training-control-plane   1/1     Running   0          3m
kube-proxy-xxxxx                                 1/1     Running   0          3m
kube-proxy-xxxxx                                 1/1     Running   0          3m
kube-proxy-xxxxx                                 1/1     Running   0          3m
kube-scheduler-training-control-plane            1/1     Running   0          3m
```

Take a moment to identify the components:
- **coredns** — cluster DNS service
- **etcd** — key-value store for cluster state
- **kube-apiserver** — the central API gateway
- **kube-controller-manager** — runs controllers (reconciliation loops)
- **kube-scheduler** — decides which node runs each Pod
- **kube-proxy** — manages network rules on each node
- **kindnet** — the CNI plugin (network provider) used by kind

> **💡 Tip:** We'll explore these components in detail in Module 2. For now, just know that they exist and are keeping your cluster running.

---

## Exercise 2: Your First Pod

### Step 1: Create the Pod Manifest

A **Pod** is the smallest deployable unit in Kubernetes. Let's create one running nginx.

Create the file `manifests/first-pod.yaml`:

```yaml
# first-pod.yaml — A simple Pod running nginx web server
apiVersion: v1              # Core API group, stable
kind: Pod                   # Resource type
metadata:
  name: my-first-pod        # Unique name for this Pod
  namespace: default        # Namespace (we'll use 'training' from Module 2 onwards)
  labels:
    app: nginx              # Labels for identification and selection
    environment: training
spec:
  containers:
  - name: nginx             # Container name within the Pod
    image: nginx:1.30.0       # Container image and version tag
    ports:
    - containerPort: 80     # Port the container listens on
```

### Step 2: Deploy the Pod

Apply the manifest to create the Pod in your cluster:

```bash
kubectl apply -f manifests/first-pod.yaml
```

Expected output:
```
pod/my-first-pod created
```

### Step 3: Check the Pod Status

```bash
# Quick status overview
kubectl get pods
```

Expected output:
```
NAME           READY   STATUS    RESTARTS   AGE
my-first-pod   1/1     Running   0          15s
```

Get more details with the `-o wide` flag:

```bash
kubectl get pods -o wide
```

This shows you which **node** the Pod is running on, its **IP address**, and more.

### Step 4: Describe the Pod

The `describe` command gives you detailed information about a resource, including events:

```bash
kubectl describe pod my-first-pod
```

Key sections to look at:
- **Status:** should be `Running`
- **IP:** the Pod's internal cluster IP
- **Node:** which worker node it's running on
- **Containers:** image, ports, resource limits
- **Events:** the history of what happened (scheduled, pulling image, started)

### Step 5: View Container Logs

```bash
kubectl logs my-first-pod
```

You should see the nginx startup log. To follow logs in real-time (like `tail -f`):

```bash
kubectl logs my-first-pod -f
```

Press `Ctrl+C` to stop following.

### Step 6: Execute Commands Inside the Pod

You can run commands inside a running container using `kubectl exec`:

```bash
# Run a single command
kubectl exec my-first-pod -- nginx -v
```

Expected output:
```
nginx version: nginx/1.30.0
```

Start an interactive shell:

```bash
kubectl exec -it my-first-pod -- /bin/bash
```

Inside the container, explore:
```bash
# Check the nginx default page
cat /usr/share/nginx/html/index.html

# Check the network configuration
hostname -i

# Exit the container shell
exit
```

### Step 7: Port-Forward to Access nginx

Port-forwarding creates a tunnel from your local machine to the Pod:

```bash
kubectl port-forward my-first-pod 8080:80
```

In another terminal (or open a browser):

```bash
curl http://localhost:8080
```

You should see the default nginx welcome page HTML. Press `Ctrl+C` to stop the port-forward.

> **🔑 Key Concept:** `port-forward` is for development and debugging only. In production, you'd use a **Service** (Module 3) or **Ingress** (Module 5) to expose applications.

---

## Exercise 3: Imperative vs. Declarative

### Step 1: Create a Pod Imperatively

You can create resources directly from the command line without writing YAML:

```bash
kubectl run imperative-nginx --image=nginx:1.30.0 --port=80
```

Verify it's running:

```bash
kubectl get pods
```

Expected output:
```
NAME               READY   STATUS    RESTARTS   AGE
imperative-nginx   1/1     Running   0          10s
my-first-pod       1/1     Running   0          15m
```

### Step 2: View the Generated YAML

You can see what Kubernetes generated for the imperative command:

```bash
kubectl get pod imperative-nginx -o yaml
```

Or, use **dry-run** to see what YAML kubectl would generate *without* actually creating anything:

```bash
kubectl run dry-run-example --image=nginx:1.30.0 --port=80 \
  --dry-run=client -o yaml
```

> **💡 Tip:** The `--dry-run=client -o yaml` trick is incredibly useful for generating YAML templates quickly. You can redirect the output to a file: `> my-pod.yaml`

### Step 3: Compare Approaches

| Aspect | Imperative | Declarative |
|--------|-----------|-------------|
| Command | `kubectl run ...` | `kubectl apply -f file.yaml` |
| Reproducible | ❌ Hard to reproduce | ✅ YAML file in Git |
| Git-friendly | ❌ No version control | ✅ Track changes in Git |
| Complex configs | ❌ Limited options | ✅ Full spec access |
| Speed | ✅ Quick for testing | ❌ Requires writing YAML |
| Production use | ❌ Not recommended | ✅ Best practice |

> **🔑 Key Concept:** Always use the **declarative approach** (YAML files + `kubectl apply`) for anything beyond quick testing. This enables version control, code review, and reproducibility — the foundation of GitOps practices.

### Step 4: Clean Up the Imperative Pod

```bash
kubectl delete pod imperative-nginx
```

---

## Verification

Confirm your lab environment is working correctly:

```bash
# 1. Cluster has 3 nodes (1 control-plane + 2 workers)
kubectl get nodes
# Expected: 3 nodes, all in "Ready" status

# 2. Your Pod is still running
kubectl get pods
# Expected: my-first-pod in "Running" status

# 3. You can access the Pod
kubectl exec my-first-pod -- nginx -v
# Expected: prints nginx version
```

---

## Cleanup

Remove the resources created during this lab:

```bash
# Delete the Pod
kubectl delete pod my-first-pod

# Verify cleanup
kubectl get pods
# Expected: No resources found in default namespace.
```

> **📝 Note:** Don't delete the kind cluster itself — we'll continue using it in the next modules!

To delete the cluster later (after the course):
```bash
kind delete cluster --name training
```

---

## Bonus Challenge

### Challenge 1: Deploy and Scale a Deployment

Instead of a bare Pod, use a **Deployment** to manage multiple replicas.

1. Create a Deployment using the bonus manifest:
```bash
kubectl apply -f manifests/first-deployment.yaml
```

2. Check the Deployment status:
```bash
kubectl get deployments
kubectl get pods
```

3. Scale the Deployment to 5 replicas:
```bash
kubectl scale deployment nginx-deployment --replicas=5
```

4. Watch the new Pods come up:
```bash
kubectl get pods -w
```

5. Expose it and access it:
```bash
kubectl expose deployment nginx-deployment --port=80 --type=NodePort
kubectl get services
```

<details>
<summary>💡 Hint</summary>
A Deployment manages a ReplicaSet, which ensures the desired number of Pod replicas are running. If a Pod dies, the ReplicaSet controller creates a new one automatically.
</details>

<details>
<summary>✅ What to observe</summary>

- After scaling, you should see 5 Pods with names like `nginx-deployment-xxxxxxxxx-xxxxx`
- Pods are distributed across your worker nodes (check with `-o wide`)
- If you delete a Pod with `kubectl delete pod <name>`, a new one is created automatically

Cleanup:
```bash
kubectl delete deployment nginx-deployment
kubectl delete service nginx-deployment
```
</details>

---

> **🎉 Congratulations!** You've set up a Kubernetes cluster, deployed your first Pod, and learned the fundamentals of kubectl. In **Module 2**, we'll dive deep into the Kubernetes architecture and become kubectl power users.
