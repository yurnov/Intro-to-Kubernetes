# Lab 8: Troubleshooting, Logging, and Monitoring

> **Duration:** 20 min
> **Prerequisites:** Module 8 theory, running Kubernetes cluster (kind with 3 nodes from Lab 1), `training` namespace created, `helm` installed (Module 7)

## Objectives

1. Diagnose and fix intentionally broken Kubernetes manifests
2. Use `kubectl logs` to investigate application log output
3. Install and use Metrics Server for basic resource monitoring
4. (Optional) Deploy a centralized logging stack with Loki and Grafana

## Before You Begin

Ensure your kind cluster from Lab 1 is still running:

```bash
kubectl get nodes
```

Expected output:
```
NAME                     STATUS   ROLES           AGE   VERSION
training-control-plane   Ready    control-plane   Xd    v1.36.1
training-worker          Ready    <none>          Xd    v1.36.1
training-worker2         Ready    <none>          Xd    v1.36.1
```

> **🔧 Troubleshooting:** If the cluster is not running, recreate it from the repository root:
> ```bash
> kind create cluster --name training --config kind-config.yaml
> ```

> **⏱️ Time check:** Exercise 1 (broken Pods) and Exercise 2 Steps 1–4 (logging) are core (~15 min). Exercise 3 (metrics-server) is core if not already installed. The Loki/Prometheus optional steps and the `kubectl debug` bonuses are take-home.

Ensure the `training` namespace exists and is set as the default context:

```bash
kubectl create namespace training --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=training
```

---

## Exercise 1: Troubleshooting Broken Deployments

In this exercise, you'll apply intentionally broken manifests, diagnose the issues, and fix them. This simulates real-world debugging scenarios.

### Step 1: Broken Pod 1 — Wrong Image (ImagePullBackOff)

Apply the broken manifest:

```bash
kubectl apply -f manifests/broken-pod-image.yaml
```

Check the Pod status:

```bash
kubectl get pods -n training
```

Expected output:
```
NAME           READY   STATUS             RESTARTS   AGE
broken-image   0/1     ImagePullBackOff   0          30s
```

**Diagnose the issue:**

```bash
kubectl describe pod broken-image -n training
```

Look at the **Events** section at the bottom of the output. You should see messages like:

```
Events:
  Type     Reason     Age   From               Message
  ----     ------     ----  ----               -------
  Normal   Scheduled  30s   default-scheduler  Successfully assigned training/broken-image to ...
  Normal   Pulling    30s   kubelet            Pulling image "nginx:99.99.99"
  Warning  Failed     25s   kubelet            Failed to pull image "nginx:99.99.99": ...
  Warning  Failed     25s   kubelet            Error: ErrImagePull
  Normal   BackOff    10s   kubelet            Back-off pulling image "nginx:99.99.99"
  Warning  Failed     10s   kubelet            Error: ImagePullBackOff
```

**Fix the issue:**

The image tag `nginx:99.99.99` does not exist. Fix it by editing the Pod:

```bash
kubectl delete pod broken-image -n training
```

Edit the manifest to use a valid image tag (`nginx:1.30.0`) and re-apply:

```bash
# Create a fixed version of the manifest
sed 's/nginx:99.99.99/nginx:1.30.0/' manifests/broken-pod-image.yaml | kubectl apply -f -
```

Verify the fix:

```bash
kubectl get pods -n training
```

Expected output:
```
NAME           READY   STATUS    RESTARTS   AGE
broken-image   1/1     Running   0          15s
```

> **🔑 Key Concept:** `ImagePullBackOff` means Kubernetes tried to pull the container image but failed, and is now waiting before retrying. Common causes: wrong image name/tag, private registry without credentials, or network issues.

### Step 2: Broken Pod 2 — Missing ConfigMap (CreateContainerConfigError)

Apply the broken manifest:

```bash
kubectl apply -f manifests/broken-pod-configmap.yaml
```

Check the Pod status:

```bash
kubectl get pods -n training
```

Expected output:
```
NAME               READY   STATUS                       RESTARTS   AGE
broken-configmap   0/1     CreateContainerConfigError   0          15s
```

> **💡 Tip:** For the first few seconds the Pod may show `ContainerCreating`. Wait ~10 seconds and re-run `kubectl get pods` — it will settle into `CreateContainerConfigError`.

**Diagnose the issue:**

```bash
kubectl describe pod broken-configmap -n training
```

In the Events section, look for:

```
Warning  Failed  10s  kubelet  Error: configmap "app-settings" not found
```

**Fix the issue:**

