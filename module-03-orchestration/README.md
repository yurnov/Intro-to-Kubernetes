# Lab 3: Orchestrating Applications with Deployments, Services, and Probes

> **Duration:** 35 min
> **Prerequisites:** Module 3 theory, running Kubernetes cluster (kind with 3 nodes from Lab 1), `training` namespace created

## Objectives

1. Create multi-container Pods using init containers and sidecars
2. Deploy and manage applications with Deployments, including rolling updates and rollbacks
3. Expose applications using ClusterIP and NodePort Services
4. Configure liveness and readiness probes for production-ready health checking
5. Set resource requests and limits to ensure predictable scheduling and stability

## Before You Begin

Ensure your kind cluster from Lab 1 is still running and the `training` namespace is set as the default:

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

Verify the `training` namespace is your default context:

```bash
kubectl config get-contexts
```

Expected output (notice the NAMESPACE column):
```
CURRENT   NAME            CLUSTER         AUTHINFO        NAMESPACE
*         kind-training   kind-training   kind-training   training
```

> **🔧 Troubleshooting:** If the namespace is not set, run:
> ```bash
> kubectl create namespace training --dry-run=client -o yaml | kubectl apply -f -
> kubectl config set-context --current --namespace=training
> ```

> **⏱️ Time check:** Exercises 1–4 are core (~30 min). Exercise 5 (resource limits / OOMKill) and the bonus 2-tier app are take-home.

---

## Exercise 1: Multi-Container Pods

### Step 1: Create a Pod with an Init Container

Init containers run **before** the main containers start. They are commonly used for setup tasks like waiting for a dependency or pre-populating data.

Create the file `manifests/init-container-pod.yaml`:

```yaml
# init-container-pod.yaml — Pod with an init container that writes a file
apiVersion: v1
kind: Pod
metadata:
  name: init-demo
  namespace: training
  labels:
    app: init-demo
spec:
  initContainers:
  - name: init-writer
    image: busybox:1.37.0
    command: ["sh", "-c", "echo 'Init complete!' > /work-dir/init-output.txt"]
    volumeMounts:
    - name: shared-data
      mountPath: /work-dir
  containers:
  - name: main-reader
    image: busybox:1.37.0
    command: ["sh", "-c", "cat /work-dir/init-output.txt && sleep 3600"]
    volumeMounts:
    - name: shared-data
      mountPath: /work-dir
  volumes:
  - name: shared-data
    emptyDir: {}
```

Apply the manifest:

```bash
kubectl apply -f manifests/init-container-pod.yaml
```

Expected output:
```
pod/init-demo created
```

### Step 2: Observe Init Container Completion

Watch the Pod go through its initialization phases:

```bash
kubectl get pod init-demo -w
```

