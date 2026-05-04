#!/bin/bash
set -euo pipefail

#  cat /var/lib/rancher/rke2/agent/etc/containerd/certs.d/docker.io/hosts.toml 
#  cat /var/lib/rancher/rke2/agent/etc/containerd/config.toml

# RKE2 Cluster Installation Script
# Usage: ./rke2ClusterInstall.sh [ha|sm]
#   ha  - High-availability multi-master cluster
#   sm  - Single-master cluster

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RKE2_HA=${1:-sm}
case "${RKE2_HA}" in
  sm|ha) ;;
  *)
    echo "Usage: $0 [ha|sm]" >&2
    exit 1
    ;;
esac
START_TIME=$(date +%s)

# === Configuration ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_FILE="$PWD/input_file.txt"

# Load .env if present, then fall back to defaults
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

source "../commonFtns.sh"
LOCAL_TZ="${LOCAL_TZ:-UTC}"
PREFIX="${PREFIX:-kube}"
SUFFIX="${SUFFIX:-localdev}"
K8S_USER="${K8S_USER:-$USER}"
DOT_DOMAIN="${PREFIX}.${SUFFIX}"
DASH_DOMAIN=$(echo "$DOT_DOMAIN" | sed 's/[.]/-/g')

WORK_DIR="${WORK_DIR:-$HOME/workdir}"
CERTDIR="${CERTDIR:-$WORK_DIR/.certDir/$(echo "$DOT_DOMAIN" | sed 's/[.]/_/g')}"

ROOT_USER="${ROOT_USER:-root}"
ROOT_PASS="${ROOT_PASS:-Vagroot}"

# Registry configuration
REG_USER="${REG_USER:-admin}"
REG_PASS="${REG_PASS:-Admin001}"
REG_HOST="${REG_HOST:-harbor.util.lcl}"

# SSH configuration
SSH_KEY_TYPE=ed25519
SSH_KEY_FILE="${HOME}/.ssh/id_${SSH_KEY_TYPE}-rke2"
ANSIBLE_COMMON_ENV=(
  ANSIBLE_HOST_KEY_CHECKING=False
  ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
  ANSIBLE_REMOTE_TMP=/tmp/ansible-remote
  ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp
)

if [ "${RKE2_HA}" = "ha" ]; then
  RKE2_INVENTORY="host_inventory_ha.ini"
  RKE2_PLAYBOOK="deploy_rke2_ha.yaml"
else # single-master
  RKE2_INVENTORY="host_inventory_sm.ini"
  RKE2_PLAYBOOK="deploy_rke2_sm.yaml"
fi

# RKE2 version & artifacts
RKE2_REL="${RKE2_REL:-rke2r3}"
RKE2_VERSION="${RKE2_VERSION:-1.35.3}"
RKE2_ARCH="${RKE2_ARCH:-amd64}"
ARTIFACT_BASE_DIR=dataDir
VER_TAG="${RKE2_VERSION//./-}"

# Component versions
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.19.4}"
METALLB_VERSION="${METALLB_VERSION:-0.15.3}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-37.2.0}"
ARGOCD_VERSION="${ARGOCD_VERSION:-3.3.3}"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.9.0}"

# Cilium LB IP range
CILIUM_LB_IP_START="${CILIUM_LB_IP_START:-10.163.168.62}"
CILIUM_LB_IP_END="${CILIUM_LB_IP_END:-10.163.168.65}"

echo -e "\n\n" >> "${INPUT_FILE}"

if [ ! -d "roles/rke2_cluster" ]; then
  echo "Missing local role: roles/rke2_cluster" >&2
  exit 1
fi
# sudo apt install -y python3-netaddr

# ---------------------------------------------------------------------------
# Step 1: Pre-installation on the launcher node
# ---------------------------------------------------------------------------