The Pod references a ConfigMap called `app-settings` that doesn't exist. Create it:

```bash
kubectl create configmap app-settings \
  --from-literal=settings.conf="debug=true" \
  -n training
```

The Pod should start automatically once the ConfigMap exists. If not, delete and re-apply:

```bash
kubectl delete pod broken-configmap -n training
kubectl apply -f manifests/broken-pod-configmap.yaml
```

Verify the fix:

```bash
kubectl get pods -n training
kubectl exec broken-configmap -n training -- cat /etc/config/settings.conf
```

Expected output:
```
debug=true
```

> **🔑 Key Concept:** `CreateContainerConfigError` means the container couldn't be created because a referenced ConfigMap or Secret doesn't exist. As we learned in Module 4, always verify that ConfigMaps and Secrets exist before deploying Pods that reference them.

### Step 3: Broken Pod 3 — Problematic Resource Limits (CrashLoopBackOff / OOMKilled)

Apply the broken manifest:

```bash
kubectl apply -f manifests/broken-pod-resources.yaml
```

Watch the Pod status:

```bash
kubectl get pods -n training -w
```

You should see the Pod crash repeatedly:

```
NAME               READY   STATUS             RESTARTS     AGE
broken-resources   0/1     CrashLoopBackOff   3 (30s ago)  90s
```

Press `Ctrl+C` to stop watching.

**Diagnose the issue:**

```bash
kubectl describe pod broken-resources -n training
```

Look for the **Last State** section. The exact values depend on how far the container got before the kernel killed it:

```
    Last State:  Terminated
      Reason:    OOMKilled       # sometimes shown as StartError
      Exit Code: 137             # sometimes 128 when killed during init
```

The memory limit of 4Mi is far too low for nginx. With a limit this extreme the container is often OOM-killed *during initialization*, before the main process even starts — in that case `describe` reports `Reason: StartError` / `Exit Code: 128` with a message like `container init was OOM-killed (memory limit too low?)`. If it survives init and then gets killed, you'll see the classic `Reason: OOMKilled` / `Exit Code: 137`. Either way the `STATUS` column cycles through `OOMKilled`, `CrashLoopBackOff`, and `RunContainerError` — all pointing at the same root cause: not enough memory.

**Fix the issue:**

Delete the broken Pod and apply it with reasonable resource limits:

```bash
kubectl delete pod broken-resources -n training

# Apply with corrected resource limits
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: broken-resources
  namespace: training
  labels:
    app: broken-resources
    exercise: troubleshooting
    module: "08"
spec:
  containers:
  - name: web
    image: nginx:1.30.0
    ports:
    - containerPort: 80
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
      limits:
        memory: "128Mi"
        cpu: "100m"
EOF
```

Verify the fix:

```bash
kubectl get pods -n training
```

Expected output:
```
NAME               READY   STATUS    RESTARTS   AGE
broken-resources   1/1     Running   0          15s
```

> **🔑 Key Concept:** `OOMKilled` (exit code 137) means the container exceeded its memory limit. The kernel kills the process immediately. Check `kubectl describe pod` → Last State for the termination reason. As we covered in Module 3, always set memory limits based on actual application needs.

### Step 4: Broken Deployment — Mismatched Label Selectors

Apply the broken manifest:

```bash
kubectl apply -f manifests/broken-deployment.yaml
```

Expected output:
```
The Deployment "broken-deploy" is invalid: spec.template.metadata.labels: Invalid value: ... `selector` does not match template `labels`
```

**Diagnose the issue:**

The Kubernetes API server **rejects** this manifest immediately because the `spec.selector.matchLabels` don't match `spec.template.metadata.labels`. Look at the error message — it clearly states the mismatch.

Examine the manifest:

```bash
cat manifests/broken-deployment.yaml | grep -A2 "matchLabels\|labels"
```

You'll see:
- `selector.matchLabels.app: broken-deploy`
- `template.metadata.labels.app: broken-web` ← **mismatch!**

**Fix the issue:**

Apply a corrected version with matching labels:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-deploy
  namespace: training
  labels:
    app: broken-deploy
    module: "08"
spec:
  replicas: 2
  selector:
    matchLabels:
      app: broken-deploy
  template:
    metadata:
      labels:
        app: broken-deploy
    spec:
      containers:
      - name: web
        image: nginx:1.30.0
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "32Mi"
            cpu: "25m"
          limits:
            memory: "64Mi"
            cpu: "50m"
EOF
```

Verify the fix:

```bash
kubectl get deployment broken-deploy -n training
kubectl get pods -l app=broken-deploy -n training
```

Expected output:
```
NAME            READY   UP-TO-DATE   AVAILABLE   AGE
broken-deploy   2/2     2            2           30s

