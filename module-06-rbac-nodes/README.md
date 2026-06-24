# Lab 6: RBAC and Node Management — Access Control and Scheduling

> **Duration:** 30 min
> **Prerequisites:** Module 6 theory, running Kubernetes cluster (kind with 3 nodes from Lab 1)

## Objectives

1. Create ServiceAccounts and configure RBAC with Roles and RoleBindings
2. Set up ClusterRoles and ClusterRoleBindings for cluster-wide access
3. Manage node labels, taints, and tolerations
4. Practice node cordoning and draining for maintenance

> **⏱️ Time check:** Exercises 1–4 are core (~30 min). Affinity / topology spread / team-RBAC scaffolding are in Bonus Challenges — take-home material.

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

Create the namespace and set context:

```bash
kubectl create namespace training --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=training
```

---

## Exercise 1: RBAC Setup

In this exercise, you'll create a ServiceAccount, a Role with limited permissions, and a RoleBinding connecting them.

### Step 1: Create a ServiceAccount

Create a `developer` ServiceAccount that will serve as the identity for our test Pod:

```bash
kubectl apply -f manifests/serviceaccount.yaml
```

Verify the ServiceAccount was created:

```bash
kubectl get serviceaccounts -n training
```

Expected output:
```
NAME        AGE
default     Xd
developer   10s
```

> **📝 Note:** On older kubectl (≤ v1.23) you'll also see a `SECRETS` column:
> ```
> NAME        SECRETS   AGE
> default     1         Xd
> developer   0         10s
> ```
> Kubernetes stopped auto-generating a token Secret per ServiceAccount (and kubectl dropped the column) in newer releases, so the count is gone. Either output is fine — what matters is that the `developer` ServiceAccount appears.

### Step 2: Create a Read-Only Role

Create a Role that allows only read operations on Pods and Services:

```bash
kubectl apply -f manifests/role-readonly.yaml
```

Examine the Role:

```bash
kubectl describe role pod-service-reader -n training
```

Expected output:
```
Name:         pod-service-reader
Labels:       app=rbac-lab
Annotations:  <none>
PolicyRule:
  Resources  Non-Resource URLs  Resource Names  Verbs
  ---------  -----------------  --------------  -----
  pods       []                 []              [get list watch]
  services   []                 []              [get list watch]
```

### Step 3: Create a RoleBinding

Bind the `pod-service-reader` Role to the `developer` ServiceAccount:

```bash
kubectl apply -f manifests/rolebinding.yaml
```

Verify the binding:

```bash
kubectl get rolebindings -n training
```

Expected output:
```
NAME                           ROLE                      AGE
developer-pod-service-reader   Role/pod-service-reader   10s
```

### Step 4: Deploy a Pod Using the ServiceAccount

Deploy a Pod that uses the `developer` ServiceAccount:

```bash
kubectl apply -f manifests/pod-with-sa.yaml
```

Verify the Pod is running and check its ServiceAccount:

```bash
kubectl get pod dev-pod -n training -o jsonpath='{.spec.serviceAccountName}'
echo  # newline
```

Expected output:
```
developer
```

### Step 5: Test Permissions

Use `kubectl auth can-i` to verify what the `developer` ServiceAccount can and cannot do:

```bash
# Can the developer get Pods? (should be YES)
kubectl auth can-i get pods \
  --as=system:serviceaccount:training:developer -n training
```

Expected output:
```
yes
```

```bash
# Can the developer list Services? (should be YES)
kubectl auth can-i list services \
  --as=system:serviceaccount:training:developer -n training
```

Expected output:
```
yes
```

```bash
# Can the developer create Deployments? (should be NO)
kubectl auth can-i create deployments \
  --as=system:serviceaccount:training:developer -n training
```

Expected output:
```
no
```

```bash
# Can the developer delete Pods? (should be NO)
kubectl auth can-i delete pods \
  --as=system:serviceaccount:training:developer -n training
```

Expected output:
```
no
```

### Step 6: List All Permissions