step1_prereqs() {
  log_title "Step 1: Pre-installation on the launcher node" 4
  prompt_choice "Y S" "Do you want to continue with step 1? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping step 1." 4
    return
  fi

  echocolor "Installing prerequisites: ansible, sshpass, openssl, ldap-utils ..."
  local os_info
  os_info=$(hostnamectl | grep 'Operating System')
  tput setaf 4 && echo -e "Running on ${os_info}\n" && tput sgr0

  if [[ "${os_info}" == *'Ubuntu'* ]]; then
    sudo apt update -y && sudo apt upgrade -y
    sudo apt install ansible curl software-properties-common uidmap -y
    sudo apt-get install openssl ldap-utils -y
    sudo apt -y install sshpass
  elif [[ "${os_info}" == *'Red Hat'* ]] || [[ "${os_info}" == *'Rocky Linux'* ]]; then
    sudo dnf check-update || true
    if [[ "${os_info}" == *'Red Hat'* ]]; then
      subscription-manager register --auto-attach --force
      subscription-manager repos --enable "codeready-builder-for-rhel-8-$(arch)-rpms"
      sudo dnf install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm" -y
    else
      sudo dnf config-manager --set-enabled powertools
      sudo dnf install epel-release -y
    fi
    sudo dnf install ansible curl openssl openldap-clients -y
    sudo dnf install -y sshpass
  else
    echo "Unsupported OS. Exiting." && exit 1
  fi

  log_inline "Step 1 Complete:" && echo
  time_diff "${START_TIME}" "$(date +%s)"
}

# ---------------------------------------------------------------------------
# Step 2: SSH key setup
# ---------------------------------------------------------------------------

step2_ssh_setup() {
  log_title "Step 2: SSH key distribution to nodes with Ansible ..." 4
  prompt_choice "Y S" "Do you want to continue with step 2? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping step 2." 4
    return
  fi

  if [ ! -f "${SSH_KEY_FILE}" ]; then
    ssh-keygen -t "${SSH_KEY_TYPE}" -f "${SSH_KEY_FILE}" -C "RKE2 cluster key" -N ""
  fi

  echocolor "Checking SSH reachability for inventory ${RKE2_INVENTORY} ..." 4
  if ! env "${ANSIBLE_COMMON_ENV[@]}" \
    ansible all \
      -i "${RKE2_INVENTORY}" \
      -u "${ROOT_USER}" \
      -e "ansible_password=${ROOT_PASS}" \
      -m wait_for_connection \
      -a "timeout=10"; then
    echo
    echo "Unable to reach one or more nodes over SSH." >&2
    echo "Check that the nodes are running, the inventory IPs are correct, port 22 is reachable, and SSH allows ${ROOT_USER} login." >&2
    echo "Inventory in use: ${RKE2_INVENTORY}" >&2
    exit 1
  fi

  echocolor "Installing SSH public key with Ansible ..." 4
  env "${ANSIBLE_COMMON_ENV[@]}" \
  ansible-playbook \
    -i "${RKE2_INVENTORY}" \
    -u "${ROOT_USER}" \
    -e "ansible_password=${ROOT_PASS}" \
    -e "rke2_ssh_public_key_file=${SSH_KEY_FILE}.pub" \
    install_ssh_keys.yaml

  echocolor "Verifying fresh SSH key authentication ..." 4
  env "${ANSIBLE_COMMON_ENV[@]}" \
    ANSIBLE_SSH_ARGS="-o ControlMaster=no -o ControlPath=none" \
    ansible all \
      -i "${RKE2_INVENTORY}" \
      -u "${ROOT_USER}" \
      --private-key "${SSH_KEY_FILE}" \
      -m ping

  eval "$(ssh-agent -s)"
  ssh-add "${SSH_KEY_FILE}"

  echocolor "SSH key distribution complete. RKE2 deployment now runs through Ansible." 4

  log_inline "Step 2 Complete:" && echo
  time_diff "${START_TIME}" "$(date +%s)"
}

# ---------------------------------------------------------------------------
# Step 3: RKE2 cluster deployment
# ---------------------------------------------------------------------------