NAME                            READY   STATUS    RESTARTS   AGE
broken-deploy-xxxxx-xxxxx       1/1     Running   0          30s
broken-deploy-xxxxx-xxxxx       1/1     Running   0          30s
```

> **🔑 Key Concept:** The Deployment `selector.matchLabels` **must** match the Pod `template.metadata.labels`. Kubernetes validates this at apply time and rejects mismatches immediately. This is a common mistake when copying manifests.

---

## Exercise 2: Log Investigation

### Step 1: Deploy a Logging Application

Deploy an application that generates structured JSON log output:

```bash
kubectl apply -f manifests/logging-app.yaml
```

Wait for the Pods to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=logging-app -n training --timeout=60s
```

Verify:

```bash
kubectl get pods -l app=logging-app -n training
```

Expected output:
```
NAME                          READY   STATUS    RESTARTS   AGE
logging-app-xxxxx-xxxxx       1/1     Running   0          30s
logging-app-xxxxx-xxxxx       1/1     Running   0          30s
```

### Step 2: View and Follow Logs

View logs from one of the Pods:

```bash
# Get the name of the first Pod
LOGGING_POD=$(kubectl get pods -l app=logging-app -n training -o jsonpath='{.items[0].metadata.name}')

# View recent logs
kubectl logs $LOGGING_POD -n training --tail=10
```

Expected output (JSON structured logs):
```json
{"level":"info","msg":"Processing request","counter":5,"timestamp":"2025-01-15T10:30:10Z"}
{"level":"info","msg":"Processing request","counter":6,"timestamp":"2025-01-15T10:30:12Z"}
...
```

Follow logs in real time (press `Ctrl+C` to stop):

```bash
kubectl logs $LOGGING_POD -n training -f --tail=5
```

### Step 3: Filter Logs Across Pods

View logs from ALL Pods of the logging application:

```bash
kubectl logs -l app=logging-app -n training --tail=5
```

> **💡 Tip:** When using `-l` (label selector) for logs, the output interleaves lines from all matching Pods. Add `--prefix=true` to prepend the Pod name to each line:
> ```bash
> kubectl logs -l app=logging-app -n training --tail=5 --prefix=true
> ```

### Step 4: View Logs from a Crashed Container

Create a Pod that deliberately crashes and view its previous logs:

```bash
kubectl run crash-test --image=busybox:1.37.0 -n training \
  --restart=Always \
  -- sh -c 'echo "Starting up..."; echo "Doing work..."; echo "FATAL: out of memory"; exit 1'
```

Wait for the Pod to enter `CrashLoopBackOff`:

```bash
kubectl get pods crash-test -n training -w
```

Press `Ctrl+C` after you see `CrashLoopBackOff`, then view the logs from the crashed container:

```bash
kubectl logs crash-test -n training
```

Expected output:
```
Starting up...
Doing work...
FATAL: out of memory
```

Even though the Pod is not running right now, `kubectl logs` returns the output of the **most recent (crashed) container instance** — exactly what you need to see why it died.

> **🔑 Key Concept:** To inspect an *earlier* instance (the one before the current crash loop), there is a `--previous` flag:
> ```bash
> kubectl logs crash-test -n training --previous
> ```
> On many clusters this shows the prior instance's logs. **On this course's kind cluster it usually fails** with `unable to retrieve container logs for containerd://...` — kind's kubelet garbage-collects the log file of a previous instance as soon as a rapidly-restarting container is replaced, so only the most recent instance's log survives. When that happens, drop `--previous` and use plain `kubectl logs` (as above). The `--previous` flag remains essential in production, where a container may crash once and then start cleanly — there `kubectl logs` shows the healthy new instance while `--previous` shows the crash.

### Step 5: Multi-Pod Log Tailing with `stern`

Built-in `kubectl logs -l <selector>` interleaves output from matching Pods, but the formatting is hard to read once you have more than a couple of Pods. **`stern`** is the day-to-day tool engineers reach for: it tails logs from any number of Pods/containers in real time, with colored prefixes per Pod, regex filtering, and `--since` support.

```bash
# Install stern (Linux x86_64)
curl -Lo stern.tar.gz https://github.com/stern/stern/releases/download/v1.32.0/stern_1.32.0_linux_amd64.tar.gz
tar -xzf stern.tar.gz stern
sudo install stern /usr/local/bin/stern
rm stern.tar.gz stern

stern --version
```

Tail logs from every Pod in the `logging-app` Deployment:

```bash
stern -n training logging-app
```

Filter to errors only:

```bash
stern -n training logging-app --include 'error|fatal'
```

Tail across an entire namespace, with 2 minutes of history:

```bash
stern -n training --since 2m '.*'
```

Press `Ctrl+C` to stop.

> **💡 Tip:** `stern -A` follows logs across **all** namespaces — invaluable when you don't yet know which Pod is misbehaving.

### Step 6: (Take-home) Centralized Log Aggregation with Loki

For production-grade centralized logging you need an aggregator that ingests, indexes, and serves queries — not just a tail tool. **Grafana Loki** is the common pairing with Prometheus/Grafana for metrics + logs.

The historic `grafana/loki-stack` Helm chart is **deprecated** as of 2026; new installs should use the maintained **`grafana/loki`** chart in `singleBinary` mode (suitable for small clusters and labs):

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki -n monitoring --create-namespace \
  --set deploymentMode=SingleBinary \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.auth_enabled=false \
  --set singleBinary.replicas=1 \
  --set 'loki.schemaConfig.configs[0].from=2024-04-01' \
  --set 'loki.schemaConfig.configs[0].store=tsdb' \
  --set 'loki.schemaConfig.configs[0].object_store=filesystem' \
  --set 'loki.schemaConfig.configs[0].schema=v13' \
  --set 'loki.schemaConfig.configs[0].index.prefix=index_' \
  --set 'loki.schemaConfig.configs[0].index.period=24h'

# Modern log forwarder — Grafana Alloy (replaces Promtail)
helm install alloy grafana/alloy -n monitoring \
  --set 'controller.type=daemonset'
```

Then add Loki as a Grafana data source (`http://loki.monitoring.svc.cluster.local:3100`) — if you installed `kube-prometheus-stack` in the next exercise its Grafana picks it up automatically.

> **📝 Note:** Treat this as a self-paced exercise — the install warm-up alone takes several minutes on a kind cluster. The official current docs are at <https://grafana.com/docs/loki/latest/setup/install/helm/>.

---

## Exercise 3: Metrics and Monitoring

### Step 1: Install Metrics Server

Check if Metrics Server is already installed:

```bash
kubectl get deployment metrics-server -n kube-system 2>/dev/null
```

If it's not installed, install it (for kind clusters):

```bash
# Install Metrics Server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml

# Patch for kind (disable TLS verification for kubelet)
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# Wait for Metrics Server to be ready
kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s
```

> **📝 Note:** The `--kubelet-insecure-tls` flag is needed for the course's kind cluster because the kubelet uses self-signed certificates. In production, configure proper TLS certificates instead.

### Step 2: View Node and Pod Metrics

Wait 30–60 seconds for metrics to be collected, then:

```bash
# View node resource usage
kubectl top nodes
```

Expected output:
```
NAME                     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
training-control-plane   250m         12%    1024Mi          26%
training-worker          120m         6%     512Mi           13%
training-worker2         115m         5%     480Mi           12%
```

```bash
# View Pod resource usage in the training namespace
kubectl top pods -n training
```

Expected output:
```
NAME                          CPU(cores)   MEMORY(bytes)
broken-image                  1m           5Mi
broken-configmap              0m           1Mi
broken-resources              1m           3Mi
logging-app-xxxxx-xxxxx       1m           2Mi
logging-app-xxxxx-xxxxx       1m           2Mi
...
```

```bash
# Sort by memory usage
kubectl top pods -n training --sort-by=memory

# View resource usage for all namespaces
kubectl top pods --all-namespaces --sort-by=cpu
```

### Step 3: (Optional) Install kube-prometheus-stack

If you have time and sufficient cluster resources, install the full monitoring stack:

```bash
# Add the Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install with minimal resources for lab use
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --version 84.4.0 \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.requests.cpu=50m
```

Wait for the Pods to be ready:

```bash
kubectl get pods -n monitoring -w
```

### Step 4: (Optional) Access Grafana Dashboard

Port-forward Grafana to your local machine:

```bash
kubectl port-forward svc/kube-prometheus-grafana -n monitoring 3000:80
```

Open a browser and navigate to `http://localhost:3000`:
- **Username:** `admin`
- **Password:** `prom-operator` (default for kube-prometheus-stack)

Explore the pre-installed dashboards:
1. Navigate to **Dashboards → Browse**
2. Open **Kubernetes / Compute Resources / Namespace (Pods)**
3. Select the `training` namespace
4. Observe CPU and memory usage for your lab Pods

