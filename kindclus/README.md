# KindClus

Automated provisioner for local multi-node Kubernetes clusters using [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker). Designed for WSL2 environments, it creates a 3-node cluster with TLS, and a Calico + MetalLB + Traefik networking stack.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Kind Cluster (kind-clus)                               │
│                                                         │
│  ┌──────────────┐  ┌────────────┐  ┌────────────┐      │
│  │ control-plane│  │  worker-1  │  │  worker-2  │      │
│  │ :8880 :8443  │  │            │  │            │      │
│  │ :8000        │  │            │  │            │      │
│  └──────────────┘  └────────────┘  └────────────┘      │
│                                                         │
│  Networking:                                            │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Calico CNI                                       │  │
│  │  MetalLB L2 load balancer                         │  │
│  │  Traefik ingress controller                       │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  Common: cert-manager, CoreDNS (custom), CA certs       │
└─────────────────────────────────────────────────────────┘

Optional pull-through image caches (Docker network: kind)
  proxy-docker :5001  ─► registry-1.docker.io
  proxy-quay   :5002  ─► quay.io
  proxy-gcr    :5003  ─► gcr.io
  proxy-ghcr   :5004  ─► ghcr.io
  proxy-k8s-gcr:5005  ─► k8s.gcr.io
```

## Prerequisites

- [Docker](https://docs.docker.com/engine/install/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- Shared utility library:
  - `../commonFtns.sh` — logging, prompts, timing helpers, certificate generation, and component installers (`cert_manager_install`, `install_calico`, `install_metallb_kind`, `install_traefik`, etc.)
- Pre-generated CA and TLS certificates under `$WORK_DIR/.certDir/<domain>/`

## Files

| File | Description |
|---|---|
| `KindClus_Run.sh` | Main entrypoint. Provisions the cluster and installs all components. |
| `corefile-kind.yaml` | Custom CoreDNS ConfigMap with local domain host entries for `util.lcl` services. |
| `calico.yaml` | Calico CNI manifest. |
| `metallb-native.yaml` | MetalLB manifest. |
| `cert-manager.yaml` | cert-manager manifest. |

## Configuration

Configuration is managed via a `.env` file. Copy the template and edit:

```bash
cp .env.example .env
nano .env
```

| Variable | Default | Description |
|---|---|---|
| `PREFIX` | `kube` | Domain prefix |
| `SUFFIX` | `localdev` | Domain suffix |
| `LOCAL_TZ` | `UTC` | Timezone for log timestamps |
| `K8S_USER` | `$USER` | OS user for cert/kubeconfig paths |
| `WORK_DIR` | `~/workdir` | Root directory for project data, certs, and backups |
| `CERTDIR` | `$WORK_DIR/.certDir/<domain>/` | TLS certificate directory |
| `KIND_NODE_IMAGE` | `kindest/node:v1.33.4` | Kubernetes node image |
| `CERT_MANAGER_VERSION` | `1.19.4` | cert-manager release |
| `METALLB_VERSION` | `0.15.3` | MetalLB release |
| `TRAEFIK_VERSION` | `37.2.0` | Traefik Helm chart version |
| `ARGOCD_VERSION` | `3.3.3` | ArgoCD Helm chart version |
| `LONGHORN_VERSION` | `1.9.0` | Longhorn Helm chart version |
| `CILIUM_LB_IP_START` | `10.163.168.62` | Cilium LB pool start (if using Cilium) |
| `CILIUM_LB_IP_END` | `10.163.168.65` | Cilium LB pool end (if using Cilium) |

The cluster domain is derived as `PREFIX.SUFFIX` (e.g. `kube.localdev`).

## Usage

```bash
cp .env.example .env   # configure your environment
nano .env
chmod +x KindClus_Run.sh
./KindClus_Run.sh
```

### Step 1 — Cluster Creation

1. Generates TLS certificates for the domain via `gencert`
2. Creates a 3-node Kind cluster (1 control-plane + 2 workers) with containerd registry mirrors configured
3. Mounts CA certificates into all nodes
4. Runs `update-ca-certificates` on each node
5. Exposes host ports: `8880` (HTTP), `8443` (HTTPS), `8000` (extra)

If the cluster already exists, you are prompted to delete it or skip to component installation.

### Step 2 — Platform Components

Installs the following in order:
1. **cert-manager** with a `ClusterIssuer` backed by the local CA
2. **Calico** CNI
3. **MetalLB** in L2 mode (IP pool auto-derived from the Kind Docker subnet)
4. **Traefik** ingress controller via Helm

### Optional — Pull-through Image Caches

The `setup_image_cache` function is available but disabled by default. To enable it, uncomment the call in `main()`. It creates Docker registry proxy containers on the `kind` network for faster image pulls from docker.io, quay.io, gcr.io, ghcr.io, and k8s.gcr.io.

## Exposed Endpoints

After successful installation (assuming domain `kube.localdev`):

| Endpoint | Description |
|---|---|
| `https://dashboard.kube.localdev/dashboard/` | Traefik dashboard |
| `https://nginx.kube.localdev/` | Test nginx service |

## Cluster Management

```bash
# List clusters
kind get clusters

# Get node status
kubectl get nodes

# Delete the cluster
kind delete cluster --name kind-clus

# Remove image cache proxies (if enabled)
for reg in docker quay gcr ghcr k8s-gcr; do
  docker stop proxy-$reg && docker rm -v proxy-$reg
done
```

## Troubleshooting

**Pods stuck in pending / too many open files (WSL2)**

Increase inotify limits — the script includes an `update_inotify` function:

```bash
sudo sysctl fs.inotify.max_user_instances=2280
sudo sysctl fs.inotify.max_user_watches=1255360
```

**Certificate errors**

Ensure CA certs exist at `$WORK_DIR/.certDir/<domain>/` and that `gencert` has been run for your domain. All Kind nodes mount these certs and run `update-ca-certificates` at cluster creation.

**MetalLB IP pool issues**

The pool range is derived from the Kind Docker network subnet. Verify with:

```bash
docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' kind
```