View the complete permission set for the `developer` ServiceAccount:

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:training:developer -n training
```

Look for the `pods` and `services` entries with `[get list watch]` verbs.

> **🔑 Key Concept:** The `developer` ServiceAccount has read-only access to Pods and Services, but cannot create, update, or delete any resources. This is the principle of least privilege in action.

### Step 7: Clean Up the Bare Pod

`dev-pod` was created as a bare Pod (no Deployment/ReplicaSet behind it). Bare Pods block `kubectl drain` later in Exercise 4 with `cannot delete Pods that declare no controller`, so remove it before moving on:

```bash
kubectl delete pod dev-pod -n training
```

Expected output:
```
pod "dev-pod" deleted
```

The ServiceAccount, Role, and RoleBinding remain in place — Exercise 2 reuses the `developer` SA.

---

## Exercise 2: ClusterRole and Aggregation

In this exercise, you'll create a ClusterRole and ClusterRoleBinding to grant cross-namespace access.

### Step 1: Create a ClusterRole

Create a ClusterRole that allows viewing Pods in any namespace:

```bash
kubectl apply -f manifests/clusterrole-pod-viewer.yaml
```

Verify:

```bash
kubectl get clusterrole pod-viewer
```

Expected output:
```
NAME         CREATED AT
pod-viewer   2024-01-01T00:00:00Z
```

### Step 2: Create a ClusterRoleBinding

Bind the ClusterRole to the `developer` ServiceAccount:

```bash
kubectl apply -f manifests/clusterrolebinding.yaml
```

Verify:

```bash
kubectl get clusterrolebinding developer-pod-viewer
```

Expected output:
```
NAME                   ROLE                      AGE
developer-pod-viewer   ClusterRole/pod-viewer    10s
```

### Step 3: Test Cross-Namespace Access

The `developer` ServiceAccount should now be able to list Pods in any namespace:

```bash
# Can the developer list Pods in kube-system? (should be YES now)
kubectl auth can-i list pods \
  --as=system:serviceaccount:training:developer -n kube-system
```

Expected output:
```
yes
```

```bash
# Can the developer list Pods in default namespace? (should be YES)
kubectl auth can-i list pods \
  --as=system:serviceaccount:training:developer -n default
```

Expected output:
```
yes
```

```bash
# Can the developer create Pods in kube-system? (should still be NO)
kubectl auth can-i create pods \
  --as=system:serviceaccount:training:developer -n kube-system
```

Expected output:
```
no
```

### Step 4: Compare with the Built-in `view` ClusterRole

Kubernetes ships with a pre-defined `view` ClusterRole. Let's examine it:

```bash
kubectl describe clusterrole view
```

Notice the extensive list of resources — the `view` ClusterRole provides read-only access to most namespaced resources. Our custom `pod-viewer` is more restrictive, granting access only to Pods.

> **💡 Tip:** In production, consider using the built-in `view` ClusterRole for read-only dashboards and monitoring tools, instead of creating custom ClusterRoles for each resource type.

---

## Exercise 3: Node Management

In this exercise, you'll manage node labels and taints, and observe their effect on Pod scheduling.

> **📝 Note:** This exercise requires a multi-node cluster. With kind (3 nodes), you have one control-plane and two worker nodes.

### Step 1: Label a Node

Add a custom label to a worker node:

```bash
kubectl label node training-worker disktype=ssd
```

Expected output:
```
node/training-worker labeled
```

Verify the label:

```bash
kubectl get node training-worker --show-labels | grep disktype
```

You should see `disktype=ssd` in the label list.

### Step 2: Taint a Node

Add a taint to the same worker node:

```bash
kubectl taint nodes training-worker dedicated=training:NoSchedule
```

Expected output:
```
node/training-worker tainted
```

Verify the taint:

```bash
kubectl describe node training-worker | grep -A5 Taints
```

Expected output:
```
Taints:             dedicated=training:NoSchedule
```

### Step 3: Deploy a Pod Without Toleration

Create a simple Pod without a toleration to verify it doesn't schedule on the tainted node:

```bash
kubectl run no-toleration-pod --image=nginx:1.30.0 -n training
```

Wait for it to be running and check which node it's on:

```bash
kubectl get pod no-toleration-pod -n training -o wide
```

Expected output:
```
NAME                READY   STATUS    RESTARTS   AGE   IP           NODE               ...
no-toleration-pod   1/1     Running   0          10s   10.244.x.x   training-worker2   ...
```

The Pod should be scheduled on `training-worker2` (the non-tainted node), NOT on `training-worker`.

### Step 4: Deploy a Pod With Toleration

Now apply the Pod manifest that includes a toleration for the taint:

```bash
kubectl apply -f manifests/pod-with-toleration.yaml
```

Check the Pod status:

```bash
kubectl get pod toleration-pod -n training -o wide
```

Expected output:
```
NAME              READY   STATUS    RESTARTS   AGE   IP           NODE               ...
toleration-pod    1/1     Running   0          10s   10.244.x.x   training-worker    ...
```

The Pod should be scheduled on `training-worker` because:
1. It has a **toleration** matching the taint (`dedicated=training:NoSchedule`)
2. It has a **nodeSelector** for `disktype=ssd` (which we added in Step 1)

> **🔑 Key Concept:** The toleration allows the Pod to schedule on the tainted node, and the nodeSelector ensures it specifically targets the labeled node. Without the toleration, the scheduler would reject the node even though the label matches.

### Step 5: Clean Up Node Taint and Label

Remove the taint and label for subsequent exercises:

```bash
# Remove the taint
kubectl taint nodes training-worker dedicated=training:NoSchedule-

