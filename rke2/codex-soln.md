# RKE2 Mirrored-Mode Installation Diagnosis and Remediation

## Context

The RKE2 installation failed while starting the first server:

```text
TASK [lablabs.rke2 : Start RKE2 service on the first server]
Unable to start service rke2-server.service
```

The intended deployment mode is mirrored image pulls through Harbor. Airgap installation behavior should not interfere with this mode.

## Summary of Issues and Solutions

### 1. Airgap Mode Interfered With Mirrored-Mode Diagnosis

Both deployment playbooks had airgap mode enabled:

```yaml
rke2_airgap_mode: true
```

That makes the role install RKE2 from local artifacts and can mask whether images are being pulled through Harbor.

**Solution**

Use normal RKE2 installation while keeping Harbor mirror configuration enabled:

```yaml
rke2_airgap_mode: false
```

Updated files:

- `deploy_rke2_sm.yaml`
- `deploy_rke2_ha.yaml`

### 2. Harbor Mirroring Needs Valid Registry Authentication

RKE2 is consuming:

```text
/etc/rancher/rke2/registries.yaml
```

Containerd generated mirror host configs under:

```text
/var/lib/rancher/rke2/agent/etc/containerd/certs.d/
```

The generated mirror rewrites are:

```text
docker.io        -> https://harbor.util.lcl/v2/mirrored-docker.io/...
quay.io          -> https://harbor.util.lcl/v2/mirrored-quay.io/...
registry.k8s.io  -> https://harbor.util.lcl/v2/mirrored-k8s.io/...
gcr.io           -> https://harbor.util.lcl/v2/mirrored-gcr.io/...
ghcr.io          -> https://harbor.util.lcl/v2/mirrored-ghcr.io/...
```

Harbor returned HTTP `401` during containerd pulls and RKE2 then fell back to the upstream registry. The network path to Harbor is working, but the rendered registry credentials are not sufficient for mirrored pulls.

**Solution**

Keep the existing mirror settings:

```yaml
rke2_custom_registry_url: harbor.util.lcl
rke2_custom_registry_prefix: mirrored
```

Provide valid Harbor credentials through Ansible variables rendered into `/etc/rancher/rke2/registries.yaml`:

```yaml
rke2_custom_registry_username: <harbor-user-or-robot-account>
rke2_custom_registry_password: <harbor-password-or-robot-token>
rke2_custom_registry_insecure_skip_verify: true
```

The credentials should belong to an account with pull access to the proxy-cache projects:

```text
mirrored-docker.io
mirrored-quay.io
mirrored-k8s.io
mirrored-gcr.io
mirrored-ghcr.io
```

Prefer a Harbor robot account with read-only/pull permissions. Store the password/token in Ansible Vault, inventory secret vars, or pass it with `--extra-vars`; do not hardcode the real credential in the role template.

Updated files:

- `deploy_rke2_sm.yaml`
- `deploy_rke2_ha.yaml`
- `roles/rke2_cluster/templates/registries.yaml.j2`
- `roles/rke2_cluster/defaults/main.yml`

### 3. Image Source Mode Needed To Be Tunable

The deployment needs to support three image source behaviors:

- `mirrored`: pull images through Harbor proxy-cache projects and fail if Harbor cannot serve the image.
- `airgap`: use Harbor `airgapped-*` projects for registry resolution.
- `upstream`: install normally and pull directly from upstream public registries without Harbor registry configuration.

**Solution**

Add a single playbook variable for image behavior:

```yaml
rke2_image_mode: mirrored # mirrored, airgap, upstream
```

Artifact delivery is controlled separately:

```yaml
rke2_artifact_source: copy # upstream, copy, download, exists
rke2_airgap_copy_sourcepath: dataDir/artifact
```

Derived variables now control the related RKE2 behavior:

```yaml
rke2_harbor_registry_url: harbor.util.lcl
rke2_use_custom_registry: "{{ rke2_image_mode in ['mirrored', 'airgap'] }}"
rke2_disable_default_registry_endpoint: "{{ rke2_image_mode in ['mirrored', 'airgap'] }}"
rke2_airgap_mode: "{{ rke2_image_mode == 'airgap' }}"
rke2_custom_registry_url: "{{ rke2_harbor_registry_url }}"
rke2_custom_registry_prefix: "{{ 'airgapped' if rke2_image_mode == 'airgap' else 'mirrored' }}"
```

The playbooks validate the mode before running the role:

```yaml
pre_tasks:
  - name: Validate RKE2 image mode
    ansible.builtin.assert:
      that:
        - rke2_image_mode in ['mirrored', 'airgap', 'upstream']
      fail_msg: "rke2_image_mode must be one of: mirrored, airgap, upstream"
```

When `rke2_image_mode: upstream`, the role removes `/etc/rancher/rke2/registries.yaml` if it exists. This prevents an old Harbor mirror configuration from accidentally affecting a direct-upstream run.

Updated files:

- `deploy_rke2_sm.yaml`
- `deploy_rke2_ha.yaml`
- `roles/rke2_cluster/defaults/main.yml`
- `roles/rke2_cluster/tasks/main.yml`

### 4. Containerd Fallback Allowed Upstream Pulls

RKE2/containerd uses configured mirror endpoints first, but by default it can still fall back to each registry's default upstream endpoint. That means a broken Harbor mirror can be hidden by a successful upstream pull.

**Solution**

Disable default registry endpoint fallback on both server and agent nodes when using `mirrored` or `airgap` mode:

```yaml
rke2_disable_default_registry_endpoint: "{{ rke2_image_mode in ['mirrored', 'airgap'] }}"
```

This renders into `/etc/rancher/rke2/config.yaml` as:

```yaml
disable-default-registry-endpoint: true
```

Expected behavior:

- If Harbor serves the image successfully, the image pull succeeds.
- If Harbor rejects the request, lacks the image, or proxy-cache access is broken, the image pull fails.
- Containerd should not silently pull from Docker Hub, Quay, `registry.k8s.io`, GCR, or GHCR for registries configured in `registries.yaml`.

Updated files:

- `roles/rke2_cluster/templates/config.yaml.j2`
- `roles/rke2_cluster/defaults/main.yml`

### 5. `CriticalAddonsOnly=true:NoExecute` Blocked Bootstrap

The taint is useful and should be kept for steady-state workload isolation:

```yaml
CriticalAddonsOnly=true:NoExecute
```

However, applying it during first-server bootstrap caused some packaged system components to remain pending because they did not all tolerate this taint. This affected Calico Typha first, and later also affected add-ons such as:

```text
rke2-coredns-autoscaler
rke2-metrics-server
rke2-snapshot-controller
```

Because the role waits for the cluster to become ready before progressing, this can deadlock installation.

**Solution**

Do not apply the taint in RKE2 `config.yaml` during installation:

```yaml
rke2_server_node_taints: []
```

After the RKE2 role completes and the cluster has had a chance to deploy system components and join workers, apply the taint as a post-install task:

```yaml
post_tasks:
  - name: Apply control-plane workload isolation taint after cluster installation
    ansible.builtin.command:
      cmd: >-
        {{ rke2_data_path }}/bin/kubectl
        --kubeconfig /etc/rancher/rke2/rke2.yaml
        taint node {{ hostvars[item].rke2_node_name | default(item) }}
        CriticalAddonsOnly=true:NoExecute --overwrite
    loop: "{{ groups['masters'] }}"
    delegate_to: "{{ groups['masters'][0] }}"
    run_once: true
    changed_when: true
    when: not ansible_check_mode
```

This preserves the desired final policy without breaking bootstrap.

### 6. HA Playbook Had an Invalid Duplicate API IP

The HA playbook defined `rke2_api_ip` twice, and the last value was invalid:

```yaml
rke2_api_ip: 10.a.x.y
```

YAML accepts duplicate keys, and Ansible uses the last value.

**Solution**

Remove the duplicate key and set the HA VIP explicitly:

```yaml
rke2_api_ip: 10.163.168.66
```

Updated file:

- `deploy_rke2_ha.yaml`

## Image Mode Reference

### Mirrored Mode

Use Harbor as a pull-through cache and block fallback to upstream registries. The default playbooks also copy the RKE2 installer artifacts from `dataDir/artifact`:

```yaml
rke2_image_mode: mirrored
rke2_artifact_source: copy
rke2_airgap_copy_sourcepath: dataDir/artifact
```

Effective behavior:

- `rke2_airgap_mode: false`
- RKE2 installer artifacts are copied from `dataDir/artifact` to `rke2_artifact_path`.
- If required local artifacts are missing in a dev environment, `rke2_artifact_prepare` downloads/prepares them on the launcher first.
- `/etc/rancher/rke2/registries.yaml` is rendered.
- Harbor projects use the `mirrored-*` prefix.
- `disable-default-registry-endpoint: true` is rendered.

### Airgap Mode

Use Harbor airgap projects:

```yaml
rke2_image_mode: airgap
```

Effective behavior:

- `rke2_airgap_mode: true`
- RKE2 installer artifacts are controlled by `rke2_artifact_source`.
- With `rke2_artifact_source: copy`, missing local artifacts are downloaded/prepared in dev; production airgapped environments should pre-stage them in `dataDir/artifact`.
- `/etc/rancher/rke2/registries.yaml` is rendered.
- Harbor projects use the `airgapped-*` prefix.
- `disable-default-registry-endpoint: true` is rendered.

### Direct Upstream Mode

Use normal upstream public registry pulls without Harbor:

```yaml
rke2_image_mode: upstream
```

Effective behavior:

- `rke2_airgap_mode: false`
- RKE2 installer artifacts are controlled by `rke2_artifact_source`; set it to `upstream` for upstream installer downloads.
- `/etc/rancher/rke2/registries.yaml` is removed if present.
- `disable-default-registry-endpoint` is not rendered.
- Containerd can pull from default upstream registry endpoints.

## Current Recommended Final State

For the current mirrored-mode installation, keep:

```yaml
rke2_image_mode: mirrored
rke2_server_node_taints: []
```

Then apply the control-plane isolation taint after the RKE2 role finishes:

```bash
/var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  taint node <master-node-name> CriticalAddonsOnly=true:NoExecute --overwrite
```

In the playbooks, this is handled by `post_tasks`.

## Bash-to-Ansible Migration

Most cluster installation logic has been moved out of `rke2ClusterInstall.sh` and into Ansible roles/playbooks.

The shell script now mainly handles:

- Launcher-node package prerequisites.
- SSH key generation and distribution.
- Interactive selection of single-node vs HA and image mode.
- Running the appropriate Ansible playbook.
- Local kubeconfig merge convenience.
- Optional post-deployment component installation functions already sourced from `commonFtns.sh`.

The following responsibilities now live in Ansible:

- Local RKE2 airgap artifact preparation for copy mode: `roles/rke2_artifact_prepare`.
- Automatic dev artifact preparation when `rke2_artifact_source: copy` and `dataDir/artifact` is incomplete.
- Optional base Kubernetes node prerequisite setup: `roles/rke2_node_prepare`, controlled by `rke2_node_prepare_enabled`.
- Optional Longhorn/NFS dependency setup: `roles/rke2_storage_prepare`, controlled by `rke2_storage_prepare_enabled`.
- Harbor airgap project creation, Harbor proxy registry creation, mirrored proxy-cache project creation, and optional image push from `rke2_imagelist.txt`: `roles/rke2_harbor_setup`.
- RKE2 installation, first-server bootstrap, remaining node joins, registry auth, default registry fallback control, registry config cleanup for upstream mode, kubeconfig download, HA keepalived config, readiness waits, and final control-plane tainting: `roles/rke2_cluster` plus playbook vars/post-tasks.

