#!/bin/bash

# kind delete cluster --name kind-clus

lclTZ="${TIMEZONE:-UTC}"
INPUT_FILE='output.log'

ORG_STR_PROXY='http://xxx.yy.zz:8080' #or empty '' if not needed
ORG_PAR_PROXY=',.example.com' 
ORG_DOT_DOMAIN='util.lcl'
ORG_IP_dnsmasq1='10.0.0.9'
ORG_IP_dnsmasq2='0.0.0.0'
ORG_IP_dnsmasq3='1.1.1.1'

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

wait_Pods_plus(){
  local TIME_=${1:-30}
  local TIMEOUT=$(( TIME_/2 ))  
  strInput="[$(TZ=$lclTZ date --date @$(date +%s) +"%a, %d-%b-%Y %H:%M:%S")]"
  echocolor "Waiting for ${TIME_}s kube pods to be ready (Within $2) ..."
  sleep $TIMEOUT
  kubectl wait -A --timeout=${TIMEOUT}s --for=condition=ready pods --field-selector=status.phase!=Succeeded
}

_timestamp() {
  TZ="$LOCAL_TZ" date --date "@$(date +%s)" +"%a, %d-%b-%Y %H:%M:%S"
}

log_info() {
  # $1: message, $2: color (default green=2)
  local ts="[$(_timestamp)]"
  tput setaf "${2:-2}" && echo -e "${ts}: $1" && tput sgr0
  echo "${ts}@log_info: $1" >> "$INPUT_FILE"
}

log_inline() {
  # $1: message, $2: color (default green=2), $3: "no" to skip file logging
  local ts="[$(_timestamp)]"
  tput setaf 3 && echo -ne "${ts}: " && tput setaf "${2:-2}" && echo -ne " $1" && tput sgr0
  if [ "${3:-yes}" != "no" ]; then echo "${ts}@log_inline: $1" >> "$INPUT_FILE"; fi
}

log_title() {
  tput setaf 5 && echo -e "\n**********************************************************************************************"
  log_inline "$1" 4
  tput setaf 5 && echo -e "\n**********************************************************************************************"
  tput sgr0
}

echocolor(){
  # Colour codes: 0 black | 1 red | 2 green | 3 yellow | 4 blue | 5 magenta | 6 cyan | 7 white | 9 default
  strInput="[$(TZ=$lclTZ date --date @$(date +%s) +"%a, %d-%b-%Y %H:%M:%S")]"
  tput setaf ${2:-2} && echo -e "${strInput}: $1" && tput sgr0
  echo "${strInput}@echocolor: $1" >> "$INPUT_FILE"
}

prompt_choice() {
  # $1: space-separated option list, $2: prompt string, $3: default input
  # Sets global: prompt_choice_resp
  local indx=0
  while [ "$indx" -lt 5 ]; do
    indx=$(( indx + 1 ))
    if [ "$indx" -eq 1 ]; then
      local input="${3:-}"
      input="${input^^}"
      [ -z "$input" ] && input="Empty~NULL"
    else
      tput setaf 2 && log_inline "$2 and type in one of these [$1] options and press [ENTER]: " 6 "no"
      read -r raw_input && input="${raw_input^^}"
      [ -z "$input" ] && input="Empty~NULL"
    fi

    local in_list=" \"_- $1 -_\" "
    in_list="${in_list^^}"
    if [[ $in_list =~ (^|[[:space:]])$input($|[[:space:]]) ]]; then
      prompt_choice_resp="$input"
      local ts="[$(_timestamp)]@prompt_choice:"
      echo "$ts $2 ==> $prompt_choice_resp" >> "$INPUT_FILE"
      tput setaf 4 && echo -e "$prompt_choice_resp accepted.\n" && tput sgr0 && break
    else
      if [ "$indx" -eq 4 ]; then
        tput setaf 1 && echo -e "Error: Invalid input! Exiting after the third attempt\n"
        tput sgr0 && exit 1
      else
        if [ "$indx" -ne 1 ]; then tput setaf 5 && echo "Warning: Invalid input try again" && tput sgr0; fi
      fi
    fi
  done
}