# Remove the label
kubectl label node training-worker disktype-

# Delete the test Pods
kubectl delete pod no-toleration-pod toleration-pod -n training --ignore-not-found
```

---

## Exercise 4: Node Draining

In this exercise, you'll practice the node maintenance workflow: cordon, drain, and uncordon.

### Step 1: Create a Deployment

First, create a Deployment with multiple replicas so we can observe Pod redistribution:

```bash
kubectl create deployment drain-test --image=nginx:1.30.0 --replicas=4 -n training
```

Wait for all Pods to be ready:

```bash
kubectl rollout status deployment drain-test -n training --timeout=60s
```

Check Pod distribution across nodes:

```bash
kubectl get pods -n training -l app=drain-test -o wide
```

Expected output (Pods spread across both worker nodes):
```
NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE               ...
drain-test-xxxxx-aaaaa        1/1     Running   0          30s   10.244.x.x   training-worker    ...
drain-test-xxxxx-bbbbb        1/1     Running   0          30s   10.244.x.x   training-worker2   ...
drain-test-xxxxx-ccccc        1/1     Running   0          30s   10.244.x.x   training-worker    ...
drain-test-xxxxx-ddddd        1/1     Running   0          30s   10.244.x.x   training-worker2   ...
```

### Step 2: Cordon a Node

Mark `training-worker` as unschedulable:

```bash
kubectl cordon training-worker
```

Verify the status:

```bash
kubectl get nodes
```

Expected output:
```
NAME                     STATUS                     ROLES           AGE   VERSION
training-control-plane   Ready                      control-plane   Xd    v1.35.1
training-worker          Ready,SchedulingDisabled   <none>          Xd    v1.35.1
training-worker2         Ready                      <none>          Xd    v1.35.1
```

### Step 3: Verify New Pods Don't Schedule on Cordoned Node

Scale up the Deployment to see where new Pods are placed:

```bash
kubectl scale deployment drain-test --replicas=6 -n training
```

Check Pod placement:

```bash
kubectl get pods -n training -l app=drain-test -o wide
```

Notice: all **new** Pods are placed on `training-worker2`. Existing Pods on `training-worker` continue running.

### Step 4: Drain the Node

Drain all workload Pods from the cordoned node:

```bash
kubectl drain training-worker \
  --ignore-daemonsets \
  --delete-emptydir-data
