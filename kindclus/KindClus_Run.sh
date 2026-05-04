#!/bin/bash
# chmod +x KindClus_Run.sh && ./KindClus_Run.sh
set -euo pipefail

trap 'log_info "Script failed at line $LINENO" 1' ERR

# === Configuration ===
START_TIME=$(date +%s)
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

KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.33.4}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.19.4}"
METALLB_VERSION="${METALLB_VERSION:-0.15.3}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-37.2.0}"
ARGOCD_VERSION="${ARGOCD_VERSION:-3.3.3}"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.9.0}"
CILIUM_LB_IP_START="${CILIUM_LB_IP_START:-10.163.168.62}"
CILIUM_LB_IP_END="${CILIUM_LB_IP_END:-10.163.168.65}"


# === Cluster & Component Functions ===

generate_extra_mounts() {
  cat <<MOUNTS
  extraMounts:
  - hostPath: ${CERTDIR}/gitea-cr.toml
    containerPath: /etc/containerd/certs.d/gitea.$DOT_DOMAIN/hosts.toml
    readOnly: true
  - hostPath: ${CERTDIR}/${DASH_DOMAIN}-ca.crt
    containerPath: /usr/local/share/ca-certificates/util-lcl-ca.crt
    readOnly: true 
  - hostPath: $WORK_DIR/util_lcl/util-lcl-ca.crt
    containerPath: /usr/local/share/ca-certificates/util-lcl-ca.crt
    readOnly: true
MOUNTS
}

setup_image_cache() {
  local reg_list=(docker quay gcr ghcr k8s-gcr)
  local nport=5000
  for reg in "${reg_list[@]}"; do
    (( nport += 1 ))
    local remote_url
    if [ "$nport" == "5001" ]; then remote_url='registry-1.docker.io'
    elif [ "$nport" == "5005" ]; then remote_url='k8s.gcr.io'
    else remote_url="${reg}.io"
    fi
    echo -e "\n=== Installing Reg[${reg}]:Port[${nport}]:"
    docker run -d --name "proxy-${reg}" --restart=always --net=kind \
      -p "${nport}:5000" -e "REGISTRY_PROXY_REMOTEURL=https://${remote_url}" registry:2
  done
  docker ps

  for i in {1..5}; do
    local j=$(( i - 1 ))
    echo -e "\n=== Listing Repo of ${reg_list[${j}]}"
    curl -X GET "http://127.0.0.1:500${i}/v2/_catalog"
  done
}

create_kind_cluster(){ 
  if [[ "$(docker inspect -f '{{.State.Running}}' kind-clus-control-plane 2>/dev/null || true)" == 'true' ]]; then
    prompt_choice "D S" "Kind Cluster is already installed. Do you want to delete it or skip to continue? Type \"d\" for delete or \"s\" for skip" && local resp="$prompt_choice_resp"
    if [ "$resp" = "S" ]; then
      log_info "Skipping Step 3 ..." 4
      return 0
    else
      log_title "Deleting Kind Cluster"
      kind delete cluster --name kind-clus
      exit
    fi
  fi

  log_title "Creating a KinD cluster using .yaml configuration"
  gencert "$DOT_DOMAIN"
  cluster_name=${DASH_DOMAIN}-clus
  KIND_NODE_IMAGE=kindest/node:v1.33.4 #.33.5

  #region ===
cat <<EOF | kind create cluster --name=kind-clus --image $KIND_NODE_IMAGE --kubeconfig ./kindClus.yaml --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["http://proxy-docker:5000"]
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
      endpoint = ["http://proxy-quay:5000"]
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."gcr.io"]
      endpoint = ["http://proxy-gcr:5000"]
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."ghcr.io"]
      endpoint = ["http://proxy-ghcr:5000"]
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."k8s.gcr.io"]
      endpoint = ["http://proxy-k8s-gcr:5005"]
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 8880 
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
  - containerPort: 8000
    hostPort: 8000
    protocol: TCP
  extraMounts:
  - hostPath: $WORK_DIR/.certDir/util_lcl/util-lcl-ca.crt
    containerPath: /usr/local/share/ca-certificates/util-lcl-ca.crt
    readOnly: true
  - hostPath: ${CERTDIR}/${DASH_DOMAIN}-ca.crt 
    containerPath: /usr/local/share/ca-certificates/${DASH_DOMAIN}-ca.crt 
    readOnly: true
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        "service-account-issuer": "kubernetes.default.svc"
        "service-account-signing-key-file": "/etc/kubernetes/pki/sa.key"
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
- role: worker
  extraMounts:
  - hostPath: $WORK_DIR/.certDir/util_lcl/util-lcl-ca.crt
    containerPath: /usr/local/share/ca-certificates/util-lcl-ca.crt
    readOnly: true
  - hostPath: ${CERTDIR}/${DASH_DOMAIN}-ca.crt 
    containerPath: /usr/local/share/ca-certificates/${DASH_DOMAIN}-ca.crt 
    readOnly: true
- role: worker
  extraMounts:  
  - hostPath: $WORK_DIR/.certDir/util_lcl/util-lcl-ca.crt
    containerPath: /usr/local/share/ca-certificates/util-lcl-ca.crt
    readOnly: true
  - hostPath: ${CERTDIR}/${DASH_DOMAIN}-ca.crt 
    containerPath: /usr/local/share/ca-certificates/${DASH_DOMAIN}-ca.crt 
    readOnly: true
EOF
  kind get kubeconfig --name kind-clus > ~/.kube/config 

  wait_Pods_plus 60 create_Kind_cluster
  kind get clusters && kubectl get nodes 

  nodes=($(kubectl get nodes -o custom-columns=":metadata.name" --no-headers))  
  echo "All nodes: ${nodes[@]}" 
  for node in "${nodes[@]}"; do echo "==== Running update-ca-certificates on node name: $node"; docker exec $node update-ca-certificates; done 
  echocolor "Kind cluster installation complete ..."
  #endregion ===
}

# === Main Execution ===
main() {
  # Step 0: 
  # setup_image_cache

  # Step 1: Create Kind Cluster
  create_kind_cluster

  # Step 2: Install required components
  log_title "Step 2: Installing other required components: MetalLB (or Cilium Hostnetwork), Cert-manager ..." 4
  cert_manager_install "$DOT_DOMAIN" "$CERT_MANAGER_VERSION" "$K8S_USER"
  install_calico
  install_metallb_kind
  install_traefik 37.2.0  "$DOT_DOMAIN"

  log_info "Step 4 Complete:" && echo ""
  time_diff "$START_TIME" "$(date +%s)"
  # docker inspect --format='{{json .Config.Labels}}' <container_name> | jq .
}

main "$@"