time_diff() {
  # $1: start epoch, $2: end epoch
  local diff_sec=$(( $2 - $1 ))
  local day=$(( diff_sec / 86400 ))
  local hour=$(( (diff_sec % 86400) / 3600 ))
  local min=$(( (diff_sec % 3600) / 60 ))
  local sec=$(( diff_sec % 60 ))
  local ret=""

  if [ "$day" -gt 0 ]; then
    ret="${day}d ${hour}h:${min}m:${sec}s"
  elif [ "$hour" -gt 0 ]; then
    ret="${hour}h:${min}m:${sec}s"
  else
    ret="${min}m:${sec}s"
  fi

  tput setaf 5 && echo "**********************************************************************************************"
  tput setaf 2 && echo -n "*** Elapsed Time: "
  tput setaf 3 && echo -n "t2[$(TZ="$LOCAL_TZ" date --date "@$2" +"%a, %d-%b-%Y %H:%M:%S")] - t1[$(TZ="$LOCAL_TZ" date --date "@$1" +"%a, %d-%b-%Y %H:%M:%S")] = "
  tput setaf 2 && echo "$ret ***"
  tput setaf 5 && echo "**********************************************************************************************"
  tput sgr0
}

update_inotify() {
  log_title "Updating inotify"
  sudo sysctl fs.inotify.max_user_instances=2280
  sudo sysctl fs.inotify.max_user_watches=1255360
}

proxy-setting(){
  # Proxy details:
  strProxy=${1:-''} #or empty '' if not needed
  paraProxy=${2:-''}  #or empty '' if not needed
  if [[ -z "$strProxy" ]]; then exit; fi

  printf -v Noproxy '%s,' 10.163.16{8..9}.{1..255} && NoProxy="${Noproxy%?}"
  strNoProxy="localhost,127.0.0.1,${NoProxy},192.168.0.0/16,10.96.0.0/12,10.244.0.0/16,10.43.0.0/16,10.44.0.0/16,.cluster.local,.svc,.default.svc,.util.lcl,.kube.lcl,.k8s.lcl${paraProxy}"

  echocolor "Confuring proxy ..."   
  #region proxy settings
cat << EOF > dum_proxy.txt
PROXY_ENABLED='yes'
HTTP_PROXY=$strProxy
HTTPS_PROXY=$strProxy
FTP_PROXY=$strProxy
NO_PROXY=$strNoProxy

http_proxy=$strProxy
https_proxy=$strProxy
ftp_proxy=$strProxy
no_proxy=$strNoProxy
EOF

cat << EOF > dum_proxy_sh.txt
export ftp_proxy=$strProxy
export http_proxy=$strProxy
export https_proxy=$strProxy
export no_proxy="$strNoProxy"

export FTP_PROXY=$strProxy
export HTTP_PROXY=$strProxy
export HTTPS_PROXY=$strProxy
export NO_PROXY="$strNoProxy"
EOF

cat << EOP > http-proxy.conf
[Service]
Environment="HTTP_PROXY=$strProxy"
Environment="HTTPS_PROXY=$strProxy"
Environment="NO_PROXY=$strNoProxy"
EOP
  sudo cp dum_proxy_sh.txt /etc/profile.d/set_proxy.sh && source /etc/profile.d/set_proxy.sh
  sudo cp http-proxy.conf /etc/systemd/system/docker.service.d/http-proxy.conf && sudo source /etc/systemd/system/docker.service.d/http-proxy.conf
  strOS=$(hostnamectl | grep 'Operating System') && if [[ "$strOS" != *'Ubuntu'* ]]; then cp dum_proxy.txt /etc/sysconfig/proxy; source /etc/sysconfig/proxy; fi
  #endregion dum_proxy_sh.txt  
  sudo systemctl stop docker && sudo systemctl start docker 
}