Node prerequisite setup defaults to disabled. The target nodes are expected to already have required kernel modules, sysctl values, and swap/firewall policy handled by the base image or separate infrastructure automation unless `rke2_node_prepare_enabled: true` is set. Longhorn/NFS package and iSCSI setup is separate and only runs when `rke2_storage_prepare_enabled: true`.

The playbooks now call roles in this order:

```yaml
roles:
  - role: rke2_artifact_prepare
  - role: rke2_node_prepare
  - role: rke2_storage_prepare
  - role: rke2_harbor_setup
  - role: rke2_cluster
```

Useful tunables:

```yaml
rke2_image_mode: mirrored        # mirrored, airgap, upstream
rke2_artifact_source: copy       # upstream, copy, download, exists
rke2_configure_harbor: false     # set true to create Harbor projects/registries
rke2_push_airgap_images: false   # set true to push rke2_imagelist.txt into Harbor
rke2_node_prepare_enabled: false # set true to run node prerequisite tasks
rke2_storage_prepare_enabled: false # set true to install Longhorn/NFS dependencies
```

## Replacing `roles/lablabs.rke2`

The playbooks no longer call `roles/lablabs.rke2`. The local replacement role is:

```text
roles/rke2_cluster
```

The old vendored role may remain in the repository for comparison or rollback, but it is no longer part of the execution path. The launcher also no longer installs it from Ansible Galaxy.

The replacement role owns:

- RKE2 install script download or airgap install script copy.
- RKE2 artifact copy/download/exists handling.
- `/etc/rancher/rke2/config.yaml` rendering.
- `/etc/rancher/rke2/registries.yaml` rendering/removal.
- `/etc/default/rke2-server` and `/etc/default/rke2-agent` rendering.
- First server bootstrap and API readiness wait.
- Remaining server/agent joins.
- HA keepalived config when enabled.
- Kubeconfig download and endpoint rewrite.

The old patch/update workflow for `roles/lablabs.rke2` was removed because there is no longer a vendored upstream role to keep patched.

## SSH Key Installation With Ansible

The initial SSH public key installation is now handled by an Ansible playbook instead of an ad-hoc shell command:

```text
install_ssh_keys.yaml
```

The playbook runs with `gather_facts: false` so it can execute before key-based authentication is available. It uses password-based SSH for the bootstrap step, creates the remote `.ssh` directory and `authorized_keys` file when needed, and installs the launcher public key idempotently.

The launcher script calls it in Step 2:

```bash
ansible-playbook \
  -i "${RKE2_INVENTORY}" \
  -u "${ROOT_USER}" \
  -e "ansible_password=${ROOT_PASS}" \
  -e "rke2_ssh_public_key_file=${SSH_KEY_FILE}.pub" \
  install_ssh_keys.yaml
```

After the playbook completes, the script verifies fresh key-only SSH authentication with SSH connection reuse disabled. This prevents a stale password-authenticated control socket from hiding a missing key.

## Validation Performed

These checks passed after the playbook changes:

```bash
bash -n rke2ClusterInstall.sh
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_REMOTE_TMP=/tmp/ansible-remote ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp ansible-playbook --syntax-check -i host_inventory_sm.ini install_ssh_keys.yaml
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_REMOTE_TMP=/tmp/ansible-remote ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp ansible-playbook --syntax-check -i host_inventory_sm.ini deploy_rke2_sm.yaml
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_REMOTE_TMP=/tmp/ansible-remote ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp ansible-playbook --syntax-check -i host_inventory_ha.ini deploy_rke2_ha.yaml
```

## Debug Commands Used

Run these from the repository root unless the command is explicitly marked as a node-local command.