step3_deploy_cluster() {
  log_title "Step 3: RKE2 cluster deployment ..." 4
  prompt_choice "Y U S" "Type \"y\" to install, \"u\" to uninstall, or \"s\" to skip" && local resp=$prompt_choice_resp

  if [ "${resp}" = "S" ]; then
    echocolor "Skipping step 3." 4
    return
  fi

  if [ "${resp}" = "U" ]; then
    echocolor "Uninstalling RKE2 ..." 4
    env "${ANSIBLE_COMMON_ENV[@]}" \
    ansible all \
      -i "${RKE2_INVENTORY}" \
      -u "${ROOT_USER}" \
      --private-key "${SSH_KEY_FILE}" \
      -b \
      -m shell \
      -a '/usr/local/bin/rke2-uninstall.sh || true; rm -f /etc/systemd/system/rke2-agent.service /etc/systemd/system/rke2-server.service /etc/default/rke2-agent /etc/default/rke2-server /run/keepalived.pid; rm -rf /var/lib/rancher /rke2 /run/containerd /run/k3s'
    tofu destroy -auto-approve
    echocolor "Uninstall complete." 4
    exit 0
  fi

  prompt_choice "M A U" "Image mode? Type \"m\" for mirrored, \"a\" for airgap, or \"u\" for direct upstream" && local resp_kind=$prompt_choice_resp
  local image_mode="mirrored"
  case "${resp_kind}" in
    M) image_mode="mirrored" ;;
    A) image_mode="airgap" ;;
    U) image_mode="upstream" ;;
  esac

  local configure_harbor="false"
  local push_airgap_images="false"
  if [ "${image_mode}" != "upstream" ]; then
    prompt_choice "Y N" "Configure Harbor projects/proxy registries from Ansible? Type \"y\" or \"n\"" && local harbor_resp=$prompt_choice_resp
    [ "${harbor_resp}" = "Y" ] && configure_harbor="true"
  fi
  if [ "${image_mode}" = "airgap" ]; then
    prompt_choice "Y N" "Push images from rke2_imagelist.txt into Harbor? Type \"y\" or \"n\"" && local push_resp=$prompt_choice_resp
    [ "${push_resp}" = "Y" ] && push_airgap_images="true"
  fi

  local rke2_ver="v${RKE2_VERSION}+${RKE2_REL}"
  if [ "${RKE2_HA}" = "ha" ]; then
    echocolor "Deploying HA cluster ..." 2
  else
    echocolor "Deploying single-master cluster ..." 2
  fi

  env "${ANSIBLE_COMMON_ENV[@]}" \
  ansible-playbook \
    -i "${RKE2_INVENTORY}" \
    -u "${ROOT_USER}" \
    --private-key "${SSH_KEY_FILE}" \
    -e "rke2_version=${rke2_ver}" \
    -e "rke2_image_mode=${image_mode}" \
    -e "rke2_harbor_registry_url=${REG_HOST}" \
    -e "rke2_custom_registry_username=${REG_USER}" \
    -e "rke2_custom_registry_password=${REG_PASS}" \
    -e "rke2_configure_harbor=${configure_harbor}" \
    -e "rke2_push_airgap_images=${push_airgap_images}" \
    "${RKE2_PLAYBOOK}"

  # Kubeconfig setup
  echocolor "\nSetting up kubeconfig ..."
  mkdir -p "/home/${K8S_USER}/.kube"
  cp rke2-kubeconfig "/home/${K8S_USER}/.kube/rke2.conf"
  export KUBECONFIG="/home/${K8S_USER}/.kube/k8s.conf:/home/${K8S_USER}/.kube/rke2.conf"
  local merged_kubeconfig
  merged_kubeconfig="$(mktemp)"
  kubectl config view --flatten > "${merged_kubeconfig}" && cp "${merged_kubeconfig}" "/home/${K8S_USER}/.kube/config"
  rm -f "${merged_kubeconfig}"
  chown "${K8S_USER}:${K8S_USER}" "/home/${K8S_USER}/.kube/config"
  chmod 600 "/home/${K8S_USER}/.kube/config"

  # Distribute TLS certs to workers
  echocolor "Distributing TLS certificates to worker nodes with Ansible ..."
  if [ -f "${CERTDIR}/${DASH_DOMAIN}-tls.crt" ] && [ -f "${CERTDIR}/${DASH_DOMAIN}-tls.key" ] && [ -f "${CERTDIR}/${DASH_DOMAIN}-ca.crt" ]; then
    env "${ANSIBLE_COMMON_ENV[@]}" \
    ansible workers \
      -i "${RKE2_INVENTORY}" \
      -u "${ROOT_USER}" \
      --private-key "${SSH_KEY_FILE}" \
      -b \
      -m file \
      -a 'path=/etc/rancher/cert state=directory owner=root group=root mode=0755'

    env "${ANSIBLE_COMMON_ENV[@]}" \
    ansible workers \
      -i "${RKE2_INVENTORY}" \
      -u "${ROOT_USER}" \
      --private-key "${SSH_KEY_FILE}" \
      -b \
      -m copy \
      -a "src=${CERTDIR}/${DASH_DOMAIN}-tls.crt dest=/etc/rancher/cert/${DASH_DOMAIN}-tls.crt owner=root group=root mode=0644"

    env "${ANSIBLE_COMMON_ENV[@]}" \
    ansible workers \
      -i "${RKE2_INVENTORY}" \
      -u "${ROOT_USER}" \
      --private-key "${SSH_KEY_FILE}" \
      -b \
      -m copy \
      -a "src=${CERTDIR}/${DASH_DOMAIN}-tls.key dest=/etc/rancher/cert/${DASH_DOMAIN}-tls.key owner=root group=root mode=0600"

    env "${ANSIBLE_COMMON_ENV[@]}" \
    ansible workers \
      -i "${RKE2_INVENTORY}" \
      -u "${ROOT_USER}" \
      --private-key "${SSH_KEY_FILE}" \
      -b \
      -m copy \
      -a "src=${CERTDIR}/${DASH_DOMAIN}-ca.crt dest=/etc/rancher/cert/${DASH_DOMAIN}-ca.crt owner=root group=root mode=0644"
  else
    echocolor "TLS certificate files not found under ${CERTDIR}; skipping worker certificate distribution." 3
  fi

  export KUBECONFIG="/home/${K8S_USER}/.kube/config"
  kubectl config use-context default
  kubectl get nodes -o wide && echo
  kubectl get pods -A

  echocolor "Cluster deployment complete."
  log_inline "Step 3 Complete:" && echo
  time_diff "${START_TIME}" "$(date +%s)"
}