# -----------------------------------------------------------------------------
# TLS certificate helpers
# -----------------------------------------------------------------------------

get_os(){
  local localOS="no_os"
  local getOS
  getOS=$(hostnamectl | grep 'Operating System')
  declare -A arrOS=([ubuntu]='Ubuntu' [rhel]='Red Hat' [rocky]='Rocky Linux' [sles]='SUSE Linux' [oracle]='Oracle Linux')
  for OS in "${!arrOS[@]}"; do
    if [[ $getOS == *${arrOS[$OS]}* ]]; then localOS=$OS; fi
  done
  if [[ $localOS == "no_os" ]]; then echocolor "Error: OS not supported!" 1; fi
  echo "$localOS"
}

root_ca(){
  log_title "CREATING ROOT CA CERTIFICATE ..."
  local CERTDIR="$1"
  local DOT_DOMAIN="$2"
  local DASH_DOMAIN
  DASH_DOMAIN=$(echo "$DOT_DOMAIN" | sed 's/[.]/-/g')

  if test -d "${CERTDIR}"; then sudo chown "$USER:$USER" -R "${CERTDIR}"; fi
  for f in "${CERTDIR}/${DASH_DOMAIN}-ca.key" "${CERTDIR}/${DASH_DOMAIN}-ca.crt" \
            "/usr/local/share/ca-certificates/${DASH_DOMAIN}-ca.crt"; do
    if test -f "$f"; then sudo rm "$f"; fi
  done

  if test ! -d "${CERTDIR}"; then mkdir -p "${CERTDIR}"; fi
  echocolor "Creating root CA key and certificate ..."
  openssl genrsa -out "${CERTDIR}/${DASH_DOMAIN}-ca.key" 4096
  openssl req -x509 -new -nodes \
    -key "${CERTDIR}/${DASH_DOMAIN}-ca.key" \
    -days 3650 \
    -out "${CERTDIR}/${DASH_DOMAIN}-ca.crt" \
    -subj "/CN=${DOT_DOMAIN}"

  local outOS
  outOS=$(get_os)
  if [[ $outOS == "ubuntu" ]]; then
    echocolor "Trusting CA on Ubuntu ..."
    sudo cp "${CERTDIR}/${DASH_DOMAIN}-ca.crt" /usr/local/share/ca-certificates/
    sudo update-ca-certificates
  elif [[ $outOS == "rhel" ]] || [[ $outOS == "rocky" ]]; then
    echocolor "Trusting CA on RHEL/Rocky ..."
    sudo cp "${CERTDIR}/${DASH_DOMAIN}-ca.crt" /etc/pki/ca-trust/source/anchors/
    sudo update-ca-trust
  elif [[ $outOS == "sles" ]]; then
    echocolor "Trusting CA on SLES ..."
    sudo cp "${CERTDIR}/${DASH_DOMAIN}-ca.crt" /etc/pki/trust/anchors/
    sudo update-ca-certificates
  else
    echocolor "OS not supported for automatic CA trust — trust the CA certificate manually." 3
  fi

  echocolor "Verifying root certificate ..."
  openssl x509 -text -noout -in "${CERTDIR}/${DASH_DOMAIN}-ca.crt"
}

