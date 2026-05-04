# RKE2 Kubernetes Cluster Deployment

Automated deployment of [RKE2](https://docs.rke2.io/) (Rancher Kubernetes Engine 2) clusters using Ansible and shell scripting. Supports single-node and high-availability configurations with air-gapped and mirrored registry modes.

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Single-Master Cluster](#single-master-cluster-1-master-2-workers)
  - [HA Cluster](#ha-cluster-3-masters-5-workers)
  - [Uninstalling](#uninstalling)
- [Installation Steps](#installation-steps)
- [Post-Deployment Components](#post-deployment-components)
- [Environment Variables](#environment-variables)
- [Inventory Configuration](#inventory-configuration)
- [Air-Gapped and Mirrored Modes](#air-gapped-and-mirrored-modes)
- [Certificates](#certificates)
- [Troubleshooting](#troubleshooting)

## Features

- **Single-master** deployment: 1 master + N workers with Calico CNI
- **High-availability (HA)** deployment: 3 masters + N workers with Cilium CNI and keepalived VIP
- **Air-gapped** installation using pre-downloaded artifacts and a local Harbor registry
- **Mirrored** installation using Harbor as a pull-through proxy cache
- **Interactive prompts** at each step allowing you to skip, install, or uninstall
- **Post-deployment components**: cert-manager, MetalLB or Cilium L2, Traefik or Cilium Gateway API, Longhorn, ArgoCD

## Architecture

```
                 +-----------+
                 | Launcher  |  <-- runs rke2ClusterInstall.sh
                 |   Node    |
                 +-----+-----+
                       |
          +------------+------------+
          |            |            |
    +-----+-----+ +---+---+ +-----+-----+
    | master-01  | |  ...  | | master-03 |   (HA: 3 masters with keepalived VIP)
    |  (server)  | |       | |  (server) |   (single-master: 1 master)
    +-----+------+ +---+---+ +-----+-----+
          |            |            |
    +-----+-----+ +---+---+ +-----+-----+
    | worker-01  | |  ...  | | worker-05 |   (HA: up to 5 workers)
    |  (agent)   | |       | |  (agent)  |   (single-master: 2 workers)
    +------------+ +-------+ +-----------+
```

## Prerequisites

- **Launcher node** running Ubuntu 24.04, Rocky Linux 9, or RHEL 8+
- **Target nodes** accessible via SSH (Ubuntu or Rocky Linux)
- **Python 3** and **pip** installed on the launcher node
- **Ansible 2.10+** installed on the launcher node
- **Harbor** registry deployed and accessible at `harbor.util.lcl` (for air-gapped/mirrored modes)
- **TLS certificates** generated for `k8s.lcl` domain (CA cert, TLS cert, and key)
- **DNS** resolving `*.util.lcl` and `*.k8s.lcl` to the appropriate IPs

### Install Ansible

```bash
sudo apt install ansible -y          # Ubuntu
# or
sudo dnf install ansible -y          # Rocky/RHEL
```

## Project Structure

```
rke2/
├── rke2ClusterInstall.sh          # Main orchestration script (entry point)
├── ../commonFtns.sh               # Shared utility functions and component installers
├── .env.example                   # Example environment variables (copy to .env)
├── .env                           # Local environment overrides (not committed)
├── install_ssh_keys.yaml          # Ansible playbook for initial SSH key installation
├── deploy_rke2_ha.yaml            # Ansible playbook for HA cluster
├── deploy_rke2_sm.yaml            # Ansible playbook for single-master cluster
├── host_inventory_ha.ini          # Ansible inventory - HA (3 masters, 5 workers)
├── host_inventory_sm.ini          # Ansible inventory - single-master (1 master, 2 workers)
├── custom_rke2.sh                 # Custom RKE2 install script (patched from upstream)
├── corefile-rke2.yaml             # CoreDNS ConfigMap with local domain entries
├── etc_resolv.conf                # Custom resolv.conf for DNS resolution
├── dataDir/
│   ├── artifact/                  # Active RKE2 binaries (copied per run)
│   └── artifact_<version>/        # Versioned RKE2 binary cache (e.g. artifact_1-35-3)
└── roles/
    ├── rke2_artifact_prepare/     # Local RKE2 artifact preparation role
    ├── rke2_cluster/              # Local RKE2 install/bootstrap role
    ├── rke2_harbor_setup/         # Local Harbor project/proxy setup role
    ├── rke2_node_prepare/         # Optional base Kubernetes node prerequisite role
    └── rke2_storage_prepare/      # Optional Longhorn/NFS dependency role
```

## Configuration

All configuration is set via environment variables or by editing values at the top of `rke2ClusterInstall.sh`. Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `RKE2_VERSION` | `1.35.3` | RKE2 Kubernetes version |
| `RKE2_REL` | `rke2r3` | RKE2 release suffix |
| `RKE2_ARCH` | `amd64` | Target architecture |
| `rke2_artifact_source` | `copy` | RKE2 installer artifact source: `upstream`, `copy`, `download`, or `exists` |
| `PREFIX` | `kube` | Domain prefix (forms `<prefix>.<suffix>`) |
| `SUFFIX` | `localdev` | Domain suffix |
| `REG_HOST` | `harbor.util.lcl` | Harbor registry hostname used for mirrored and airgap modes |

See [Environment Variables](#environment-variables) for the full list of overridable values.

## Usage

### Single-Master Cluster (1 master, 2 workers)

```bash
chmod +x rke2ClusterInstall.sh
./rke2ClusterInstall.sh sm
```

This uses:
- Inventory: `host_inventory_sm.ini`
- Playbook: `deploy_rke2_sm.yaml`
- CNI: Calico
- No HA / no keepalived

### HA Cluster (3 masters, 5 workers)

```bash
./rke2ClusterInstall.sh ha
```

This uses:
- Inventory: `host_inventory_ha.ini`
- Playbook: `deploy_rke2_ha.yaml`
- CNI: Calico (configurable via playbook)
- Keepalived VIP (configurable in `deploy_rke2_ha.yaml`)

### Uninstalling

When prompted at Step 3, type `u` to uninstall. This will:
- Run `rke2-uninstall.sh` on all nodes
- Remove systemd services, rancher data, and runtime directories
- Run `tofu destroy` for any Terraform/OpenTofu state

## Installation Steps

The script runs interactively through 4 steps. Each step prompts you to proceed or skip.

### Step 1: Launcher Node Prerequisites

Installs required packages on the machine running the script:
- `ansible` for node orchestration
- `sshpass` for the initial password-based SSH key bootstrap
- `curl`, `openssl`, `ldap-utils` / `openldap-clients`

Automatically detects Ubuntu, Rocky Linux, or RHEL and uses the appropriate package manager.

### Step 2: SSH Key Distribution

- Generates an Ed25519 SSH key pair (`~/.ssh/id_ed25519-rke2`) if one doesn't exist
- Checks password-based SSH reachability with Ansible
- Runs `install_ssh_keys.yaml` to install the public key on all master and worker nodes
- Verifies fresh key-only SSH authentication before deployment continues
- Starts `ssh-agent` and loads the key

### Step 3: Cluster Deployment

1. **Copies RKE2 artifacts** from `dataDir/artifact` by default
2. **Configures Harbor registry** when requested
3. **Deploys RKE2** using `mirrored`, `airgap`, or `upstream` image mode
4. **Sets up kubeconfig** at `~/.kube/config` (merged with any existing config)
5. **Distributes TLS certificates** to worker nodes at `/etc/rancher/cert/` with Ansible

Target nodes are expected to already satisfy RKE2 prerequisites by default. To let the playbook handle basic Kubernetes node preparation, set `rke2_node_prepare_enabled: true`. To install Longhorn/NFS dependencies, set `rke2_storage_prepare_enabled: true`.

### Step 4: Post-Deployment Components

Installs Kubernetes add-ons on top of the running cluster:

1. **cert-manager** (v1.19.4) — with CA secret and ClusterIssuer
2. **Load balancer** — choose one:
   - **MetalLB** (v0.15.3) + **Traefik** ingress controller (Gateway API mode)
   - **Cilium HostNetwork** with L2 announcements + Cilium Gateway API
3. **Longhorn** (v1.9.0) — distributed storage
4. **ArgoCD** (v3.3.3) — GitOps continuous delivery

## Environment Variables

Copy `.env.example` to `.env`, update the values for your environment, then source it before running:

```bash
cp .env.example .env
# Edit .env with your values
source .env && ./rke2ClusterInstall.sh ha
```

See [`.env.example`](.env.example) for all available variables and their defaults.

## Inventory Configuration

### HA Inventory (`host_inventory_ha.ini`)

```ini
[masters]
master-01 ansible_host=192.168.58.101 rke2_type=server
master-02 ansible_host=192.168.58.102 rke2_type=server
master-03 ansible_host=192.168.58.103 rke2_type=server

[workers]
worker-04 ansible_host=192.168.58.111 rke2_type=agent
worker-05 ansible_host=192.168.58.112 rke2_type=agent
worker-06 ansible_host=192.168.58.113 rke2_type=agent
worker-06 ansible_host=192.168.58.114 rke2_type=agent
worker-06 ansible_host=192.168.58.115 rke2_type=agent

[k8s_cluster:children]
masters
workers

[all:vars]
ansible_user=vagrant
ansible_python_interpreter=/usr/bin/python3.12
```

### Single-Master Inventory (`host_inventory_sm.ini`)

```ini
[masters]
master-01 ansible_host=192.168.58.101 rke2_type=server

[workers]
worker-02 ansible_host=192.168.58.111 rke2_type=agent
worker-03 ansible_host=192.168.58.112 rke2_type=agent

[k8s_cluster:children]
masters
workers

[all:vars]
ansible_user=root
ansible_python_interpreter=/usr/bin/python3.12
```

Edit the `ansible_host` IPs to match your environment.

## Air-Gapped and Mirrored Modes

Image source mode and RKE2 artifact source are separate settings. The default playbooks use Harbor mirrored image pulls while copying RKE2 installer artifacts from `dataDir/artifact`:

```yaml
rke2_image_mode: mirrored
rke2_artifact_source: copy
rke2_airgap_copy_sourcepath: dataDir/artifact
```

When `rke2_artifact_source: copy`, the `rke2_artifact_prepare` role checks `dataDir/artifact` first. If `rke2.sh`, the RKE2 tarball, or the checksum file is missing, it downloads/prepares them on the launcher before copying them to the nodes. In production airgapped environments, pre-stage these files so no download is required.

### Air-Gapped

Images are pre-pulled to the launcher node, tagged, and pushed to Harbor under `airgapped-<registry-name>` projects (e.g., `airgapped-docker.io`, `airgapped-quay.io`, `airgapped-ghcr.io`). Requires a file `rke2_imagelist.txt` containing the full image references.

### Mirrored

Harbor acts as a pull-through proxy cache. The script creates remote registries in Harbor (Docker Hub, Quay, registry.k8s.io, GCR, GHCR) and corresponding `mirrored-<registry-name>` projects such as `mirrored-ghcr.io`. Nodes pull images through Harbor transparently. RKE2 installer artifacts can still be copied from `dataDir/artifact`.

Both modes configure containerd on each node via the Ansible role's `registries.yaml` template.

## Certificates

The script expects pre-generated certificates at `$WORK_DIR/.certDir/<domain>/` (e.g. `~/workdir/.certDir/kube_localdev/`):

```
$WORK_DIR/.certDir/<prefix_suffix>/
├── <prefix>-<suffix>-ca.crt        # CA certificate
├── <prefix>-<suffix>-ca.key        # CA private key
├── <prefix>-<suffix>-tls.crt       # TLS certificate
└── <prefix>-<suffix>-tls.key       # TLS private key
```

These are used for:
- Kubernetes TLS secrets (Traefik, Cilium, ArgoCD, nginx)
- cert-manager CA ClusterIssuer

## Troubleshooting

### Check node status
```bash
kubectl get nodes -o wide
kubectl get pods -A
```

### View RKE2 service logs on a node
```bash
# On a server node:
journalctl -u rke2-server -f
# On an agent node:
journalctl -u rke2-agent -f
```

### Certificate rotation
```bash
# On each node:
systemctl stop rke2-server
rke2 certificate rotate
systemctl start rke2-server
```

### Complete cluster teardown
Run the script and choose `u` (uninstall) at Step 3, or manually:
```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TMP=/tmp/ansible-remote \
ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp \
ansible all -i host_inventory_sm.ini -u root \
  --private-key ~/.ssh/id_ed25519-rke2 \
  -b -m shell \
  -a '/usr/local/bin/rke2-uninstall.sh || true; rm -rf /var/lib/rancher /rke2 /run/containerd /run/k3s'
```

### Run commands across all nodes
```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TMP=/tmp/ansible-remote \
ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp \
ansible all -i host_inventory_sm.ini -u root \
  --private-key ~/.ssh/id_ed25519-rke2 \
  -b -m shell \
  -a 'systemctl status rke2-server --no-pager || systemctl status rke2-agent --no-pager'
```