# ---------------------------------------------------------------------------
# Step 4: Post-deployment components
# ---------------------------------------------------------------------------

step4_components() {
  export KUBECONFIG="/home/${K8S_USER}/.kube/config"

  # Step 4: Install required components
  log_title "Step 4: Installing other required components: MetalLB (or Cilium Hostnetwork), Cert-manager ..." 4
  cert_manager_install "$DOT_DOMAIN" "$CERT_MANAGER_VERSION" "$K8S_USER"
    
  prompt_choice "M H" "MetalLB or Cilium HostNetwork? Type \"m\" or \"h\"" && local lb_resp=$prompt_choice_resp
  if [ "${lb_resp}" = "M" ]; then
    install_metallb_k8s "${METALLB_VERSION}"
    install_traefik "${TRAEFIK_VERSION}" "$DOT_DOMAIN"
  else
    cilium_gateway_install "${CILIUM_LB_IP_START}" "${CILIUM_LB_IP_END}"
  fi

  # longhorn_install "${LONGHORN_VERSION}"
  # argocd_install argocd "${ARGOCD_VERSION}"

  # Then update dnsmasq:    
  ../update-dns.sh ".$DOT_DOMAIN"

  echocolor "Step 4 Complete:"
  time_diff "${START_TIME}" "$(date +%s)"
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

echo "${SSH_KEY_FILE}" && eval "$(ssh-agent -s)" && ssh-add "${SSH_KEY_FILE}"

step1_prereqs
step2_ssh_setup
step3_deploy_cluster
step4_components