gencert(){
  # Generates a wildcard TLS certificate for the given domain, signed by the local CA.
  # Usage: gencert <dot-domain>   e.g. gencert util.localdev
  local DOT_DOMAIN="$1"
  local DASH_DOMAIN
  DASH_DOMAIN=$(echo "$DOT_DOMAIN" | sed 's/[.]/-/g')
  local CERTDIR="$WORK_DIR/.certDir/$(echo "$DOT_DOMAIN" | sed 's/[.]/_/g')"

  if ! test -f "${CERTDIR}/${DASH_DOMAIN}-ca.crt"; then root_ca "$CERTDIR" "$DOT_DOMAIN"; fi

  if [[ -f "${CERTDIR}/${DASH_DOMAIN}-tls.crt" ]]; then
    echocolor "${DASH_DOMAIN}-tls.crt already exists, skipping"
  else
    log_inline "CREATING TLS CERTIFICATE ..."
    if test ! -d "${CERTDIR}"; then mkdir -p "${CERTDIR}"; fi

    #region
    cat << EOF > "${CERTDIR}/req.cnf"
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.$DOT_DOMAIN
DNS.2 = $DOT_DOMAIN
EOF
  #endregion

    echocolor "Creating client private key ..."
    openssl genrsa -out "${CERTDIR}/${DASH_DOMAIN}-tls.key" 4096
    echocolor "Creating certificate signing request ..."
    openssl req -new \
      -key "${CERTDIR}/${DASH_DOMAIN}-tls.key" \
      -out "${CERTDIR}/${DASH_DOMAIN}-tls.csr" \
      -subj "/CN=${DOT_DOMAIN}" \
      -config "${CERTDIR}/req.cnf"
    echocolor "Signing certificate with local CA ..."
    openssl x509 -req \
      -in "${CERTDIR}/${DASH_DOMAIN}-tls.csr" \
      -CA "${CERTDIR}/${DASH_DOMAIN}-ca.crt" \
      -CAkey "${CERTDIR}/${DASH_DOMAIN}-ca.key" \
      -CAcreateserial \
      -out "${CERTDIR}/${DASH_DOMAIN}-tls.crt" \
      -days 3650 \
      -extensions v3_req \
      -extfile "${CERTDIR}/req.cnf"
    openssl x509 -inform PEM \
      -in "${CERTDIR}/${DASH_DOMAIN}-tls.crt" \
      -out "${CERTDIR}/${DASH_DOMAIN}-tls.cert"
  fi

  if which docker >/dev/null 2>&1; then
    echocolor "Trusting CA in Docker certs.d ..."
    sudo mkdir -p "/etc/docker/certs.d/${DOT_DOMAIN}/"
    sudo cp "${CERTDIR}/${DASH_DOMAIN}-tls.key"  "/etc/docker/certs.d/${DOT_DOMAIN}/${DASH_DOMAIN}-tls.key"
    sudo cp "${CERTDIR}/${DASH_DOMAIN}-tls.cert" "/etc/docker/certs.d/${DOT_DOMAIN}/${DASH_DOMAIN}-tls.cert"
    sudo cp "${CERTDIR}/${DASH_DOMAIN}-ca.crt"   "/etc/docker/certs.d/${DOT_DOMAIN}/ca.crt"
    sudo systemctl restart docker
  fi

  echocolor "Verifying certificate chain ..."
  openssl verify -CAfile "${CERTDIR}/${DASH_DOMAIN}-ca.crt" \
    -verify_hostname "subdomain.${DOT_DOMAIN}" \
    "${CERTDIR}/${DASH_DOMAIN}-tls.crt"
  echocolor "${DASH_DOMAIN}-tls certificate ready."
}

