# Lab 7: StatefulSets, DaemonSets, CronJobs, and Helm

> **Duration:** 30 min
> **Prerequisites:** Module 7 theory, running Kubernetes cluster (kind with 3 nodes from Lab 1), Helm installed

## Objectives

1. Deploy a StatefulSet with a headless Service and verify ordinal naming and per-replica PVCs
2. Create a DaemonSet that runs on every node and observe node-level scheduling
3. Set up a CronJob with scheduled execution and inspect Job history
4. Install, upgrade, and rollback an application using Helm
5. (Optional) Explore ArgoCD for GitOps-based continuous delivery

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

Set up the training namespace:

```bash
kubectl create namespace training --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=training
```

> **🧹 Start from a clean slate (recommended):** This lab assumes **all three nodes are schedulable** and the `training` namespace is **empty**. If you completed **Module 06** (Node management), a worker may still be **cordoned** — look for `SchedulingDisabled` in `kubectl get nodes` — and leftover workloads (e.g. a `drain-test` Deployment) may remain. A cordoned node will skew the StatefulSet, DaemonSet, and Helm exercises. Reset before starting:
> ```bash
> # Re-enable scheduling on any cordoned nodes
> kubectl get nodes -o name | xargs kubectl uncordon
> # Remove leftover workloads from earlier modules
> kubectl delete deployment drain-test -n training --ignore-not-found
> ```
> For a guaranteed-clean environment, recreate the namespace — or the whole cluster:
> ```bash
> # Option A: just reset the namespace
> kubectl delete namespace training --ignore-not-found
> kubectl create namespace training
> kubectl config set-context --current --namespace=training
>
> # Option B: rebuild the cluster from scratch (from the repo root)
> kind delete cluster --name training
> kind create cluster --name training --config kind-config.yaml
> ```

Verify Helm is installed:

```bash
helm version
```

Expected output:
```
version.BuildInfo{Version:"v4.2.0", ...}
```

> **📝 Note:** If Helm is not installed, run:
> ```bash
> curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
> ```
> The course standardizes on Helm 4. Helm 3 also works for everything in this lab, but the install script and a few subcommand defaults differ.

> **⏱️ Time check:** Exercises 1 (StatefulSet), 2 (DaemonSet), and the core of 4 (Helm install + upgrade + rollback) are core (~30 min). Exercise 3 (CronJob — needs minute-cadence wait time), the Helm rollback inspection, and Exercise 5 (Argo CD) are take-home / instructor demo. Pre-pulled images (see [`INSTRUCTOR_GUIDE.md`](../INSTRUCTOR_GUIDE.md)) make the difference between fitting in 30 min and overrunning by 15+ min.

---

## Exercise 1: StatefulSet

In this exercise, you'll deploy a StatefulSet and explore the guarantees it provides — stable network identity, ordered scaling, and per-replica persistent storage.

### Step 1: Create the Headless Service

A headless Service is required for StatefulSets to provide DNS records for each Pod:

```bash
kubectl apply -f manifests/headless-service.yaml
```

Verify the Service was created:

```bash
kubectl get service nginx-headless -n training
```

Expected output:
```
NAME             TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
nginx-headless   ClusterIP   None         <none>        80/TCP    10s
```

Notice `CLUSTER-IP` is `None` — this is a headless Service.

### Step 2: Deploy the StatefulSet

Deploy the StatefulSet with 3 replicas:

```bash
kubectl apply -f manifests/statefulset.yaml
```

Watch the Pods being created **in order**:

```bash
kubectl get pods -l app=nginx-stateful -n training -w
```

Expected output (Pods appear one at a time, in order):
```
NAME    READY   STATUS    RESTARTS   AGE
web-0   0/1     Pending   0          0s
web-0   1/1     Running   0          5s
web-1   0/1     Pending   0          0s
web-1   1/1     Running   0          5s
web-2   0/1     Pending   0          0s
web-2   1/1     Running   0          5s
```

Press `Ctrl+C` to stop watching.