### Service, Journal, and RKE2 Config

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TMP=/tmp/ansible-remote \
ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp \
ansible -i host_inventory_sm.ini master-01 \
  --private-key ~/.ssh/id_ed25519-rke2 \
  -b \
  -m shell \
  -a 'echo ===service===; systemctl status rke2-server.service --no-pager -l || true; echo ===journal===; journalctl -u rke2-server.service -n 180 --no-pager || true; echo ===config===; sed -n "1,180p" /etc/rancher/rke2/config.yaml || true; echo ===registries===; sed -n "1,180p" /etc/rancher/rke2/registries.yaml || true; echo ===images-dir===; ls -lah /var/lib/rancher/rke2/agent/images 2>/dev/null || true'
```

Node-local equivalents:

```bash
systemctl status rke2-server.service --no-pager -l
journalctl -u rke2-server.service -n 180 --no-pager
sed -n '1,180p' /etc/rancher/rke2/config.yaml
sed -n '1,180p' /etc/rancher/rke2/registries.yaml
ls -lah /var/lib/rancher/rke2/agent/images 2>/dev/null || true
```

### Harbor and Containerd Mirror Verification

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TMP=/tmp/ansible-remote \
ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp \
ansible -i host_inventory_sm.ini master-01 \
  --private-key ~/.ssh/id_ed25519-rke2 \
  -b \
  -m shell \
  -a 'echo ===containerd-hosts===; find /var/lib/rancher/rke2/agent/etc/containerd/certs.d -maxdepth 2 -type f -name hosts.toml -print -exec sed -n "1,120p" {} \; || true; echo ===harbor-v2===; curl -k -I --connect-timeout 5 https://harbor.util.lcl/v2/ || true; echo ===mirror-pull-test===; /var/lib/rancher/rke2/bin/crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock pull docker.io/library/busybox:1.36 || true'
```

Node-local equivalents:

```bash
find /var/lib/rancher/rke2/agent/etc/containerd/certs.d \
  -maxdepth 2 \
  -type f \
  -name hosts.toml \
  -print \
  -exec sed -n '1,120p' {} \;

curl -k -I --connect-timeout 5 https://harbor.util.lcl/v2/

/var/lib/rancher/rke2/bin/crictl \
  --runtime-endpoint unix:///run/k3s/containerd/containerd.sock \
  pull docker.io/library/busybox:1.36

/var/lib/rancher/rke2/bin/ctr \
  --address /run/k3s/containerd/containerd.sock \
  -n k8s.io \
  images ls
```

### Kubernetes State and Scheduling Diagnosis

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-local \
ANSIBLE_REMOTE_TMP=/tmp/ansible-remote \
ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp \
ansible -i host_inventory_sm.ini master-01 \
  --private-key ~/.ssh/id_ed25519-rke2 \
  -b \
  -m shell \
  -a 'echo ===pods===; /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -A -o wide || true; echo ===nodes===; /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes -o wide || true; echo ===events===; /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get events -A --sort-by=.lastTimestamp | tail -n 80 || true'
```

Node-local equivalents:

```bash
/var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get pods -A -o wide

/var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get nodes -o wide

/var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get events -A --sort-by=.lastTimestamp

/var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get node master-01 -o jsonpath='{.spec.taints}'
```

### Temporary Taint Test Used During Diagnosis

This was used only to confirm the scheduling root cause:

```bash
/var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  taint node master-01 CriticalAddonsOnly=true:NoExecute-
```

To restore the taint manually:

```bash
/var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  taint node master-01 CriticalAddonsOnly=true:NoExecute --overwrite
```

## Operational Note

For an already-partial installation that currently has only `master-01`, remove the taint before rerunning the playbook so the cluster can recover and workers can join:

```bash
/var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  taint node master-01 CriticalAddonsOnly=true:NoExecute-
```

After the playbook completes, the new `post_tasks` section will apply the taint to all masters.
