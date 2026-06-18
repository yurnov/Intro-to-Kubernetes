# Lab 4: Storage, ConfigMaps, and Secrets

> **Duration:** 35 min
> **Prerequisites:** Module 4 theory, running Kubernetes cluster (kind with 3 nodes from Lab 1)

## Objectives

1. Create a Pod with an `emptyDir` volume shared between two containers
2. Deploy PostgreSQL with persistent storage using PersistentVolumeClaims
3. Externalize nginx configuration using ConfigMaps
4. Create and consume Secrets for database credentials
5. Verify data persistence across Pod restarts

## Before You Begin

Ensure your kind cluster from Lab 1 is still running and the `training` namespace exists:

```bash
kubectl get nodes
```

Expected output:
```
NAME                     STATUS   ROLES           AGE   VERSION
training-control-plane   Ready    control-plane   3d    v1.36.1
training-worker          Ready    <none>          3d    v1.36.1
training-worker2         Ready    <none>          3d    v1.36.1
```

Set up the training namespace:

```bash
kubectl create namespace training --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=training
```

Check available StorageClasses:

```bash
kubectl get storageclass
```

Expected output:
```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   3d
```

> **📝 Note:** The `standard` StorageClass uses `rancher.io/local-path` provisioner in kind. This supports dynamic provisioning and `ReadWriteOnce` access mode.

> **⏱️ Time check:** Exercises 1–3 are core (~30 min). Exercise 4 (Secrets, including the docker-registry secret) and the bonus stack are take-home.

---

## Exercise 1: Volume Basics with emptyDir

### Step 1: Create a Pod with a Shared Volume

An `emptyDir` volume allows containers in the same Pod to share data. Let's create a Pod with two containers that communicate through a shared volume.

Examine the manifest:

```bash
cat manifests/emptydir-pod.yaml
```

Apply it:

```bash
kubectl apply -f manifests/emptydir-pod.yaml
```

### Step 2: Verify Both Containers Are Running

```bash
kubectl get pod emptydir-demo
```

Expected output:
```
NAME            READY   STATUS    RESTARTS   AGE
emptydir-demo   2/2     Running   0          30s
```

> **📝 Note:** `2/2` in the READY column means both containers are running.

### Step 3: Check the Writer Container

See what the writer container wrote to the shared volume:

```bash
kubectl exec emptydir-demo -c writer -- cat /shared-data/message.txt
```

Expected output (the timestamp varies):
```
Hello from the writer container!
Written at: <current date>
Hostname: emptydir-demo
```

### Step 4: Read from the Reader Container

Verify the reader container can see the same data:

```bash
kubectl exec emptydir-demo -c reader -- cat /shared-data/message.txt
```

You should see the exact same output — both containers share the volume.

### Step 5: Delete the Pod and Verify Data Loss

```bash
kubectl delete pod emptydir-demo
```

The `emptyDir` volume and all its data are permanently destroyed when the Pod is deleted.

> **🔑 Key Concept:** `emptyDir` volumes are tied to the Pod lifecycle. Use them for temporary, shared data only. For data that must survive Pod deletion, use PersistentVolumeClaims.

---

## Exercise 2: Persistent Storage with PostgreSQL

### Step 1: Create the PersistentVolumeClaim

First, create a PVC to request persistent storage:

```bash
kubectl apply -f manifests/pvc.yaml
```

Check the PVC status:

```bash
kubectl get pvc
```

Expected output:
```
NAME           STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
postgres-pvc   Pending                                      standard       10s
```

> **📝 Note:** The PVC shows `Pending` because the `standard` StorageClass uses `WaitForFirstConsumer` binding mode. The PV will be created when a Pod that uses this PVC is scheduled.

### Step 2: Create the Database Secret

Before deploying PostgreSQL, create the Secret with database credentials:

```bash
kubectl apply -f manifests/db-secret.yaml
```

Verify the Secret was created:

```bash
kubectl get secret db-credentials
```

Expected output:
```
NAME             TYPE     DATA   AGE
db-credentials   Opaque   2      5s
```

### Step 3: Deploy PostgreSQL with Persistent Storage

```bash
kubectl apply -f manifests/postgres-with-pvc.yaml
```

Wait for the Pod to be ready:

```bash
kubectl get pods -l app=postgres -w
```

Expected output (after ~30 seconds):
```
NAME                        READY   STATUS    RESTARTS   AGE
postgres-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

Press `Ctrl+C` to stop watching.

Now check the PVC again:

```bash
kubectl get pvc
```

Expected output:
```
NAME           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
postgres-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            standard       2m
```

The PVC is now `Bound` — a PV was dynamically provisioned!

### Step 4: Write Data to the Database

Connect to PostgreSQL and create a table with data:

```bash
# Get the Pod name
POSTGRES_POD=$(kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')

# Connect and create a table
kubectl exec -it $POSTGRES_POD -- psql -U trainuser -d trainingdb -c "
CREATE TABLE messages (
  id SERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO messages (content) VALUES ('Hello from Module 4!');
INSERT INTO messages (content) VALUES ('This data survives Pod restarts!');
SELECT * FROM messages;
"
```

Expected output (timestamps will reflect when you ran the inserts):
```
 id |             content              |         created_at
----+----------------------------------+---------------------------
  1 | Hello from Module 4!             | <ts1>
  2 | This data survives Pod restarts! | <ts2>
(2 rows)
```

### Step 5: Delete and Recreate PostgreSQL

Now delete the PostgreSQL Deployment and recreate it to prove data persistence:

```bash
# Delete the Deployment (this deletes the Pod)
kubectl delete deployment postgres

# Verify the Pod is gone
kubectl get pods -l app=postgres
# Expected: No resources found

# The PVC should still be Bound
kubectl get pvc postgres-pvc
```

Expected output:
```
NAME           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
postgres-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            standard       5m
```

Redeploy PostgreSQL:

```bash
kubectl apply -f manifests/postgres-with-pvc.yaml
```

Wait for the new Pod to be ready:

```bash
kubectl get pods -l app=postgres -w
```

### Step 6: Verify Data Persistence

```bash
POSTGRES_POD=$(kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it $POSTGRES_POD -- psql -U trainuser -d trainingdb -c "SELECT * FROM messages;"
```

Expected output (same two rows as before — same timestamps):
```
 id |             content              |         created_at
----+----------------------------------+---------------------------
  1 | Hello from Module 4!             | <ts1>
  2 | This data survives Pod restarts! | <ts2>
(2 rows)
```

🎉 The data survived the Pod deletion because it was stored on the PersistentVolume!

> **🔑 Key Concept:** PVCs decouple the storage lifecycle from the Pod lifecycle. The data lives in the PV, which persists independently of Pods, Deployments, and even namespaces (PVs are cluster-scoped).

---

## Exercise 3: ConfigMaps

### Step 1: Create a ConfigMap from a Literal

```bash
kubectl create configmap greeting \
  --from-literal=GREETING="Welcome to Kubernetes Training!" \
  --from-literal=MODULE="04 - Storage and Secrets"
```

Verify:

```bash
kubectl get configmap greeting -o yaml
```

You should see the key-value pairs in the `data` section.

### Step 2: Create a ConfigMap for nginx Configuration

Apply the ConfigMap that contains a custom nginx configuration:

```bash
kubectl apply -f manifests/configmap-nginx.yaml
```

Examine the ConfigMap:

```bash
kubectl describe configmap nginx-config
```

You should see two keys: `default.conf` and `index.html`.

### Step 3: Deploy nginx with the ConfigMap

```bash
kubectl apply -f manifests/nginx-with-configmap.yaml
```

Wait for the Pod to be ready:

```bash
kubectl get pods -l app=nginx-custom -w
```

### Step 4: Verify the Custom Configuration

Stock `nginx:1.30.0` doesn't include `curl`, so port-forward to the Pod and hit the endpoints from your host:

```bash
# Get the Pod name and port-forward in the background
NGINX_POD=$(kubectl get pod -l app=nginx-custom -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward "$NGINX_POD" 8080:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 2

# Test the custom HTML page, /info, and /healthz
curl -s http://localhost:8080/
curl -s http://localhost:8080/info
curl -s http://localhost:8080/healthz

# Stop the port-forward when you're done
kill $PF_PID 2>/dev/null
```

Expected output for `/info`:
```
Server: nginx
Configured via: Kubernetes ConfigMap
Module: 04 - Storage and Secrets
```

> **💡 Tip:** Inside the cluster you can hit the same endpoints from a debug Pod that *does* have `curl`:
> ```bash
> kubectl run netshoot --image=nicolaka/netshoot:v0.14 -it --rm --restart=Never -- \
>   curl -s http://nginx-configured/info
> ```
>
> **📝 Note:** `nginx-configured` resolves via the ClusterIP Service created in Module 03. If the Service is not present, apply it first: `kubectl apply -f ../module-03-orchestration/manifests/nginx-service-clusterip.yaml`.

### Step 5: Update the ConfigMap and Observe Changes

Update the ConfigMap:

```bash
kubectl patch configmap nginx-config --type merge -p '
{
  "data": {
    "index.html": "<!DOCTYPE html>\n<html>\n<body>\n<h1>Updated via ConfigMap!</h1>\n<p>This page was updated without rebuilding the container image.</p>\n</body>\n</html>\n"
  }
}'
```

Wait for the update to propagate (kubelet syncs ConfigMap-mounted volumes within ~60 seconds — exact latency depends on the kubelet's `configMapAndSecretChangeDetectionStrategy`):

```bash
# Poll the file until the new content lands (up to 90s)
for i in $(seq 1 18); do
  if kubectl exec "$NGINX_POD" -- cat /usr/share/nginx/html/index.html | grep -q "Updated via ConfigMap"; then
    echo "Update visible after ~${i}*5 seconds."
    break
  fi
  sleep 5
done

kubectl exec "$NGINX_POD" -- cat /usr/share/nginx/html/index.html
```

You should see the updated HTML content.

> **💡 Tip:** ConfigMap volume updates happen automatically, but nginx needs a reload to serve updated config files. For the HTML file (which is read on each request from `/usr/share/nginx/html`), the update is visible immediately after the volume sync.

---

## Exercise 4: Secrets

### Step 1: Examine the Existing Secret

We already created the `db-credentials` Secret in Exercise 2. Let's inspect it:

```bash
kubectl get secret db-credentials -o yaml
```

Notice that the values in the `data` field are base64-encoded. Decode them:

```bash
kubectl get secret db-credentials -o jsonpath='{.data.username}' | base64 --decode
echo

kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 --decode
echo
```

Expected output:
```
trainuser
Kub3rn3t3s-Tr@ining!
```

> **⚠️ Warning:** As you can see, base64 is trivially reversible. Secrets are encoded, not encrypted! Restrict access to Secrets using RBAC (covered in Module 6).

### Step 2: Deploy a Pod That Mounts the Secret

```bash
kubectl apply -f manifests/pod-with-secret.yaml
```

Wait for the Pod to be ready:

```bash
kubectl get pod secret-reader -w
```

### Step 3: Verify the Secret Contents

View the output of the reader container:

```bash
kubectl logs secret-reader
```

Expected output:
```
=== Secret mounted as files ===
Username: trainuser
Password file exists: yes

=== File permissions ===
total 0
lrwxrwxrwx    1 root     root            15 ... password -> ..data/password
lrwxrwxrwx    1 root     root            15 ... username -> ..data/username

=== Sleeping to allow inspection ===
```

You can also inspect the mounted Secret files directly:

```bash
# List files in the Secret mount
kubectl exec secret-reader -- ls -la /etc/db-credentials/

# Read the username
kubectl exec secret-reader -- cat /etc/db-credentials/username
```

### Step 4: Create a Docker Registry Secret

Create a Secret for pulling images from a private Docker registry:

```bash
kubectl create secret docker-registry my-registry-secret \
  --docker-server=registry.example.com \
  --docker-username=myuser \
  --docker-password=mypassword \
  --docker-email=user@example.com
```

Examine the Secret:

```bash
kubectl get secret my-registry-secret -o yaml
```

Decode the `.dockerconfigjson` data:

```bash
kubectl get secret my-registry-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode | python3 -m json.tool
```

Expected output:
```json
{
    "auths": {
        "registry.example.com": {
            "username": "myuser",
            "password": "mypassword",
            "email": "user@example.com",
            "auth": "bXl1c2VyOm15cGFzc3dvcmQ="
        }
    }
}
```

> **📝 Note:** Docker registry Secrets are used in Pod specs with the `imagePullSecrets` field. You'll see this in practice when working with private container registries.

---

## Verification

Confirm everything works correctly:

```bash
# 1. PVC is bound and PostgreSQL data persisted
kubectl get pvc postgres-pvc
# Expected: STATUS is "Bound"

POSTGRES_POD=$(kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POSTGRES_POD -- psql -U trainuser -d trainingdb -c "SELECT count(*) FROM messages;"
# Expected: count = 2

# 2. ConfigMap-based nginx is serving custom content
# Troubleshooting: if "nginx-configured" doesn't resolve, the ClusterIP Service from Module 03
# is missing — apply it first: kubectl apply -f ../module-03-orchestration/manifests/nginx-service-clusterip.yaml
NGINX_POD=$(kubectl get pod -l app=nginx-custom -o jsonpath='{.items[0].metadata.name}')
kubectl run verify-curl --image=curlimages/curl:8.19.0 --restart=Never -it --rm -- \
  curl -s http://nginx-configured/healthz
# Expected: "healthy"

# 3. Secret is mounted and readable
kubectl exec secret-reader -- cat /etc/db-credentials/username
# Expected: "trainuser"

# 4. All Pods are running
kubectl get pods -n training
# Expected: postgres, nginx-configured, and secret-reader all Running
```

---

## Cleanup

Remove all resources created during this lab:

```bash
kubectl delete -f manifests/
kubectl delete configmap greeting
kubectl delete secret my-registry-secret
```

Verify cleanup:

```bash
kubectl get all,pvc,configmap,secret -n training
```

Or reset the entire namespace:

```bash
kubectl delete namespace training
kubectl create namespace training
kubectl config set-context --current --namespace=training
```

---

## Bonus Challenge

### Challenge: Deploy a Complete Application Stack

Deploy a complete application where:
- **PostgreSQL** stores data with a PVC for persistence
- **Database credentials** are stored in a Secret
- **Application configuration** is in a ConfigMap
- A **web frontend** (nginx) displays a custom page with database connection status

<details>
<summary>💡 Hint</summary>

You need four resources:
1. A `Secret` for the database credentials (already have `db-credentials`)
2. A `PVC` for PostgreSQL data (already have `postgres-pvc`)
3. A `ConfigMap` for the frontend configuration
4. A PostgreSQL `Deployment` + a nginx `Deployment`
5. Two `Services` to connect them

Use `envFrom` to inject the ConfigMap as environment variables and `secretKeyRef` for the database password.
</details>

<details>
<summary>✅ Solution</summary>

```yaml
# bonus-app.yaml — Complete application stack
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-frontend-config
  namespace: training
data:
  DB_HOST: "postgres-svc"
  DB_PORT: "5432"
  DB_NAME: "trainingdb"
  index.html: |
    <!DOCTYPE html>
    <html>
    <body>
      <h1>Kubernetes Training App</h1>
      <p>Database: postgres-svc:5432/trainingdb</p>
      <p>Credentials: loaded from Secret</p>
      <p>Config: loaded from ConfigMap</p>
      <p>Storage: PersistentVolumeClaim</p>
    </body>
    </html>
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-svc
  namespace: training
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  namespace: training
spec:
  selector:
    app: frontend
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: training
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: nginx
        image: nginx:1.30.0
        ports:
        - containerPort: 80
        envFrom:
        - configMapRef:
            name: app-frontend-config
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
          readOnly: true
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
      volumes:
      - name: html
        configMap:
          name: app-frontend-config
          items:
          - key: index.html
            path: index.html
```

Apply and test:
```bash
kubectl apply -f bonus-app.yaml

# Test the frontend from a curl-capable image (nginx itself doesn't have curl)
kubectl run verify-curl --image=curlimages/curl:8.19.0 --restart=Never -it --rm -- \
  curl -s http://frontend-svc/
```

Cleanup:
```bash
kubectl delete -f bonus-app.yaml
```
</details>

---

> **🎉 Congratulations!** You've mastered Kubernetes storage and configuration management. You can now persist data with PVCs, externalize configuration with ConfigMaps, and securely manage credentials with Secrets. In **Module 5**, we'll explore Kubernetes networking — including Services, Ingress, DNS, and NetworkPolicies.