> **🔑 Key Concept:** Notice the ordinal naming: `web-0`, `web-1`, `web-2`. Each Pod has a predictable, stable name — unlike Deployment Pods which get random suffixes.

### Step 3: Verify Per-Replica PVCs

Check the PersistentVolumeClaims created by `volumeClaimTemplates`:

```bash
kubectl get pvc -n training
```

Expected output:
```
NAME               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   AGE
www-data-web-0     Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   100Mi      RWO            60s
www-data-web-1     Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   100Mi      RWO            55s
www-data-web-2     Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   100Mi      RWO            50s
```

Each Pod gets its own PVC — `www-data-web-0`, `www-data-web-1`, `www-data-web-2`.

### Step 4: Test DNS Resolution

Write unique content to each Pod to prove they have separate storage:

```bash
# Write a unique page to each Pod
for i in 0 1 2; do
  kubectl exec web-$i -n training -- sh -c "echo 'Hello from web-$i' > /usr/share/nginx/html/index.html"
done
```

Verify each Pod serves its own content. Stock `nginx:1.30.0` doesn't ship `curl`, so we hit each replica from a netshoot debug Pod that *does* (one Pod, three queries):

```bash
kubectl run netshoot --image=nicolaka/netshoot:v0.14 --restart=Never -i --rm --tty=false -- \
  bash -c '
    for i in 0 1 2; do
      echo "--- web-$i ---"
      curl -s "http://web-$i.nginx-headless.training.svc.cluster.local"
    done
  '
```

Expected output:
```
--- web-0 ---
Hello from web-0
--- web-1 ---
Hello from web-1
--- web-2 ---
Hello from web-2
```

Now test DNS resolution using a debug Pod:

```bash
kubectl run dns-test --image=busybox:1.37.0 --restart=Never -n training \
  -- sh -c "nslookup web-0.nginx-headless.training.svc.cluster.local && sleep 10"
```

Wait for the Pod to complete and check the logs:

```bash
kubectl wait --for=condition=Ready pod/dns-test -n training --timeout=30s
kubectl logs dns-test -n training
```

Expected output:
```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:   web-0.nginx-headless.training.svc.cluster.local
Address: 10.244.x.x
```

Clean up the debug Pod:

```bash
kubectl delete pod dns-test -n training
```

### Step 5: Scale Down and Observe Graceful Termination

Scale the StatefulSet down to 2 replicas:

```bash
kubectl scale statefulset web --replicas=2 -n training
```

Watch the Pods:

```bash
kubectl get pods -l app=nginx-stateful -n training -w
```

Expected output (web-2 is terminated **first**, in reverse order):
```
NAME    READY   STATUS        RESTARTS   AGE
web-0   1/1     Running       0          5m
web-1   1/1     Running       0          5m
web-2   1/1     Terminating   0          5m
```

Press `Ctrl+C` to stop watching.

### Step 6: Verify PVCs Persist After Pod Deletion

Even though web-2 was deleted, its PVC still exists:

```bash
kubectl get pvc -n training
```

Expected output:
```
NAME               STATUS   VOLUME          CAPACITY   ACCESS MODES   AGE
www-data-web-0     Bound    pvc-xxxxxxxx    100Mi      RWO            6m
www-data-web-1     Bound    pvc-xxxxxxxx    100Mi      RWO            6m
www-data-web-2     Bound    pvc-xxxxxxxx    100Mi      RWO            6m
```

> **🔑 Key Concept:** PVCs created by `volumeClaimTemplates` are **not deleted** when Pods are removed. This ensures data is preserved. You must delete PVCs manually if cleanup is needed.

Scale back up and verify the data persists:

```bash
kubectl scale statefulset web --replicas=3 -n training
kubectl wait --for=condition=Ready pod/web-2 -n training --timeout=60s
kubectl exec web-2 -n training -- cat /usr/share/nginx/html/index.html
```

Expected output:
```
Hello from web-2
```

The data from Step 4 is still there — persistent storage works across Pod restarts.

---

## Exercise 2: DaemonSet

### Step 1: Deploy the DaemonSet

Create a DaemonSet that runs a log collector on every node:

