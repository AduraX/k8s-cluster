# k8s-cluster

Automated Kubernetes cluster provisioning toolkit with two deployment targets: **Kind** for local development on WSL2, and **RKE2** for production-grade bare-metal or VM clusters. Both share a common library of utilities, certificate management, and platform component installers.

## Deployment Options

| | Kind (local dev) | RKE2 (production) |
|---|---|---|
| **Entrypoint** | `kindclus/KindClus_Run.sh` | `rke2/rke2ClusterInstall.sh [sg\|ha]` |
| **Nodes** | 1 control-plane + 2 workers (Docker containers) | 1–3 masters + 2–5 workers (VMs / bare-metal) |
| **CNI** | Calico | Calico (SG) or Cilium (HA) |
| **Load Balancer** | MetalLB L2 | MetalLB or Cilium L2 |
| **Ingress / Gateway** | Traefik (Gateway API) | Traefik or Cilium Gateway API |
| **Storage** | — | Longhorn |
| **GitOps** | — | ArgoCD |
| **Air-gapped support** | No | Yes (Harbor registry) |
| **HA / VIP** | No | Yes (keepalived) |

## Architecture

```
k8s-cluster/
├── commonFtns.sh                  # Shared library (logging, certs, component installers)
├── custom-traefik-values.yaml     # Traefik Helm values (Gateway API mode)
├── traefik-nginx.yaml             # Test nginx deployment + HTTPRoute
├── kindclus/                      # Kind cluster provisioner
│   ├── KindClus_Run.sh            # Main entrypoint
│   ├── calico.yaml                # Calico CNI manifest
│   ├── metallb-native.yaml        # MetalLB manifest
│   ├── cert-manager.yaml          # cert-manager manifest
│   └── corefile-kind.yaml         # Custom CoreDNS ConfigMap
└── rke2/                          # RKE2 cluster provisioner
    ├── rke2ClusterInstall.sh      # Main entrypoint (accepts sg or ha)
    ├── deploy_rke2_sg.yaml        # Ansible playbook — single-group
    ├── deploy_rke2_ha.yaml        # Ansible playbook — HA
    ├── host_inventory_sg.ini      # Ansible inventory — 1 master, 2 workers
    ├── host_inventory_ha.ini      # Ansible inventory — 3 masters, 5 workers
    ├── custom_rke2.sh             # Patched RKE2 install script
    ├── corefile-rke2.yaml         # Custom CoreDNS ConfigMap
    ├── etc_resolv.conf            # Custom resolv.conf template
    ├── dataDir/                   # RKE2 binary cache (per-version)
    └── roles/lablabs.rke2/        # Community Ansible role
```

## Shared Library — `commonFtns.sh`

Both provisioners source `commonFtns.sh`, which provides:

- **Logging** — timestamped, color-coded console output with file logging
- **Interactive prompts** — `prompt_choice` for guided step-by-step installation
- **Certificate management** — `root_ca`, `gencert`, `create_tls_secret` for generating and distributing CA and wildcard TLS certificates
- **Component installers** — `cert_manager_install`, `install_calico`, `install_metallb_kind`, `install_metallb_k8s`, `install_traefik`, `cilium_gateway_install`, `longhorn_install`, `install_argocd`, `install_istio`

## Prerequisites

### Common

- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- Pre-generated TLS certificates (or let the scripts generate them)

### Kind (local dev)