Expected output (you'll see it progress):
```
NAME        READY   STATUS     RESTARTS   AGE
init-demo   0/1     Init:0/1   0          2s
init-demo   0/1     PodInitializing   0   3s
init-demo   1/1     Running    0          4s
```

Press `Ctrl+C` to stop watching.

Verify the init container wrote the file by checking the main container's logs:

```bash
kubectl logs init-demo -c main-reader
```

Expected output:
```
Init complete!
```

> **🔑 Key Concept:** Init containers run sequentially and must complete successfully before main containers start. If an init container fails, Kubernetes restarts the Pod. This pattern is useful for waiting on services, running database migrations, or downloading configuration.

### Step 3: Create a Pod with a Sidecar Container

The sidecar pattern adds a helper container alongside the main application container. A common use case is log collection.

Create the file `manifests/sidecar-pod.yaml`:

```yaml
# sidecar-pod.yaml — nginx with a busybox sidecar that tails access logs
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-demo
  namespace: training
  labels:
    app: sidecar-demo
spec:
  containers:
  - name: nginx
    image: nginx:1.30.0
    ports:
    - containerPort: 80
    volumeMounts:
    - name: log-volume
      mountPath: /var/log/nginx
  - name: log-reader
    image: busybox:1.37.0
    command: ["sh", "-c", "tail -f /var/log/nginx/access.log"]
    volumeMounts:
    - name: log-volume
      mountPath: /var/log/nginx
  volumes:
  - name: log-volume
    emptyDir: {}
```

Apply and verify:

```bash
kubectl apply -f manifests/sidecar-pod.yaml
```

Expected output:
```
pod/sidecar-demo created
```

### Step 4: Observe Sidecar Behavior

Check that the Pod has two containers:

```bash
kubectl get pod sidecar-demo
```

Expected output:
```
NAME           READY   STATUS    RESTARTS   AGE
sidecar-demo   2/2     Running   0          15s
```

> **📝 Note:** The `READY` column shows `2/2`, meaning both containers are running inside the Pod.

Generate traffic to nginx and watch the sidecar pick it up. Stock `nginx:1.30.0` doesn't ship `curl`, so port-forward and hit it from the host:

```bash
# Port-forward in the background; kill it after the request
kubectl port-forward sidecar-demo 8080:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 2
curl -s http://localhost:8080 -o /dev/null
kill $PF_PID 2>/dev/null

# Check the sidecar's log output
kubectl logs sidecar-demo -c log-reader
```

Expected output (from the log-reader):
```
127.0.0.1 - - [xx/xxx/xxxx:xx:xx:xx +0000] "GET / HTTP/1.1" 200 615 "-" "curl/x.x.x"
```

> **💡 Tip:** Use `-c <container-name>` with `kubectl logs` and `kubectl exec` when a Pod has multiple containers. Without it, kubectl defaults to the first container in the spec.

---

## Exercise 2: Deployments in Action

### Step 1: Create a Deployment

A Deployment manages a set of identical Pods (via a ReplicaSet), providing declarative updates, scaling, and self-healing.

Create the file `manifests/nginx-deployment.yaml`:

```yaml
# nginx-deployment.yaml — Deployment with 3 replicas of nginx
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  namespace: training
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.30.0
        ports:
        - containerPort: 80
```

Apply the manifest:

```bash
kubectl apply -f manifests/nginx-deployment.yaml
```

Expected output:
```
deployment.apps/nginx-deployment created
```

Verify the Deployment, ReplicaSet, and Pods:

```bash
kubectl get deployment nginx-deployment
kubectl get replicaset
kubectl get pods -l app=nginx
```

Expected output:
```
NAME               READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deployment   3/3     3            3           30s

NAME                          DESIRED   CURRENT   READY   AGE
nginx-deployment-xxxxxxxxxx   3         3         3       30s

NAME                                READY   STATUS    RESTARTS   AGE
nginx-deployment-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
nginx-deployment-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
nginx-deployment-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

### Step 2: Scale the Deployment

Scale from 3 to 5 replicas:

```bash
kubectl scale deployment nginx-deployment --replicas=5
```

Watch the new Pods come up:

```bash
kubectl get pods -l app=nginx
```

Expected output:
```
NAME                                READY   STATUS    RESTARTS   AGE
nginx-deployment-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
nginx-deployment-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
nginx-deployment-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
nginx-deployment-xxxxxxxxxx-xxxxx   1/1     Running   0          5s
nginx-deployment-xxxxxxxxxx-xxxxx   1/1     Running   0          5s
```

Check which nodes the Pods are distributed across:

```bash
kubectl get pods -l app=nginx -o wide
```

> **📝 Note:** The scheduler distributes Pods across available worker nodes. You should see Pods on both `training-worker` and `training-worker2`.

### Step 3: Perform a Rolling Update

The Deployment is currently running `nginx:1.30.0`. Roll forward to the previous patch (`nginx:1.29.8`) so we have a real diff to roll over:

```bash
# Update the image tag — this is what triggers the rollout
kubectl set image deployment/nginx-deployment nginx=nginx:1.29.8

# Annotate the cause (the modern replacement for the deprecated --record flag)
kubectl annotate deployment/nginx-deployment \
  kubernetes.io/change-cause="downgrade to nginx 1.29.8 to test rollout" --overwrite
```

Watch the rollout progress:

```bash
kubectl rollout status deployment/nginx-deployment
```

Expected output:
```
Waiting for deployment "nginx-deployment" rollout to finish: 2 out of 5 new replicas have been updated...
Waiting for deployment "nginx-deployment" rollout to finish: 3 out of 5 new replicas have been updated...
Waiting for deployment "nginx-deployment" rollout to finish: 4 out of 5 new replicas have been updated...
deployment "nginx-deployment" successfully rolled out
```

### Step 4: View Rollout History

```bash
kubectl rollout history deployment/nginx-deployment
```

Expected output:
```
deployment.apps/nginx-deployment
REVISION  CHANGE-CAUSE
1         <none>
2         downgrade to nginx 1.29.8 to test rollout
```

> **📝 Note:** Older lab material used `kubectl ... --record`; that flag is deprecated and the modern equivalent is the `kubernetes.io/change-cause` annotation we set above.

Get details on a specific revision:

```bash
kubectl rollout history deployment/nginx-deployment --revision=2
```

### Step 5: Rollback to the Previous Version

Roll back to the previous revision:

```bash
kubectl rollout undo deployment/nginx-deployment
```

Expected output:
```
deployment.apps/nginx-deployment rolled back
```

Verify the rollback — image should be back at the original tag:

```bash
kubectl rollout status deployment/nginx-deployment
kubectl describe deployment nginx-deployment | grep Image
```

Expected output:
```
    Image:        nginx:1.30.0
```

> **🔑 Key Concept:** Kubernetes keeps a history of Deployment revisions (controlled by `revisionHistoryLimit`). You can roll back to any previous revision using `kubectl rollout undo --to-revision=N`. This makes safe, reversible releases straightforward.

Scale back to 3 replicas for the remaining exercises:

```bash
kubectl scale deployment nginx-deployment --replicas=3
```

---

## Exercise 3: Services

### Step 1: Create a ClusterIP Service

A **ClusterIP** Service gives the Deployment a stable internal IP and DNS name, load-balancing across all matching Pods.

Create the file `manifests/nginx-service-clusterip.yaml`:

```yaml
# nginx-service-clusterip.yaml — ClusterIP Service for nginx
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
  namespace: training
spec:
  type: ClusterIP
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
```

Apply the manifest:

```bash
kubectl apply -f manifests/nginx-service-clusterip.yaml
```

Expected output:
```
service/nginx-service created
```

Verify the Service and its Endpoints:

```bash
kubectl get service nginx-service
kubectl get endpoints nginx-service
```

Expected output:
```
NAME            TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
nginx-service   ClusterIP   10.96.xxx.xxx   <none>        80/TCP    10s

NAME            ENDPOINTS                                      AGE
nginx-service   10.244.x.x:80,10.244.x.x:80,10.244.x.x:80    10s
```

> **📝 Note:** The Endpoints list should show 3 Pod IPs (one per replica). The Service load-balances traffic across these Pods.

### Step 2: Test Service DNS Resolution

Create a debug Pod to test DNS and connectivity from within the cluster.

Create the file `manifests/debug-pod.yaml`:

```yaml
# debug-pod.yaml — Pod for testing DNS and connectivity
apiVersion: v1
kind: Pod
metadata:
  name: debug-pod
  namespace: training
  labels:
    app: debug
spec:
  containers:
  - name: debug
    image: busybox:1.37.0
    command: ["sleep", "3600"]
```

Apply and test:

```bash
kubectl apply -f manifests/debug-pod.yaml

# Wait for the debug Pod to be ready
kubectl wait --for=condition=Ready pod/debug-pod --timeout=30s
```

Test DNS resolution and connectivity:

```bash
# Resolve the Service DNS name
kubectl exec debug-pod -- nslookup nginx-service

# Access the Service by name
kubectl exec debug-pod -- wget -qO- http://nginx-service
```

Expected output (from nslookup):
```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      nginx-service.training.svc.cluster.local
Address:   10.96.xxx.xxx
```

> **🔑 Key Concept:** Kubernetes DNS automatically creates records for Services. Within the same namespace, use the Service name (e.g., `nginx-service`). Across namespaces, use the fully qualified name: `<service>.<namespace>.svc.cluster.local`.

### Step 3: Create a NodePort Service

A **NodePort** Service exposes the application on a static port on every node, making it accessible from outside the cluster.

The course's `kind-config.yaml` already maps host port **80** to the control-plane node, so we'll bind the NodePort Service to that mapped port for end-to-end access from your laptop.

Create the file `manifests/nginx-service-nodeport.yaml`:

```yaml
# nginx-service-nodeport.yaml — NodePort Service exposed via the host:80 mapping
apiVersion: v1
kind: Service
metadata:
  name: nginx-nodeport
  namespace: training
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
  - port: 80                # ClusterIP-side port
    targetPort: 80          # Pod port
    nodePort: 30080         # Node-side port (bound on every node)
    protocol: TCP
```

Apply the manifest:

```bash
kubectl apply -f manifests/nginx-service-nodeport.yaml
```

Verify the Service:

```bash
kubectl get service nginx-nodeport
```

Expected output:
```
NAME             TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
nginx-nodeport   NodePort   10.96.xxx.xxx   <none>        80:30080/TCP   10s
```

> **💡 Access from your host:** the kind config maps `hostPort: 80 → containerPort: 80` on the control-plane node, *not* the NodePort range. To exercise NodePort end-to-end without touching the kind config, port-forward instead:
> ```bash
> kubectl port-forward service/nginx-nodeport 8080:80
> curl http://localhost:8080
> ```
> If you want true `<node-ip>:30080` access, add `extraPortMappings: [{containerPort: 30080, hostPort: 30080}]` under the control-plane node in `kind-config.yaml` and recreate the cluster.

### Step 4: Observe Endpoints When Scaling

Watch how Endpoints update when you change the replica count:

```bash
# Check current Endpoints
kubectl get endpoints nginx-service

# Scale down to 1 replica
kubectl scale deployment nginx-deployment --replicas=1

# Check Endpoints again
kubectl get endpoints nginx-service
```

Expected output:
```
NAME            ENDPOINTS        AGE
nginx-service   10.244.x.x:80   5m
```

The Endpoints list now shows only 1 Pod IP. Scale back up:

```bash
kubectl scale deployment nginx-deployment --replicas=3

# Verify Endpoints updated
kubectl get endpoints nginx-service
```

Expected output:
```
NAME            ENDPOINTS                                      AGE
nginx-service   10.244.x.x:80,10.244.x.x:80,10.244.x.x:80    5m
```

> **📝 Note:** The Endpoints controller continuously watches for Pods that match the Service's selector and updates the Endpoints list automatically. This is how Services provide dynamic load balancing.

---

## Exercise 4: Health Checks

### Step 1: Deploy with Liveness and Readiness Probes

Probes tell Kubernetes how to check if your container is healthy and ready to serve traffic.

Create the file `manifests/deployment-with-probes.yaml`:

```yaml
# deployment-with-probes.yaml — Deployment with liveness and readiness probes
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probed-app
  namespace: training
  labels:
    app: probed-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: probed-app
  template:
    metadata:
      labels:
        app: probed-app
    spec:
      containers:
      - name: app
        image: busybox:1.37.0
        command:
        - sh
        - -c
        - |
          touch /tmp/healthy
          touch /tmp/ready
          echo "App started"
          while true; do sleep 5; done
        livenessProbe:
          exec:
            command: ["cat", "/tmp/healthy"]
          initialDelaySeconds: 5
          periodSeconds: 5
        readinessProbe:
          exec:
            command: ["cat", "/tmp/ready"]
          initialDelaySeconds: 5
          periodSeconds: 5
```

Apply and verify:

```bash
kubectl apply -f manifests/deployment-with-probes.yaml

# Wait for Pods to be ready
kubectl rollout status deployment/probed-app
```

Expected output:
```
deployment "probed-app" successfully rolled out
```

```bash
kubectl get pods -l app=probed-app
```

Expected output:
```
NAME                          READY   STATUS    RESTARTS   AGE
probed-app-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
probed-app-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

### Step 2: Simulate a Liveness Failure

Delete the file that the liveness probe checks. Kubernetes will detect the failure and restart the container:

```bash
# Pick one of the Pods
POD_NAME=$(kubectl get pods -l app=probed-app -o jsonpath='{.items[0].metadata.name}')

# Delete the liveness check file
kubectl exec $POD_NAME -- rm /tmp/healthy

# Watch the Pod — it will be restarted after the probe fails
kubectl get pod $POD_NAME -w
```

Expected output (after ~15 seconds):
```
NAME                          READY   STATUS    RESTARTS      AGE
probed-app-xxxxxxxxxx-xxxxx   1/1     Running   0             2m
probed-app-xxxxxxxxxx-xxxxx   0/1     Running   1 (1s ago)    2m
probed-app-xxxxxxxxxx-xxxxx   1/1     Running   1 (3s ago)    2m
```

Press `Ctrl+C` to stop watching.

> **🔑 Key Concept:** When a **liveness probe** fails, the kubelet restarts the container. The Pod stays on the same node — Kubernetes doesn't reschedule it. After restart, the container runs its command again, recreating `/tmp/healthy`, so the probe starts passing again.

### Step 3: Simulate a Readiness Failure

Create a Service for the probed-app and observe how readiness affects Endpoints:

```bash
# Create a quick Service
kubectl expose deployment probed-app --port=80 --target-port=80 --name=probed-svc

# Check current Endpoints
kubectl get endpoints probed-svc
```

Now simulate a readiness failure:

```bash
# Delete the readiness check file
kubectl exec $POD_NAME -- rm /tmp/ready

# Watch the Pod become not-ready (READY goes to 0/1)
kubectl get pod $POD_NAME -w
```

Expected output:
```
NAME                          READY   STATUS    RESTARTS      AGE
probed-app-xxxxxxxxxx-xxxxx   0/1     Running   1             3m
```

Press `Ctrl+C` and check the Endpoints:

```bash
kubectl get endpoints probed-svc
```

The unready Pod's IP is removed from the Endpoints — it no longer receives traffic.

> **⚠️ Warning:** A readiness failure does **not** restart the container (unlike liveness). It only removes the Pod from Service Endpoints. The Pod stays running but doesn't receive traffic until the probe passes again.

Restore readiness:

```bash
kubectl exec $POD_NAME -- touch /tmp/ready

# Verify the Pod is ready again
kubectl get pod $POD_NAME
kubectl get endpoints probed-svc
```

---

## Exercise 5: Resource Limits

### Step 1: Deploy with Resource Requests and Limits

Resource requests guarantee scheduling capacity; limits cap actual usage.

Create the file `manifests/deployment-with-limits.yaml`:

```yaml
# deployment-with-limits.yaml — Deployment with CPU and memory constraints
apiVersion: apps/v1
kind: Deployment
metadata:
  name: limited-app
  namespace: training
  labels:
    app: limited-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: limited-app
  template:
    metadata:
      labels:
        app: limited-app
    spec:
      containers:
      - name: nginx
        image: nginx:1.30.0
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
```

Apply the manifest:

```bash
kubectl apply -f manifests/deployment-with-limits.yaml
```

Verify the resource settings:

```bash
kubectl get pods -l app=limited-app
kubectl describe pod -l app=limited-app | grep -A 6 "Limits\|Requests"
```

Expected output:
```
    Limits:
      cpu:     100m
      memory:  128Mi
    Requests:
      cpu:     50m
      memory:  64Mi
```

### Step 2: Observe Resource Usage

Use `kubectl top` to view actual resource consumption (requires metrics-server):

```bash
kubectl top pod -l app=limited-app
```

Expected output:
```
NAME                           CPU(cores)   MEMORY(bytes)
limited-app-xxxxxxxxxx-xxxxx   1m           5Mi
limited-app-xxxxxxxxxx-xxxxx   1m           5Mi
```

> **📝 Note:** If `kubectl top` returns an error, the metrics-server may not be installed. On kind, install it with:
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml
> kubectl patch deployment metrics-server -n kube-system --type=json \
>   -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
> ```
> Wait 1-2 minutes for metrics to become available.

### Step 3: (Optional) Trigger an OOMKill

Set a low memory limit and have the container deliberately allocate past it, so the kernel OOM killer terminates the process **after** it has started running. The deprecated `kubectl run --limits` flag is gone, so we use a Pod manifest:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: oom-test
  namespace: training
  labels:
    app: oom-test
spec:
  restartPolicy: Never
  containers:
  - name: memory-hog
    image: busybox:1.37.0
    # /cache is tmpfs (medium: Memory) — its content counts against the
    # container's memory limit, so writing 64 MiB into a container limited
    # to 16 MiB reliably triggers the cgroup OOM killer at runtime.
    command: ["sh", "-c", "dd if=/dev/zero of=/cache/hog bs=1M count=64; sleep 60"]
    resources:
      requests:
        memory: "16Mi"
      limits:
        memory: "16Mi"
    volumeMounts:
    - name: cache
      mountPath: /cache
  volumes:
  - name: cache
    emptyDir:
      medium: Memory     # tmpfs — its content counts against the container's memory limit
      sizeLimit: 128Mi
EOF
```

Watch the Pod:

```bash
kubectl get pod oom-test -w
```

Expected output:
```
NAME       READY   STATUS      RESTARTS   AGE
oom-test   0/1     OOMKilled   0          5s
```

Press `Ctrl+C` to stop watching.

```bash
kubectl describe pod oom-test -n training | grep -A 3 "State:"
```

Expected output:
```
State:          Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

> **💡 Why busybox + tmpfs instead of nginx with a tiny limit?**
> A 4 MiB limit on `nginx` is too small for the process to even start, so the kubelet reports the pod as `StartError` rather than `OOMKilled` — which hides the lesson. By giving busybox enough headroom to start (16 MiB) and then having it write past the limit, we guarantee a runtime OOM kill, which the kubelet records as `containerStatuses[*].lastState.terminated.reason: OOMKilled`.

> **⚠️ Warning:** When a container exceeds its memory limit, the kernel OOM killer terminates the process. With `restartPolicy: Always`, this results in a `CrashLoopBackOff`. Always set memory limits high enough for your application's normal operation.

Clean up the test Pod:

```bash
kubectl delete pod oom-test
```

---

## Verification

Confirm everything works correctly:

```bash
# 1. Init container Pod ran successfully
kubectl logs init-demo -c main-reader
# Expected: "Init complete!"

# 2. Sidecar Pod has 2/2 ready containers
kubectl get pod sidecar-demo
# Expected: 2/2 Running

# 3. Deployment has 3 replicas
kubectl get deployment nginx-deployment
# Expected: 3/3 READY

# 4. ClusterIP Service has correct Endpoints
kubectl get endpoints nginx-service
# Expected: 3 Pod IPs listed

# 5. DNS resolution works
kubectl exec debug-pod -- nslookup nginx-service
# Expected: resolves to the Service ClusterIP

# 6. Probed app is running with probes
kubectl get deployment probed-app
# Expected: 2/2 READY

# 7. Limited app has resource constraints
kubectl describe pod -l app=limited-app | grep -A 2 "Limits"
# Expected: cpu: 100m, memory: 128Mi
```

---

## Cleanup

Remove all resources created during this lab:

```bash
# Delete all resources from manifests
kubectl delete -f manifests/ --ignore-not-found

# Delete the imperatively created Service
kubectl delete service probed-svc --ignore-not-found

# Verify cleanup
kubectl get all -n training
# Expected: No resources found in training namespace.
```

Or reset the entire namespace:

```bash
kubectl delete namespace training
kubectl create namespace training
kubectl config set-context --current --namespace=training
```

---

## Bonus Challenge

### Challenge: Build a 2-Tier Application

Deploy a complete 2-tier application with a **Valkey** backend and a **web frontend**, including probes, resource limits, and Services for both tiers. Verify that the frontend can communicate with the backend through Kubernetes Services.

Requirements:
1. Deploy Valkey (1 replica) with a ClusterIP Service, liveness probe, and resource limits
2. Deploy an nginx frontend (2 replicas) with a ClusterIP Service, readiness probe, and resource limits
3. Verify the frontend can resolve and connect to the backend Service

<details>
<summary>💡 Hint</summary>

- Use `valkey/valkey:9.0.3` for the backend and `nginx:1.30.0` for the frontend
- Valkey listens on port `6379` — a TCP liveness probe works well for it
- Name the Valkey Service `valkey-backend` so the frontend can reach it via DNS
- Use `kubectl exec` from a frontend Pod to test connectivity with `wget` or by installing a Valkey CLI
- Set sensible resource limits (e.g., 100m CPU / 128Mi memory for each tier)
</details>

<details>
<summary>✅ Solution</summary>

**1. Valkey Backend Deployment and Service:**

```yaml
# valkey-backend.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valkey-backend
  namespace: training
  labels:
    app: valkey
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: valkey
      tier: backend
  template:
    metadata:
      labels:
        app: valkey
        tier: backend
    spec:
      containers:
      - name: valkey
        image: valkey/valkey:9.0.3
        ports:
        - containerPort: 6379
        livenessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: valkey-backend
  namespace: training
spec:
  type: ClusterIP
  selector:
    app: valkey
    tier: backend
  ports:
  - port: 6379
    targetPort: 6379
    protocol: TCP
```

**2. Web Frontend Deployment and Service:**

```yaml
# web-frontend.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  namespace: training
  labels:
    app: web
    tier: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
      tier: frontend
  template:
    metadata:
      labels:
        app: web
        tier: frontend
    spec:
      containers:
      - name: nginx
        image: nginx:1.30.0
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: web-frontend
  namespace: training
spec:
  type: ClusterIP
  selector:
    app: web
    tier: frontend
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
```

**3. Deploy and verify:**

```bash
# Apply both manifests
kubectl apply -f valkey-backend.yaml
kubectl apply -f web-frontend.yaml

# Verify all resources are running
kubectl get deployments
kubectl get services
kubectl get pods

# Test cross-service communication from a netshoot debug Pod
# (the stock nginx image has neither curl nor nslookup; netshoot has both)
kubectl run netshoot --image=nicolaka/netshoot:v0.14 --restart=Never -it --rm -- \
  bash -c '
    echo "--- DNS lookup ---"
    nslookup valkey-backend
    echo "--- TCP probe ---"
    nc -zv valkey-backend 6379
  '
```

**4. Cleanup:**

```bash
kubectl delete -f valkey-backend.yaml
kubectl delete -f web-frontend.yaml
```
</details>

---

> **🎉 Congratulations!** You've deployed multi-container Pods, managed Deployments with rolling updates and rollbacks, exposed applications with Services, and configured health probes and resource limits. In **Module 4**, we'll explore persistent storage and Secrets management to handle stateful workloads and sensitive configuration.