```bash
kubectl apply -f manifests/daemonset.yaml
```

### Step 2: Verify One Pod Per Node

Check the DaemonSet status:

```bash
kubectl get daemonset log-collector -n training
```

Expected output:
```
NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
log-collector   3         3         3       3            3           <none>           30s
```

Verify each Pod is running on a different node:

```bash
kubectl get pods -l app=log-collector -n training -o wide
```

Expected output:
```
NAME                  READY   STATUS    RESTARTS   AGE   IP           NODE
log-collector-xxxxx   1/1     Running   0          30s   10.244.0.x   training-control-plane
log-collector-yyyyy   1/1     Running   0          30s   10.244.1.x   training-worker
log-collector-zzzzz   1/1     Running   0          30s   10.244.2.x   training-worker2
```

> **🔑 Key Concept:** Notice each Pod is on a different node. The DaemonSet controller ensures exactly one Pod per node. The tolerations in the manifest allow the Pod to run on the control-plane node too.

### Step 3: Check Pod Logs

```bash
# Get logs from one of the DaemonSet Pods
kubectl logs -l app=log-collector -n training --tail=3
```

Expected output:
```
Log collector started on log-collector-xxxxx
[Mon Jan  1 12:00:00 UTC 2025] Collecting logs from log-collector-xxxxx...
[Mon Jan  1 12:00:30 UTC 2025] Collecting logs from log-collector-xxxxx...
```

### Step 4: Restrict to Specific Nodes with Node Selector

Label one of the worker nodes:

```bash
kubectl label node training-worker node-type=logging
```

Now observe the current DaemonSet — it runs on all nodes. To restrict it, we need to add a `nodeSelector`. Let's patch the DaemonSet:

```bash
kubectl patch daemonset log-collector -n training --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/nodeSelector", "value": {"node-type": "logging"}}]'
```

Check which Pods remain:

```bash
kubectl get pods -l app=log-collector -n training -o wide
```

Expected output (only the labeled node has a Pod):
```
NAME                  READY   STATUS    RESTARTS   AGE   IP           NODE
log-collector-yyyyy   1/1     Running   0          10s   10.244.1.x   training-worker
```

> **💡 Tip:** DaemonSets respect node selectors, taints, and tolerations — just like regular Pods. This lets you target specific node pools (e.g., GPU nodes, storage nodes).

Remove the node label and revert the DaemonSet:

```bash
kubectl label node training-worker node-type-
kubectl patch daemonset log-collector -n training --type='json' \
  -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector"}]'
```

---

## Exercise 3: CronJob

### Step 1: Create the CronJob

Deploy a CronJob that runs every minute:

```bash
kubectl apply -f manifests/cronjob.yaml
```

Verify the CronJob was created:

```bash
kubectl get cronjob periodic-task -n training
```

Expected output:
```
NAME            SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
periodic-task   */1 * * * *   False     0        <none>          10s
```

### Step 2: Watch Jobs Being Created

Wait for the CronJob to trigger its first Job (up to 1 minute):

```bash
kubectl get jobs -l app=periodic-task -n training -w
```

Expected output (a new Job appears every minute):
```
NAME                       COMPLETIONS   DURATION   AGE
periodic-task-28437590     1/1           5s         60s
periodic-task-28437591     0/1                      0s
periodic-task-28437591     1/1           3s         3s
```

Press `Ctrl+C` to stop watching.

### Step 3: Inspect Completed Jobs and Logs

List the Jobs created by the CronJob:

```bash
kubectl get jobs -l app=periodic-task -n training
```

Check the logs from a completed Job:

```bash
# Get the most recent Job's Pod
kubectl logs -l app=periodic-task -n training --tail=5
```

Expected output:
```
=== Periodic task started at Mon Jan  1 12:01:00 UTC 2025 ===
Hostname: periodic-task-28437590-xxxxx
Task completed successfully!
```

### Step 4: Observe History Limits

Wait for a few minutes to let multiple Jobs run. Then check the history:

```bash
kubectl get jobs -l app=periodic-task -n training
```