create_tls_secret() {
  local namespace="${1:?namespace required}"
  local secret_name="${2:?secret name required}"
  local dot_domain="${3:?domain required}"
  local dash_domain="${dot_domain//./-}"  
  local cert_dir="$WORK_DIR/.certDir/$(echo "$dot_domain" | sed 's/[.]/_/g')"

  kubectl -n "${namespace}" create secret tls "${secret_name}" \
    --cert="${cert_dir}/${dash_domain}-ca.crt" \
    --key="${cert_dir}/${dash_domain}-ca.key" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# ---------------------------------------------------------------------------
# DNS / resolv.conf
# ---------------------------------------------------------------------------

create_resolv() {
  # https://gist.github.com/coltenkrauter/608cfe02319ce60facd76373249b8ca6 
  local DOT_DOMAIN=${1:?err} # could be multiple
  local IP_dnsmasq2=${2:?err}  
  local IP_dnsmasq3=${3:?err}
  #region
  echocolor "\nUpdating /etc/resolv.conf content ..." # MAX 3 SERVER
cat << EOF > etc_resolv.conf
# Generated by NetworkManager
search util.lcl $DOT_DOMAIN
nameserver $(hostname -I | cut -f1 -d' ')
nameserver $IP_dnsmasq2
nameserver $IP_dnsmasq3
EOF
  #endregion 
}

# ---------------------------------------------------------------------------
# Component installers
# ---------------------------------------------------------------------------

longhorn_install() {
  log_title "Installing Longhorn ..."
  prompt_choice "Y S" "Do you want to install Longhorn? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping Longhorn installation." 4
    return
  fi

  local longhorn_ver="${1:-1.9.0}"

  helm repo add longhorn https://charts.longhorn.io && helm repo update
  helm install longhorn longhorn/longhorn \
    --namespace longhorn-system --create-namespace --version "${longhorn_ver}"

  echocolor "Waiting for Longhorn pods ..." && sleep 60
  kubectl -n longhorn-system get pods
}

cert_manager_install() {
  log_title "Installing cert-manager, create CA secret and ClusterIssuer ..."
  prompt_choice "Y S" "Do you want to install cert-manager? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping cert-manager installation." 4
    return
  fi

  local dot_domain="${1:?domain required}"
  local cert_ver="${2:-1.13.6}"
  local dash_domain="${dot_domain//./-}"

  echocolor "Deploying cert-manager v${cert_ver} ..."
  if [ ! -f "cert-manager.yaml" ]; then
    curl -sfL "https://github.com/cert-manager/cert-manager/releases/download/v${cert_ver}/cert-manager.yaml" > cert-manager.yaml
  fi
  kubectl apply -f cert-manager.yaml
  wait_Pods_plus 180 'cert_manager_install'

  echocolor "Creating CA secret ..."
  create_tls_secret cert-manager "${dash_domain}-ca" "${dot_domain}"
  wait_Pods_plus 60 'cert_manager_install'

  echocolor "Creating ClusterIssuer ..."
  #region
  cat <<EOF | kubectl apply -n cert-manager -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ca-issuer
  namespace: cert-manager
spec:
  ca:
    secretName: ${dash_domain}-ca
EOF
  #endregion
  wait_Pods_plus 60 'cert_manager_install'
}

install_calico() {
  log_title "Installing Calico ..."  
  prompt_choice "Y S" "Do you want to install Calico? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping Calico installation." 4
    return
  fi

  local calico_ver="${1:-3.31.4}"
  if [ ! -f "calico.yaml" ]; then
    curl -sfL https://raw.githubusercontent.com/projectcalico/calico/v${calico_ver}/manifests/calico.yaml > calico.yaml
  fi
  
  kubectl apply -f calico.yaml
  wait_Pods_plus 270 install_calico
  kubectl get pods -A
  log_info "Calico installation complete ..."
}

install_metallb_kind() {
  log_title "Installing MetalLB ..."
  prompt_choice "Y S" "Do you want to install MetalLB? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping MetalLB installation." 4
    return
  fi

  # log_title "Updating mode from iptables to ipvs and strictARP to true ..."
  # kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e 's/mode: iptables/mode: ipvs/' | kubectl diff -f - -n kube-system
  # kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e 's/mode: iptables/mode: ipvs/' | kubectl apply -f - -n kube-system
  # kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: true/" | kubectl diff -f - -n kube-system
  # kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: true/" | kubectl apply -f - -n kube-system

  log_title "Installing MetalLB ..."
  local mb_ver="${1:-0.14.5}"
  if [ ! -f "metallb-native.yaml" ]; then
    curl -sfL "https://raw.githubusercontent.com/metallb/metallb/v${mb_ver}/config/manifests/metallb-native.yaml" > metallb-native.yaml
  fi
  kubectl apply -f metallb-native.yaml
  wait_Pods_plus 150 'metallb_install'

  local kind_subnet=$(docker network inspect -f '{{(index .IPAM.Config 1).Subnet}}' kind)
  local metallb_start=$(echo "$kind_subnet" | sed "s@0.0/16@255.200@")
  local metallb_end=$(echo "$kind_subnet" | sed "s@0.0/16@255.250@")
  log_info "KIND_SUBNET: $kind_subnet | METALLB_START: $metallb_start | METALLB_END: $metallb_end"

  log_info "Configuring MetalLB IP Pool: "
  #region
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-mllb-pool
  namespace: metallb-system
spec:
  addresses:
  - $metallb_start-$metallb_end
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-mllb-l2advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - kind-mllb-pool
EOF
  #endregion

  wait_Pods_plus 60 install_metallb
  kubectl get pods -n metallb-system
  log_info "MetalLB installation complete ..."

  # log_title "Updating coredns by adding util urls ..."
  # kubectl apply -f corefile-kind.yaml
  # kubectl -n kube-system rollout restart deployment coredns
}

install_metallb_k8s() {
  log_title "Installing MetalLB ..."
  prompt_choice "Y S" "Do you want to install MetalLB? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping MetalLB installation." 4
    return
  fi

  local mb_ver="${1:-0.14.5}"
  local pool_start="${2:-192.168.58.50}"
  local pool_stop="${3:-192.168.58.53}"
  
  log_title "Installing MetalLB ..."
  local mb_ver="${1:-0.14.5}"
  if [ ! -f "metallb-native.yaml" ]; then
    curl -sfL "https://raw.githubusercontent.com/metallb/metallb/v${mb_ver}/config/manifests/metallb-native.yaml" > metallb-native.yaml
  fi
  kubectl apply -f metallb-native.yaml
  wait_Pods_plus 150 'metallb_install'

  #region
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: rke2-mllb-pool
  namespace: metallb-system
spec:
  avoidBuggyIPs: true
  addresses:
  - ${pool_start}-${pool_stop}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: rke2-mllb-l2advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - rke2-mllb-pool
EOF
  #endregion

  wait_Pods_plus 30 'metallb_install'
  kubectl get pods -n metallb-system
  echocolor "MetalLB installation complete.\n"

  # log_title "Updating CoreDNS with local domain entries ..."
  # kubectl apply -f corefile-rke2.yaml
  # kubectl -n kube-system rollout restart deployment rke2-coredns-rke2-coredns
  # wait_Pods_plus 15 'metallb_install'
}

install_traefik() {
  log_title "Starting Traefik installation ..." 4
  prompt_choice "Y S" "Do you want to install Traefik? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping Traefik installation." 4
    return
  fi

  local traefik_ver="${1:-37.2.0}"
  local dot_domain="${2:?domain required}"
  echocolor "Installing Traefik ..."
  helm repo add traefik https://traefik.github.io/charts && helm repo update
  helm install traefik traefik/traefik \
    -f ../custom-traefik-values.yaml --namespace traefik --create-namespace --version "${traefik_ver}"

  create_tls_secret traefik traefik-selfsigned-tls "${dot_domain}"
  kubectl -n traefik get svc traefik

  echocolor "Installing nginx test workload ..."
  kubectl get namespace nginx-ns &>/dev/null || kubectl create namespace nginx-ns
  create_tls_secret nginx-ns nginx-selfsigned-tls "${dot_domain}"
  kubectl apply -f ../traefik-nginx.yaml && kubectl -n nginx-ns get svc,pods
  curl -vv "https://nginx.${DOT_DOMAIN}/" | grep -o "<title>.*</title>"
  # curl -vv "https://nginx.k8s.lcl/" | grep -o "<title>.*</title>"
}

install_argocd() {
  log_title "Starting ArgoCD installation ..." 4  
  prompt_choice "Y S" "Do you want to install ArgoCD? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping ArgoCD installation." 4
    return
  fi

  local argocd_ns="${1:-argocd}"
  local argocd_ver="${2:-3.3.2}"

  echocolor "Installing ArgoCD ..."
  kubectl create namespace "${argocd_ns}"
  create_tls_secret "${argocd_ns}" argocd-selfsigned-tls

  tofu apply -auto-approve
  local client_secret
  client_secret=$(tofu output -raw -state="${TF_STATE}" client-secret)

  helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
  helm install argocd argo/argo-cd -n "${argocd_ns}" --set dex.enabled=false

  kubectl -n "${argocd_ns}" apply -f argocd-cm.yaml
  kubectl -n "${argocd_ns}" patch configmap argocd-cmd-params-cm \
    --type merge -p '{"data":{"server.insecure":"true"}}'
  kubectl -n "${argocd_ns}" rollout restart deploy argocd-server
  kubectl -n "${argocd_ns}" rollout status deploy argocd-server

  kubectl apply -f argocd-gtw.yaml
  kubectl -n "${argocd_ns}" get pods,svc,gateway

  local argocd_pass
  argocd_pass=$(kubectl -n "${argocd_ns}" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
  echocolor "ArgoCD credentials — Username: admin | Password: ${argocd_pass}"
}

install_istio() {
  log_title "Starting Istio installation ..." 4
  prompt_choice "Y S" "Do you want to install Istio? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping Istio  installation." 4
    return
  fi

  local istio_ver="${1:-1.28.1}"

  log_title "Downloading Istio v${istio_ver} ..."
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION="${istio_ver}" TARGET_ARCH=x86_64 sh -
  export PATH="${PATH}:${PWD}/istio-${istio_ver}/bin"
  istioctl version

  log_title "Installing Istio ..."
  istioctl install --filename istioOperator-jwks-config.yaml --skip-confirmation

  # BookInfo sample app
  log_title "Installing BookInfo app ..." 4
  kubectl create ns bookinfo
  kubectl label namespace bookinfo istio-injection=enabled
  kubectl config set-context --current --namespace bookinfo

  kubectl -n bookinfo apply -f "istio-${istio_ver}/samples/bookinfo/platform/kube/bookinfo.yaml"
  kubectl get pods,services
  kubectl exec "$(kubectl get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}')" \
    -c ratings -- curl -sS productpage:9080/productpage | grep -o "<title>.*</title>"

  kubectl apply -f "istio-${istio_ver}/samples/bookinfo/networking/bookinfo-gateway.yaml"
  kubectl get gateway.networking.istio.io,virtualservice.networking.istio.io

  local ingress_name=istio-ingressgateway
  local ingress_ns=istio-system
  local ingress_host ingress_port
  ingress_host=$(kubectl -n "${ingress_ns}" get service "${ingress_name}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  ingress_port=$(kubectl -n "${ingress_ns}" get service "${ingress_name}" -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
  local gateway_url="${ingress_host}:${ingress_port}"
  echo "GATEWAY_URL: ${gateway_url}"
  curl -s "http://${gateway_url}/productpage" | grep -o "<title>.*</title>"

  # Keycloak integration
  log_title "Installing Istio + Keycloak integration ..." 4
  if [ ! -d istio-keycloak ]; then
    git clone https://github.com/infracloudio/istio-keycloak.git
  fi
  kubectl create ns keycloak
  kubectl label namespace keycloak istio-injection=enabled
  kubectl config set-context --current --namespace keycloak
  cd istio-keycloak
  kubectl apply -f app/

  wait_Pods_plus 150 istio_install
  kubectl -n keycloak get pods,services

  kubectl apply -f istio-manifests/ingressGateway.yaml
  kubectl apply -f istio-manifests/virtualService.yaml
  kubectl -n keycloak get gateway.networking.istio.io,virtualservice.networking.istio.io

  local lb_ip
  lb_ip=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  curl -X GET -H "host: book-info.test.io" "http://${lb_ip}/getbooks" && echo

  wait_Pods_plus 25 istio_install
  curl -X POST -H "host: book-info.test.io" \
    -d '{"isbn": 9781982156909, "title": "The Comedy of Errors", "synopsis": "Shakespeare play", "authorname": "William Shakespeare", "price": 10.39}' \
    "http://${lb_ip}/addbook"
  curl -X GET -H "host: book-info.test.io" "http://${lb_ip}/getbooks" && echo

  local keycloak_url='https://keycloak.util.lcl'

  #region
  cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: book-info-request-authentication
spec:
  selector:
    matchLabels:
      app: book-info
  jwtRules:
  - issuer: "${keycloak_url}/realms/istio"
    jwksUri: "${keycloak_url}/realms/istio/protocol/openid-connect/certs"
    forwardOriginalToken: true
EOF

  cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: book-info-auth
spec:
  selector:
    matchLabels:
      app: book-info
  rules:
  - from:
    - source:
        requestPrincipals: ["*"]
EOF
  #endregion

  wait_Pods_plus 15 istio_install
  curl -X GET -H "host: book-info.test.io" "http://${lb_ip}/getbooks" && echo

  local token_response access_token
  token_response=$(curl -X POST \
    -d "client_id=istio" -d "username=book-user" -d "password=book-user" -d "grant_type=password" \
    "${keycloak_url}/realms/istio/protocol/openid-connect/token")
  access_token=$(echo "${token_response}" | jq -r '.access_token')
  curl -X GET -H "host: book-info.test.io" -H "Authorization: Bearer ${access_token}" \
    "http://${lb_ip}/getbooks" && echo
}

cilium_gateway_install() {  
  log_title "Installing Cilium Gateway API with L2 announcements ..."
  prompt_choice "Y S" "Do you want to install Cilium Gateway API? Type \"y\" for yes or \"s\" for skip" && local resp=$prompt_choice_resp
  if [ "${resp}" = "S" ]; then
    echocolor "Skipping Cilium Gateway API installation." 4
    return
  fi

  local pool_start="${1:-10.163.168.62}"
  local pool_stop="${2:-10.163.168.65}"

  #region
  cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
  description: The default Cilium GatewayClass
EOF

  echocolor "\nReconfiguring Cilium ConfigMap ..." 2
  kubectl get configmaps -n kube-system cilium-config -o yaml --type merge -p '{"data":{"cni-exclusive":"false"}}'
  kubectl get configmaps -n kube-system cilium-config -o yaml --type merge -p '{"data":{"bpf-lb-sock-hostns-only":"true"}}'
  kubectl get configmaps -n kube-system cilium-config -o yaml --type merge -p '{"data":{"gateway-api-hostnetwork-enabled":"true"}}'
  kubectl -n kube-system rollout restart deployment/cilium-operator
  kubectl -n kube-system rollout restart ds/cilium
  wait_Pods_plus 45 "cilium_gateway_install"

  cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: rke2-policy
spec:
  interfaces:
  - ens160
  externalIPs: true
  loadBalancerIPs: true
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: rke2-pool
spec:
  blocks:
  - start: "${pool_start}"
    stop:  "${pool_stop}"
EOF

  # Gateway API CRDs
  echocolor "\nInstalling Gateway API CRDs ..." 2
  kubectl apply -f gtw_standard-install.yaml
  kubectl get crd | grep gateway.networking
  wait_Pods_plus 10 "cilium_gateway_install"

  cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cilium-gateway
  namespace: cilium
spec:
  gatewayClassName: cilium
  listeners:
  - name: web
    protocol: HTTP
    port: 8880
    allowedRoutes:
      namespaces:
        from: All
  - name: websecure
    protocol: HTTPS
    port: 8443
    allowedRoutes:
      namespaces:
        from: All
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: cilium-selfsigned-tls
EOF
  #endregion

  create_tls_secret cilium cilium-selfsigned-tls
  kubectl -n cilium get svc cilium

  echocolor "Installing nginx test workload ..."
  kubectl create namespace nginx-ns
  create_tls_secret nginx-ns nginx-selfsigned-tls
  kubectl apply -f cilium-nginx.yaml && kubectl -n nginx-ns get svc,pods
  wait_Pods_plus 60 "cilium_gateway_install"
  curl "https://nginx.${DOT_DOMAIN}/" | grep -o "<title>.*</title>"
}

