#!/usr/bin/env bash
set -euo pipefail

## update-dns.sh — Sync dnsmasq with Traefik's current LoadBalancer IP
##
## Detects the Traefik service external IP and updates dnsmasq to point
## *.k8s.lcl (or your configured domain) to it.
##
## Useful after cluster restarts when MetalLB assigns a new IP.
##
## Usage:
##   ../update-dns.sh                    # uses default domain .k8s.lcl
##   ../update-dns.sh .example.lcl       # custom domain
##
## Prerequisites: kubectl, sudo access for dnsmasq config

DOMAIN="${1:-.k8s.lcl}"
DNSMASQ_CONF="/etc/dnsmasq.d/k8s_lcl.conf"
TRAEFIK_NS="${TRAEFIK_NS:-traefik}"
TRAEFIK_SVC="${TRAEFIK_SVC:-traefik}"

log() { tput setaf 2; echo "[$(date '+%H:%M:%S')] $*"; tput sgr0 2>/dev/null; }
err() { tput setaf 1; echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; tput sgr0 2>/dev/null; }

# Get Traefik's current external IP
TRAEFIK_IP=$(kubectl get svc "${TRAEFIK_SVC}" -n "${TRAEFIK_NS}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -z "$TRAEFIK_IP" ]]; then
  err "Could not get Traefik external IP — is Traefik running with a LoadBalancer service?"
  echo ""
  echo "  kubectl get svc -n ${TRAEFIK_NS}"
  exit 1
fi

log "Traefik external IP: ${TRAEFIK_IP}"

# Check current dnsmasq config
if [[ -f "$DNSMASQ_CONF" ]]; then
  CURRENT_IP=$(grep -oP 'address=/.*?/\K[0-9.]+' "$DNSMASQ_CONF" 2>/dev/null || echo "")
  if [[ "$CURRENT_IP" == "$TRAEFIK_IP" ]]; then
    log "dnsmasq already points to ${TRAEFIK_IP} — no update needed"
    exit 0
  fi
  log "Updating dnsmasq: ${CURRENT_IP:-<not set>} → ${TRAEFIK_IP}"
  sudo sed -i "s|address=/${DOMAIN}/.*|address=/${DOMAIN}/${TRAEFIK_IP}|" "$DNSMASQ_CONF"
else
  log "Creating ${DNSMASQ_CONF}"
  echo "address=/${DOMAIN}/${TRAEFIK_IP}" | sudo tee "$DNSMASQ_CONF" > /dev/null
fi

# Restart dnsmasq
sudo systemctl restart dnsmasq
log "dnsmasq restarted"

# Verify
RESOLVED=$(nslookup "kubeflow${DOMAIN}" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' || echo "")
if [[ "$RESOLVED" == "$TRAEFIK_IP" ]]; then
  log "DNS verified: kubeflow${DOMAIN} → ${TRAEFIK_IP}"
else
  log "DNS check: kubeflow${DOMAIN} → ${RESOLVED:-<failed>} (expected ${TRAEFIK_IP})"
fi

echo ""
echo "=========================================="
echo " DNS updated"
echo "=========================================="
echo " Domain  : *${DOMAIN}"
echo " IP      : ${TRAEFIK_IP}"
echo " Config  : ${DNSMASQ_CONF}"
echo "=========================================="