You should see at most 3 completed Jobs (due to `successfulJobsHistoryLimit: 3`). Older Jobs are automatically cleaned up.

### Step 5: Create a One-Time Job from the CronJob

You can manually trigger a CronJob without waiting for the schedule:

```bash
kubectl create job manual-task --from=cronjob/periodic-task -n training
```

Verify the manually triggered Job:

```bash
kubectl get jobs manual-task -n training
kubectl wait --for=condition=complete job/manual-task -n training --timeout=30s
kubectl logs job/manual-task -n training
```

Expected output:
```
=== Periodic task started at Mon Jan  1 12:05:00 UTC 2025 ===
Hostname: manual-task-xxxxx
Task completed successfully!
```

---

## Exercise 4: Deploy with Helm

> **📝 Bitnami uses an OCI registry** for chart distribution. There's no `helm repo add` step — install directly with `oci://registry-1.docker.io/bitnamicharts/<chart>`.

### Step 1: Inspect the Chart

```bash
# Show the chart's metadata and default values
helm show chart oci://registry-1.docker.io/bitnamicharts/nginx
helm show values oci://registry-1.docker.io/bitnamicharts/nginx | head -40
```

### Step 2: Install nginx with Custom Values

Install the nginx chart using the custom values file:

```bash
helm install my-nginx oci://registry-1.docker.io/bitnamicharts/nginx \
  -f manifests/helm-values.yaml -n training
```

Expected output:
```
NAME: my-nginx
LAST DEPLOYED: ...
NAMESPACE: training
STATUS: deployed
REVISION: 1
...
```

Verify the installation:

```bash
helm list -n training
kubectl get deployments -n training -l app.kubernetes.io/instance=my-nginx
kubectl get services -n training -l app.kubernetes.io/instance=my-nginx
```

Wait for the Pods to be ready:

```bash
kubectl rollout status deployment my-nginx -n training --timeout=120s
```

### Step 3: Override Values with --set

Upgrade the release to change the replica count:

```bash
helm upgrade my-nginx oci://registry-1.docker.io/bitnamicharts/nginx \
  -f manifests/helm-values.yaml --set replicaCount=3 -n training
```

Verify the change:

```bash
kubectl get pods -l app.kubernetes.io/instance=my-nginx -n training
```

Expected output (3 Pods now):
```
NAME                        READY   STATUS    RESTARTS   AGE
my-nginx-xxxxxxxx-xxxxx     1/1     Running   0          30s
my-nginx-xxxxxxxx-yyyyy     1/1     Running   0          30s
my-nginx-xxxxxxxx-zzzzz     1/1     Running   0          10s
```

### Step 4: View Release History and Rollback

View the release history:

```bash
helm history my-nginx -n training
```

Expected output:
```
REVISION    UPDATED                     STATUS      CHART           APP VERSION     DESCRIPTION
1           Mon Jan  1 12:00:00 2025    superseded  nginx-x.x.x    x.x.x          Install complete
2           Mon Jan  1 12:05:00 2025    deployed    nginx-x.x.x    x.x.x          Upgrade complete
```

Rollback to revision 1:

```bash
helm rollback my-nginx 1 -n training
```

Expected output:
```
Rollback was a success! Happy Helming!
```

Verify the rollback:

```bash
kubectl get pods -l app.kubernetes.io/instance=my-nginx -n training
helm history my-nginx -n training
```

The replica count should be back to 2 (from the original values file).

### Step 5: Uninstall the Release

```bash
helm uninstall my-nginx -n training
```

Expected output:
```
release "my-nginx" uninstalled
```

Verify all resources were removed:

```bash
kubectl get all -l app.kubernetes.io/instance=my-nginx -n training
```

Expected output:
```
No resources found in training namespace.
```

---

## Exercise 5: ArgoCD Introduction (Optional / Instructor demo)

> **📝 Note:** Optional, usually instructor-led. The setup takes a few minutes — the recommended path is to have the trainer run the bundled prep script *before* the session and walk through the result live. Learners can then experiment with sync/self-heal without waiting on installs.

### Quickstart (if you're following along on your own laptop)