```

Expected output:
```
node/training-worker already cordoned
WARNING: ignoring DaemonSet-managed Pods: ...
evicting pod training/drain-test-xxxxx-aaaaa
evicting pod training/drain-test-xxxxx-ccccc
pod/drain-test-xxxxx-aaaaa evicted
pod/drain-test-xxxxx-ccccc evicted
node/training-worker drained
```

### Step 5: Observe Pod Rescheduling

Check that all Pods have been rescheduled to `training-worker2`:

```bash
kubectl get pods -n training -l app=drain-test -o wide
```

All Pods should now be running on `training-worker2`:
```
NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE               ...
drain-test-xxxxx-bbbbb        1/1     Running   0          2m    10.244.x.x   training-worker2   ...
drain-test-xxxxx-ddddd        1/1     Running   0          2m    10.244.x.x   training-worker2   ...
drain-test-xxxxx-eeeee        1/1     Running   0          1m    10.244.x.x   training-worker2   ...
drain-test-xxxxx-fffff        1/1     Running   0          1m    10.244.x.x   training-worker2   ...
drain-test-xxxxx-ggggg        1/1     Running   0          30s   10.244.x.x   training-worker2   ...
drain-test-xxxxx-hhhhh        1/1     Running   0          30s   10.244.x.x   training-worker2   ...
```

### Step 6: Uncordon the Node

Re-enable scheduling on the node:

```bash
kubectl uncordon training-worker
```

Verify:

```bash
kubectl get nodes
```

Expected output:
```
NAME                     STATUS   ROLES           AGE   VERSION
training-control-plane   Ready    control-plane   Xd    v1.35.1
training-worker          Ready    <none>          Xd    v1.35.1
training-worker2         Ready    <none>          Xd    v1.35.1
```

> **📝 Note:** Uncordoning a node doesn't automatically move Pods back. Existing Pods stay where they are. New Pods (from scaling or rescheduling) may be placed on the uncordoned node based on scheduler decisions.

### Step 7: Clean Up

```bash
kubectl delete deployment drain-test -n training
```

---

## Verification

Confirm all lab exercises completed successfully:

```bash
# 1. ServiceAccount exists
kubectl get serviceaccount developer -n training

# 2. Role and RoleBinding exist
kubectl get role pod-service-reader -n training
kubectl get rolebinding developer-pod-service-reader -n training

# 3. ClusterRole and ClusterRoleBinding exist
kubectl get clusterrole pod-viewer
kubectl get clusterrolebinding developer-pod-viewer

# 4. RBAC permissions are correct
kubectl auth can-i get pods \
  --as=system:serviceaccount:training:developer -n training
# Expected: yes

kubectl auth can-i create deployments \
  --as=system:serviceaccount:training:developer -n training
# Expected: no

# 5. Cross-namespace access works
kubectl auth can-i list pods \
  --as=system:serviceaccount:training:developer -n kube-system
# Expected: yes

# 6. All exercise deployments are healthy (drain-test was deleted earlier)
kubectl get deployments -n training
```

---

## Cleanup

Remove all resources created during this lab:

```bash
# Delete namespaced resources
kubectl delete -f manifests/ -n training --ignore-not-found
kubectl delete deployment affinity-demo spread-app -n training --ignore-not-found

# Delete cluster-wide resources
kubectl delete clusterrole pod-viewer --ignore-not-found
kubectl delete clusterrolebinding developer-pod-viewer --ignore-not-found

# Ensure node is clean
kubectl uncordon training-worker 2>/dev/null || true
kubectl label node training-worker disktype- 2>/dev/null || true
kubectl taint nodes training-worker dedicated=training:NoSchedule- 2>/dev/null || true
```

Or delete and recreate the namespace:

```bash
kubectl delete namespace training
kubectl create namespace training

