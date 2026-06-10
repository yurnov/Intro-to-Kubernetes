# Introduction to Kubernetes — Training Course (lab materials)

## 📋 Course Overview

A hands-on training course designed to take participants from container basics through advanced Kubernetes operations, CI/CD, and troubleshooting.

**Duration:** ~12 hours (8 modules × 90 min blocks)
**Target Audience:** New and existing users of container orchestration technologies
**Prerequisites:** Understanding of Linux, container technologies, and public cloud concepts

## 🗂️ Modules

| # | Module | Duration | Key Topics |
|---|--------|----------|------------|
| 1 | [Introduction](module-01-introduction/README.md) | 90 min | Containers, K8s overview, managed services, installation |
| 2 | [Architecture and Tools](module-02-architecture/README.md) | 90 min | Components, namespaces, kubectl, operators |
| 3 | Orchestration | 90 min | Pods, deployments, services, probes, limits |
| 4 | Storage and Secrets | 90 min | PV/PVC, StorageClass, ConfigMaps, Secrets |
| 5 | Networking | 90 min | CNI, DNS, Gateway API, NetworkPolicies |
| 6 | RBAC and Node Management | 90 min | ServiceAccounts, Roles, node draining, affinity |
| 7 | Advanced Abstractions & CI/CD | 90 min | StatefulSet, DaemonSet, CronJob, Helm, ArgoCD |
| 8 | Logging, Monitoring & Troubleshooting | 90 min | Prometheus, Grafana, EFK, debugging |
<!--| 3 | [Orchestration](module-03-orchestration/) | 90 min | Pods, deployments, services, probes, limits |
| 4 | [Storage and Secrets](module-04-storage-secrets/) | 90 min | PV/PVC, StorageClass, ConfigMaps, Secrets |
| 5 | [Networking](module-05-networking/) | 90 min | CNI, DNS, Gateway API, NetworkPolicies |
| 6 | [RBAC and Node Management](module-06-rbac-nodes/) | 90 min | ServiceAccounts, Roles, node draining, affinity |
| 7 | [Advanced Abstractions & CI/CD](module-07-advanced-cicd/) | 90 min | StatefulSet, DaemonSet, CronJob, Helm, ArgoCD |
| 8 | [Logging, Monitoring & Troubleshooting](module-08-logging-troubleshooting/) | 90 min | Prometheus, Grafana, EFK, debugging | -->

## 🛠️ Lab Environment Setup

### Primary Option: Local (kind)
```bash
# Install kind v0.32.0
go install sigs.k8s.io/kind@v0.32.0
# or
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# Create the canonical 3-node course cluster from the repository root
kind create cluster --name training --config kind-config.yaml

# Verify
kubectl get nodes
```

This course standardizes on the repository's `kind-config.yaml`, which pins:
- `kind` `v0.32.0`
- `kindest/node` `v1.36.1` (tag-only; production setups should pin by sha256 digest)
- host port mappings for `80/443`
- the `ingress-ready=true` label on the control-plane node

### Optional Alternatives

#### Local (minikube)
```bash
# Install minikube from the official release page, then start a multi-node cluster
minikube start --nodes=3 --driver=docker --memory=4096 --cpus=2
```

#### Cloud-based
Use a managed Kubernetes service:
- **Google GKE:** `gcloud container clusters create training --num-nodes=3`
- **AWS EKS:** `eksctl create cluster --name training --nodes=3`
- **Azure AKS:** `az aks create -g rg-training -n training --node-count=3`

### Required Tools
```bash
# kubectl 1.36.1 (matches the cluster's kindest/node v1.36.1)
curl -LO "https://dl.k8s.io/release/v1.36.1/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/kubectl

# Helm 4 (for Modules 5, 7, 8)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash

# k9s (optional, recommended)
# https://github.com/derailed/k9s/releases/tag/v0.50.18
```

> **📝 Version compatibility:** The course pins `kubectl v1.36.1` against `kindest/node v1.36.1` (shipped with `kind v0.32.0`), so client and server are on the same minor — no version-skew warning. If you bump one, bump `kind-config.yaml` and the install commands above in lockstep, keeping client/server within the [supported skew](https://kubernetes.io/releases/version-skew-policy/).

### Install the Tooling
Run the bundled installer to grab `kubectl`, `kind`, and `helm` at the course-pinned versions:

```bash
./scripts/install-tools.sh
```

The script is idempotent — re-running it skips tools that are already at the right version. It supports Linux and macOS (amd64 / arm64).

### Verify Your Setup
Run the preflight script before each module:
```bash
./scripts/preflight.sh                # generic
./scripts/preflight.sh module-5       # module-specific extras (Cilium, etc.)
```

If you hit issues during a lab, see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## 📁 Repository Structure

```
├── README.md                    # This file
├── kind-config.yaml             # Canonical lab cluster profile for this course
├── scripts/
│   ├── install-tools.sh         # Install kubectl/kind/helm at the course-pinned versions
│   ├── preflight.sh             # Verify tooling and cluster before each module
└── module-XX-*/                 # Module directories with labs, and manifests
    ├── lab.md                   # Hands-on lab exercises
    └── manifests/               # Kubernetes YAML files for labs
```