> **💡 Tip:** The kube-prometheus-stack comes with dozens of pre-configured dashboards. Explore "Kubernetes / Compute Resources / Cluster" for a high-level overview.

---

## Verification

Confirm all lab exercises completed successfully:

```bash
# 1. All broken Pods should be fixed and running
kubectl get pods -n training

# 2. Logging app should be generating logs
kubectl logs -l app=logging-app -n training --tail=3

# 3. Metrics Server should be working
kubectl top pods -n training

# 4. All Deployments should be healthy
kubectl get deployments -n training
```

---

## Cleanup

Remove all resources created during this lab:

```bash
# Delete all lab resources in the training namespace
kubectl delete pod broken-image broken-configmap broken-resources crash-test -n training --ignore-not-found
kubectl delete deployment broken-deploy logging-app -n training --ignore-not-found
kubectl delete service logging-app -n training --ignore-not-found
kubectl delete configmap app-settings -n training --ignore-not-found
kubectl delete -f manifests/ -n training --ignore-not-found

# (Optional) Remove monitoring stack
helm uninstall kube-prometheus -n monitoring 2>/dev/null
helm uninstall loki -n monitoring 2>/dev/null
helm uninstall alloy -n monitoring 2>/dev/null
kubectl delete namespace monitoring --ignore-not-found

# (Optional) Remove Metrics Server
kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml 2>/dev/null
```

Or delete and recreate the namespace:

```bash
kubectl delete namespace training
kubectl create namespace training
```

---

## Bonus Challenges

### Challenge 1: Ephemeral Debug Containers

Use `kubectl debug` to attach an ephemeral container to one of the running nginx Pods and inspect its network configuration:

1. Attach a debug container using the `nicolaka/netshoot:v0.14` image
2. Inside the debug container, check the Pod's network interfaces, DNS configuration, and connectivity

<details>
<summary>💡 Hint</summary>

Use `kubectl debug` with the `--image` and `--target` flags:
```bash
kubectl debug -it <pod-name> -n training --image=nicolaka/netshoot:v0.14 --target=web
```

Inside the container, try:
- `ip addr` — view network interfaces
- `cat /etc/resolv.conf` — check DNS config
- `curl localhost:80` — test the nginx container
</details>

<details>
<summary>✅ Solution</summary>

```bash
# Attach an ephemeral debug container to the broken-image Pod (which is now fixed)
kubectl debug -it broken-image -n training --image=nicolaka/netshoot:v0.14 --target=web

# Inside the ephemeral container:
ip addr                    # View network interfaces
cat /etc/resolv.conf       # Check DNS resolution config
curl -s localhost:80       # Access nginx on localhost (shared network namespace)
netstat -tlnp              # View listening ports
exit
```

The debug container shares the Pod's network namespace, so `localhost:80` reaches the nginx container directly.
</details>

### Challenge 2: Network Debugging with Netshoot

A Service called `logging-app` exists but imagine it's not accessible. Use the `nicolaka/netshoot:v0.14` image to debug the connectivity:

1. Run a debug Pod with networking tools
2. Verify DNS resolution for the Service
3. Check if the Service has endpoints
4. Test connectivity to the Service

<details>
<summary>💡 Hint</summary>

Run a one-time debug Pod:
```bash
kubectl run debug --image=nicolaka/netshoot:v0.14 -it --rm -n training -- bash
```

Inside the Pod:
- `nslookup logging-app` — check DNS
- `curl -s logging-app:80` — test HTTP connectivity
</details>

<details>
<summary>✅ Solution</summary>

```bash
# Check Service endpoints first (from outside the cluster)
kubectl get endpoints logging-app -n training

# Run a debug Pod
kubectl run debug --image=nicolaka/netshoot:v0.14 -it --rm -n training -- bash

# Inside the debug Pod:
nslookup logging-app                    # Verify DNS resolves
nslookup logging-app.training.svc.cluster.local  # FQDN resolution
curl -s --max-time 3 logging-app:80     # Test HTTP connectivity
dig logging-app.training.svc.cluster.local  # Detailed DNS query
exit
```

If the Service is not accessible:
1. Check that endpoints exist (`kubectl get endpoints`)
2. Verify the Service selector matches Pod labels
3. Ensure the target port matches the container port
</details>

---

> **🎉 Congratulations!** You've completed the final lab of the **Introduction to Kubernetes** course. You've practiced diagnosing and fixing broken Pods, investigating logs, and using metrics for monitoring. These troubleshooting skills are essential for day-to-day Kubernetes operations and will serve you well as you prepare for CKA/CKAD certifications or manage production clusters.