# Still need to clean cluster-wide resources
kubectl delete clusterrole pod-viewer --ignore-not-found
kubectl delete clusterrolebinding developer-pod-viewer --ignore-not-found
```

---

## Bonus Challenges

### Challenge 1: Scheduling with Affinity (take-home)

Use nodeSelector, node affinity, and pod anti-affinity to control Pod placement on the existing cluster. The `manifests/` directory of this module already contains `deployment-node-affinity.yaml` and `deployment-pod-antiaffinity.yaml` for you to study and apply.

1. Label `training-worker` with `disktype=ssd`.
2. Apply `manifests/deployment-node-affinity.yaml` and observe how *most* (but not necessarily all) replicas land on the labeled node — `preferredDuringSchedulingIgnoredDuringExecution` is a soft preference.
3. Apply `manifests/deployment-pod-antiaffinity.yaml` and verify that replicas spread across both workers.
4. Inspect the scheduling events: `kubectl events -n training --for pod/<pod-name>` (replace `<pod-name>` with one of the `spread-app` Pods from `kubectl get pods -l app=spread-app -n training`).

   > **📝 Note:** Avoid `kubectl describe pod -l app=spread-app | grep "Events:"` here. As of kubectl v1.34+, `describe` with a **label selector** that matches multiple Pods no longer renders a per-Pod `Events:` section, so the `grep` returns nothing. `kubectl events` (or describing a single Pod by name) shows the scheduling events reliably.
5. Clean up: `kubectl label node training-worker disktype-` and delete both Deployments.

<details>
<summary>💡 Hint</summary>

The affinity manifests are already in `manifests/`. Compare the two Deployments side by side — the only structural difference is `nodeAffinity` vs `podAntiAffinity` under `spec.template.spec.affinity`. The `topologyKey: kubernetes.io/hostname` is what makes anti-affinity spread Pods across nodes.
</details>

### Challenge 2: Complete Team RBAC Setup

Create a complete RBAC setup for a development team:

1. **`dev` ServiceAccount:** can manage (create, update, delete) Pods, Services, and Deployments in the `training` namespace
2. **`viewer` ServiceAccount:** read-only access to everything in the `training` namespace
3. Test both with `kubectl auth can-i`

<details>
<summary>💡 Hint</summary>

For the `dev` ServiceAccount, create a Role with verbs `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` on `pods`, `services`, and `deployments`.

For the `viewer` ServiceAccount, you can use a RoleBinding that references the built-in `view` ClusterRole — this grants read-only access to most namespaced resources without needing a custom Role.
</details>

<details>
<summary>✅ Solution</summary>

```yaml
# dev-sa.yaml — Dev ServiceAccount + Role + RoleBinding
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dev
  namespace: training
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-role
  namespace: training
rules:
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-binding
  namespace: training
subjects:
- kind: ServiceAccount
  name: dev
  namespace: training
roleRef:
  kind: Role
  name: dev-role
  apiGroup: rbac.authorization.k8s.io
---
# viewer-sa.yaml — Viewer ServiceAccount + RoleBinding using built-in view ClusterRole
apiVersion: v1
kind: ServiceAccount
metadata:
  name: viewer
  namespace: training
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: viewer-binding
  namespace: training
subjects:
- kind: ServiceAccount
  name: viewer
  namespace: training
roleRef:
  kind: ClusterRole
  name: view                         # Built-in read-only ClusterRole
  apiGroup: rbac.authorization.k8s.io
```

Apply and test:
```bash
kubectl apply -f bonus-rbac.yaml

# Dev can create Deployments
kubectl auth can-i create deployments \
  --as=system:serviceaccount:training:dev -n training
# Expected: yes

# Dev can delete Pods
kubectl auth can-i delete pods \
  --as=system:serviceaccount:training:dev -n training
# Expected: yes

# Viewer can list Pods
kubectl auth can-i list pods \
  --as=system:serviceaccount:training:viewer -n training
# Expected: yes

# Viewer cannot create Deployments
kubectl auth can-i create deployments \
  --as=system:serviceaccount:training:viewer -n training