- [Docker](https://docs.docker.com/engine/install/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- WSL2 recommended

### RKE2 (production)

- Launcher node running Ubuntu 24.04, Rocky Linux 9, or RHEL 8+
- Target nodes accessible via SSH
- Python 3, pip, and Ansible 2.10+
- Harbor registry at `harbor.util.lcl` (for air-gapped / mirrored modes)
- DNS resolving `*.util.lcl` and `*.<prefix>.<suffix>` to the appropriate IPs

## Configuration

Both provisioners use a `.env` file for configuration. Copy the example and edit:

```bash
cp .env.example .env
nano .env
```

Key variables shared across both:

| Variable | Default | Description |
|---|---|---|
| `PREFIX` | `kube` | Domain prefix |
| `SUFFIX` | `localdev` | Domain suffix |
| `LOCAL_TZ` | `UTC` | Timezone for log timestamps |
| `K8S_USER` | `$USER` | OS user for cert/kubeconfig paths |
| `WORK_DIR` | `~/workdir` | Root directory for certs, data, and backups |
| `CERT_MANAGER_VERSION` | `1.19.4` | cert-manager release |
| `METALLB_VERSION` | `0.15.3` | MetalLB release |
| `TRAEFIK_VERSION` | `37.2.0` | Traefik Helm chart version |
| `ARGOCD_VERSION` | `3.3.3` | ArgoCD Helm chart version |
| `LONGHORN_VERSION` | `1.9.0` | Longhorn Helm chart version |

The cluster domain is derived as `PREFIX.SUFFIX` (e.g. `kube.localdev`).

See each sub-directory's README for the full list of environment variables specific to that provisioner.

## Quick Start

### Kind — Local Development Cluster

```bash
cd kindclus
cp .env.example .env && nano .env
chmod +x KindClus_Run.sh
./KindClus_Run.sh
```

This creates a 3-node Kind cluster with Calico, MetalLB, cert-manager, and Traefik. After installation, the Traefik dashboard is available at `https://dashboard.<domain>/dashboard/`.

### RKE2 — Single-Group Cluster (1 master, 2 workers)

```bash
cd rke2
cp .env.example .env && nano .env
chmod +x rke2ClusterInstall.sh
./rke2ClusterInstall.sh sg
```

### RKE2 — HA Cluster (3 masters, 5 workers)

```bash
cd rke2
cp .env.example .env && nano .env
./rke2ClusterInstall.sh ha
```

The RKE2 installer walks through 4 interactive steps:
1. **Launcher prerequisites** — installs required packages
2. **SSH key distribution** — generates and copies keys to all nodes
3. **Cluster deployment** — distributes certs, downloads RKE2, configures Harbor (optional), runs Ansible
4. **Post-deployment components** — cert-manager, load balancer, Traefik/Cilium Gateway, Longhorn, ArgoCD

## Certificates

Both provisioners expect (or generate) certificates at:

```
$WORK_DIR/.certDir/<prefix_suffix>/
├── <prefix>-<suffix>-ca.crt        # CA certificate
├── <prefix>-<suffix>-ca.key        # CA private key
├── <prefix>-<suffix>-tls.crt       # Wildcard TLS certificate
└── <prefix>-<suffix>-tls.key       # TLS private key
```

These are used for node CA trust, Kubernetes TLS secrets, and the cert-manager CA ClusterIssuer.

## Air-Gapped and Mirrored Modes (RKE2 only)

- **Air-gapped** — images are pre-pulled, tagged, and pushed to Harbor under `airgapped-<registry>` projects
- **Mirrored** — Harbor acts as a pull-through proxy cache with `mirrored-<registry>` projects

Both modes configure containerd on each node via the Ansible role's `registries.yaml` template.

## Troubleshooting

### WSL2 — pods stuck in pending / too many open files

```bash
sudo sysctl fs.inotify.max_user_instances=2280
sudo sysctl fs.inotify.max_user_watches=1255360
```

### Certificate errors

Ensure CA certs exist at `$WORK_DIR/.certDir/<domain>/` and that `gencert` has been run for your domain.

### Kind — MetalLB IP pool issues

The pool range is auto-derived from the Kind Docker network subnet:

```bash
docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' kind
```

### RKE2 — view service logs on a node

```bash
journalctl -u rke2-server -f   # server node
journalctl -u rke2-agent -f    # agent node
```

### RKE2 — run commands across all nodes

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TMP=/tmp/ansible-remote \
ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp \
ansible all -i host_inventory_ha.ini -u vagrant \
  --private-key ~/.ssh/id_ed25519-rke2 \
  -b -m shell \
  -a 'systemctl status rke2-server --no-pager || systemctl status rke2-agent --no-pager'
```

### RKE2 — complete cluster teardown

Run the installer and choose `u` (uninstall) at Step 3, or manually:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TMP=/tmp/ansible-remote \
ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp \
ansible all -i host_inventory_ha.ini -u vagrant \
  --private-key ~/.ssh/id_ed25519-rke2 \
  -b -m shell \
  -a '/usr/local/bin/rke2-uninstall.sh || true; rm -rf /var/lib/rancher /rke2 /run/containerd /run/k3s'
```

## Further Reading

- [kindclus/README.md](kindclus/README.md) — detailed Kind provisioner documentation
- [rke2/README.md](rke2/README.md) — detailed RKE2 provisioner documentation