The repo includes a one-shot script that stands up **Gitea** locally as the Git source of truth and **Argo CD** as the GitOps controller, then seeds a sample repo and Application. It's idempotent — safe to re-run.

```bash
# From the repo root:
./scripts/argocd-lab-prep.sh
```

When it finishes, it prints two `kubectl port-forward` commands (one for Gitea, one for Argo CD), the credentials, and a couple of suggested demo edits. Skip ahead to **Step 4** ("Observe Sync and Health Status") below — Steps 1–3 are unnecessary because the script has already done them.

To clean up at the end:
```bash
./scripts/argocd-lab-teardown.sh
```

### Manual steps (if you want to walk through the install yourself)

#### Step 1: Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.1/manifests/install.yaml
```

Wait for ArgoCD to be ready:

```bash
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s
```

### Step 2: Access the ArgoCD UI

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
```

Port-forward the ArgoCD API server:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

Open a browser and navigate to `https://localhost:8080`. Log in with:
- **Username:** `admin`
- **Password:** (the password from the command above)

> **⚠️ Warning:** The default certificate is self-signed. Accept the browser warning to proceed.

### Step 3: Create an Application

Apply the ArgoCD Application manifest:

```bash
kubectl apply -f manifests/argocd-application.yaml
```

Or create it via the ArgoCD CLI:

```bash
# Install ArgoCD CLI (if not installed)
# curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/v3.4.1/argocd-linux-amd64
# chmod +x argocd && sudo mv argocd /usr/local/bin/

argocd login localhost:8080 --username admin --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) --insecure

argocd app create sample-app \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path guestbook \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace training \
  --sync-policy automated
```

### Step 4: Observe Sync and Health Status

> **📝 Two paths land here.** If you used the **Quickstart prep script**, the Application is named `gitops-demo` and its workload runs in the `gitops-demo` namespace — use those names below. If you followed the **Manual steps** above instead, substitute your own names (`sample-app`, workload `guestbook-ui`, namespace `training`).

In the ArgoCD UI, you should see the `gitops-demo` application with:
- **Sync Status:** Synced (or syncing)
- **Health Status:** Healthy (once all resources are running)

From the CLI:

```bash
# Via kubectl — no Argo CD CLI required:
kubectl -n argocd get application gitops-demo

# Or, if you installed the Argo CD CLI:
argocd app get gitops-demo
```

Verify the deployed resources:

```bash
kubectl get all -n gitops-demo -l app=gitops-demo
```

### Step 5: Observe Self-Healing

Make a manual change and watch ArgoCD revert it:

```bash
# Manually scale the deployment (this creates drift)
kubectl scale deployment gitops-demo -n gitops-demo --replicas=5

# Wait a moment, then check — ArgoCD should revert to the Git-defined state
sleep 60
kubectl get deployment gitops-demo -n gitops-demo
```

The replica count should revert to what's defined in Git (back to 2 — self-healing in action). If you followed the manual path, scale `guestbook-ui` in the `training` namespace instead.

---

## Verification

Confirm all lab exercises completed successfully:

```bash
# 1. StatefulSet is running with ordinal naming
kubectl get pods -l app=nginx-stateful -n training
# Expected: web-0, web-1, web-2 (Running)

# 2. Per-replica PVCs exist
kubectl get pvc -n training | grep www-data
# Expected: www-data-web-0, www-data-web-1, www-data-web-2

# 3. DaemonSet runs on every node
kubectl get daemonset log-collector -n training
# Expected: DESIRED=CURRENT=READY (matches node count)

# 4. CronJob has created Jobs
kubectl get cronjob periodic-task -n training
kubectl get jobs -l app=periodic-task -n training
# Expected: CronJob exists with LAST SCHEDULE set, Jobs visible

# 5. Helm release was managed (already uninstalled)
helm list -n training
```

---

## Cleanup

Remove all resources created during this lab:

```bash
# Delete StatefulSet and headless Service
kubectl delete statefulset web -n training
kubectl delete service nginx-headless -n training

# Delete PVCs (not automatically deleted with StatefulSet!)
kubectl delete pvc www-data-web-0 www-data-web-1 www-data-web-2 -n training --ignore-not-found

# Delete DaemonSet
kubectl delete daemonset log-collector -n training

# Delete CronJob (and all its Jobs)
kubectl delete cronjob periodic-task -n training
kubectl delete job manual-task -n training --ignore-not-found

# Delete remaining Jobs
kubectl delete jobs -l app=periodic-task -n training --ignore-not-found
kubectl delete jobs -l app=pi-calculator -n training --ignore-not-found

# Delete ArgoCD (if installed)
kubectl delete -f manifests/argocd-application.yaml --ignore-not-found
kubectl delete namespace argocd --ignore-not-found

# Remove node labels
kubectl label node training-worker node-type- --ignore-not-found
```

Or delete and recreate the namespace:

```bash
kubectl delete namespace training
kubectl create namespace training
```

---

## Bonus Challenges

### Challenge 1: Create a Custom Helm Chart

Create a simple Helm chart for a custom application:

1. Scaffold a new chart with `helm create`
2. Customize `values.yaml` with your own replicas, image, and service port
3. Add a ConfigMap template with application settings
4. Install and verify your chart

<details>
<summary>💡 Hint</summary>

Use `helm create my-app` to scaffold the chart, then modify:
- `values.yaml` — change the image repository to `hashicorp/http-echo` with tag `0.2.3`, then add custom args
- `templates/configmap.yaml` — create a new template for application configuration
- Use `helm template my-app ./my-app` to preview before installing
</details>

<details>
<summary>✅ Solution</summary>

```bash
# Create the chart
helm create my-app

# Modify values.yaml
cat > my-app/values.yaml << 'EOF'
replicaCount: 2
image:
  repository: hashicorp/http-echo
  tag: "0.2.3"
  pullPolicy: IfNotPresent
service:
  type: ClusterIP
  port: 80
containerPort: 5678
appSettings:
  message: "Hello from my custom chart!"
  environment: training
EOF

# Create a ConfigMap template
cat > my-app/templates/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "my-app.fullname" . }}-config
  namespace: {{ .Release.Namespace }}
data:
  MESSAGE: {{ .Values.appSettings.message | quote }}
  ENVIRONMENT: {{ .Values.appSettings.environment | quote }}
EOF

# Install the chart
helm install my-custom-app ./my-app -n training

# Verify
kubectl get all -l app.kubernetes.io/instance=my-custom-app -n training
kubectl get configmap -l app.kubernetes.io/instance=my-custom-app -n training

# Cleanup
helm uninstall my-custom-app -n training
rm -rf my-app
```
</details>

### Challenge 2: Parallel Job Processing

Create a Job that runs 6 completions with 3 parallel workers:

<details>
<summary>💡 Hint</summary>

Modify the Job manifest to set `completions: 6` and `parallelism: 3`. Each Pod should print its hostname so you can see different Pods running in parallel.
</details>

<details>
<summary>✅ Solution</summary>

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: parallel-job
  namespace: training
spec:
  completions: 6                     # Need 6 total completions
  parallelism: 3                     # Run 3 Pods at a time
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: worker
        image: busybox:1.37.0
        command:
        - sh
        - -c
        - |
          echo "Worker $(hostname) started at $(date)"
          sleep 5
          echo "Worker $(hostname) completed at $(date)"
        resources:
          requests:
            cpu: "25m"
            memory: "32Mi"
          limits:
            cpu: "50m"
            memory: "64Mi"
```

Apply and watch:
```bash
kubectl apply -f parallel-job.yaml
kubectl get pods -l job-name=parallel-job -n training -w
# You should see 3 Pods running simultaneously, then 3 more after those complete
kubectl delete job parallel-job -n training
```
</details>

---

> **🎉 Congratulations!** You've deployed StatefulSets with per-replica storage, DaemonSets for node-level workloads, CronJobs for scheduled tasks, and managed applications with Helm. In **Module 8**, we'll explore logging, monitoring with Prometheus and Grafana, and Kubernetes troubleshooting techniques.