# Expected: no
```
</details>

### Challenge 3: Topology Spread Constraints

Create a Deployment with **topology spread constraints** that evenly distributes 4 replicas across your worker nodes, using `maxSkew: 1`.

**What this challenge is about.** `topologySpreadConstraints` tell the scheduler to keep Pods *balanced* across a set of failure domains (here, individual nodes). The pieces:

- **`topologyKey: kubernetes.io/hostname`** — the label whose distinct values define the domains. Every node carries a unique `kubernetes.io/hostname`, so each node is its own domain. Our cluster has three: `training-control-plane`, `training-worker`, and `training-worker2`.
- **`maxSkew: 1`** — the maximum allowed difference between the most-populated and least-populated domain. With `maxSkew: 1`, no node may hold more than one Pod above the emptiest node.
- **`whenUnsatisfiable: DoNotSchedule`** — a *hard* rule. If placing a Pod would break `maxSkew`, the Pod stays `Pending` rather than being placed anyway. (The softer alternative is `ScheduleAnyway`.)
- **`labelSelector`** — which Pods are counted when measuring the spread. It must match this Deployment's own Pods so they are balanced against each other.

> **⚠️ Gotcha — the control-plane counts too.** By default a constraint measures skew across **all** nodes matching the `topologyKey`, including the tainted `training-control-plane`, which can never run these Pods. That node sits permanently at 0 Pods, so with `maxSkew: 1` each worker is capped at 1 Pod — only 2 of the 4 replicas schedule and the other two hang in `Pending` with `didn't match pod topology spread constraints`. The solution below adds **`nodeTaintsPolicy: Honor`** to exclude nodes whose taints the Pod can't tolerate, so only the two schedulable workers are counted. See the explanation after the solution.

<details>
<summary>💡 Hint</summary>

Use `topologySpreadConstraints` in the Pod spec. On a kind cluster you also need `nodeTaintsPolicy: Honor` so the tainted control-plane node is not counted as an empty domain:
```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    nodeTaintsPolicy: Honor
    labelSelector:
      matchLabels:
        app: your-app-name
```
</details>

<details>
<summary>✅ Solution</summary>

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-even
  namespace: training
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-even
  template:
    metadata:
      labels:
        app: spread-even
    spec:
      containers:
      - name: nginx
        image: nginx:1.30.0
        resources:
          requests:
            memory: "32Mi"
            cpu: "25m"
          limits:
            memory: "64Mi"
            cpu: "50m"
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        nodeTaintsPolicy: Honor          # Ignore nodes whose taints we can't tolerate (the control-plane)
        labelSelector:
          matchLabels:
            app: spread-even
```

Apply and verify:
```bash
kubectl apply -f bonus-spread.yaml
kubectl rollout status deployment spread-even -n training --timeout=60s
kubectl get pods -l app=spread-even -o wide -n training
```

You should see 2 Pods on each worker node (even distribution with `maxSkew: 1`).

**What `nodeTaintsPolicy: Honor` does.** This field controls whether tainted nodes are included when the scheduler measures skew:

- **`Ignore` (the default):** node taints are *ignored* for the skew calculation — every node matching the `topologyKey` is counted, even ones the Pod can't actually run on. On kind, `training-control-plane` carries a `NoSchedule` taint and our Pods have no matching toleration, yet under `Ignore` it still counts as a domain holding 0 Pods. That phantom empty domain caps each worker at one Pod and leaves 2 replicas `Pending`.
- **`Honor`:** the scheduler *honors* taints and **excludes** any node whose `NoSchedule`/`NoExecute` taints the Pod doesn't tolerate. The control-plane drops out of the calculation, leaving just the two workers as domains. Four replicas across two domains with `maxSkew: 1` is then satisfiable as a clean 2 + 2.

> **🔑 Key Concept:** `nodeTaintsPolicy` (and its sibling `nodeAffinityPolicy`) decide *which nodes form the denominator* of the spread. When a hard `DoNotSchedule` constraint leaves Pods unexpectedly `Pending`, an unschedulable node silently counted as an empty domain is a common cause — `nodeTaintsPolicy: Honor` is the usual fix.

> **📝 Note:** `nodeTaintsPolicy` requires Kubernetes v1.26+ (it reached stable/GA in v1.27). On older clusters, restrict the Pods to workers another way — e.g. a `nodeAffinity` rule or `nodeSelector` that only matches worker nodes — so the control-plane isn't part of the spread.
</details>

---

> **🎉 Congratulations!** You've implemented RBAC for access control, managed node taints and tolerations, practiced node maintenance with cordon/drain, and used affinity rules for advanced scheduling. In **Module 7**, we'll explore advanced abstractions (StatefulSets, DaemonSets, Jobs) and CI/CD with Helm and ArgoCD.
