#!/usr/bin/env bash
# Funciones compartidas por los scripts de validación. No se ejecuta solo:
# lo cargan los demás con "source".
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

TENANTS_YML="${ROOT_DIR}/secrets/generated/tenants.yml"

if [[ ! -f "${TENANTS_YML}" ]]; then
  echo "Faltan los secretos (${TENANTS_YML}). Ejecuta primero scripts/generate-secrets.sh" >&2
  exit 1
fi

get_secret() {
  # get_secret <clave>   (clave tal y como aparece en tenants.yml, p.ej. cliente-a.ingest_password)
  local key="$1"
  case "${key}" in
    cliente-a.ingest_user)     grep -A2 '^  cliente-a:' "${TENANTS_YML}" | grep ingest_user     | sed -E 's/.*: *"([^"]+)".*/\1/' ;;
    cliente-a.ingest_password) grep -A2 '^  cliente-a:' "${TENANTS_YML}" | grep ingest_password | sed -E 's/.*: *"([^"]+)".*/\1/' ;;
    cliente-b.ingest_user)     grep -A2 '^  cliente-b:' "${TENANTS_YML}" | grep ingest_user     | sed -E 's/.*: *"([^"]+)".*/\1/' ;;
    cliente-b.ingest_password) grep -A2 '^  cliente-b:' "${TENANTS_YML}" | grep ingest_password | sed -E 's/.*: *"([^"]+)".*/\1/' ;;
    *) echo "get_secret: clave desconocida: ${key}" >&2; exit 1 ;;
  esac
}

CENTRAL_FQDN="central-monitoring.lab"
CENTRAL_IP="172.28.100.10"

pass() { printf '  [OK]   %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; OVERALL_FAIL=1; }
info() { printf '  [--]   %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

OVERALL_FAIL=0

# vm_ssh <vm> <comando-remoto>   -> ejecuta el comando remoto vía "vagrant ssh"
vm_ssh() {
  local vm="$1" cmd="$2"
  vagrant ssh "${vm}" -c "${cmd}" 2>/dev/null
}

# central_curl <path-o-args-curl...>  -> curl ejecutado DENTRO de central-monitoring
# (para poder hablar en local con Mimir:9009 y Loki:3100, que no están
# publicados hacia fuera).
central_curl() {
  vm_ssh central-monitoring "curl -sS $*"
}

final_summary() {
  if [[ "${OVERALL_FAIL}" -eq 0 ]]; then
    printf '\nResultado: TODO CORRECTO.\n'
    exit 0
  else
    printf '\nResultado: HAY FALLOS. Revisa los [FAIL] anteriores.\n'
    exit 1
  fi
}
