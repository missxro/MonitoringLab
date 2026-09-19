#!/usr/bin/env bash
# Genera, UNA sola vez, todos los secretos del laboratorio:
#   - CA propia del laboratorio + certificado de servidor para la central
#     (con SAN válido para su IP de tránsito y su nombre).
#   - Credenciales de ingesta y de consulta por cliente, y credenciales de
#     administración de Grafana.
#   - Ficheros htpasswd para nginx a partir de esas credenciales.
#
# Idempotente: si secrets/generated/tenants.yml ya existe, no hace nada
# (evita invalidar credenciales/certificados ya usados por VMs provisionadas).
# Usa --force para regenerar explícitamente todo desde cero.
#
# Nada de lo que este script escribe se versiona: todo cae bajo secrets/,
# que está en .gitignore.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_YML="${ROOT_DIR}/config/lab.yml"
SECRETS_DIR="${ROOT_DIR}/secrets"
PKI_DIR="${SECRETS_DIR}/pki"
NGINX_DIR="${SECRETS_DIR}/nginx"
GENERATED_DIR="${SECRETS_DIR}/generated"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

if [[ -f "${GENERATED_DIR}/tenants.yml" && "${FORCE}" -eq 0 ]]; then
  echo "Los secretos ya existen en ${SECRETS_DIR} (usa --force para regenerarlos)."
  echo "No se ha modificado nada."
  exit 0
fi

command -v openssl >/dev/null || { echo "Falta openssl" >&2; exit 1; }

mkdir -p "${PKI_DIR}" "${NGINX_DIR}" "${GENERATED_DIR}"
chmod 700 "${SECRETS_DIR}" "${PKI_DIR}" "${NGINX_DIR}" "${GENERATED_DIR}"

# --- Leer los dos únicos valores que necesitamos de config/lab.yml --------
# (config/lab.yml es simple y fijo a propósito: no hace falta un parser YAML
# completo ni dependencias extra en el host solo para este script).
CENTRAL_IP=$(grep 'central_transit_ip:' "${LAB_YML}" | head -1 | sed -E 's/.*: *"?([0-9.]+)"?.*/\1/')
CENTRAL_FQDN=$(grep 'central_fqdn:' "${LAB_YML}" | head -1 | sed -E 's/.*: *"([^"]+)".*/\1/')
mapfile -t TENANTS < <(grep -E '^\s+- cliente-' "${LAB_YML}" | sed -E 's/^\s+- //')

if [[ -z "${CENTRAL_IP}" || -z "${CENTRAL_FQDN}" || "${#TENANTS[@]}" -eq 0 ]]; then
  echo "No se ha podido leer central_transit_ip / central_fqdn / tenants desde ${LAB_YML}" >&2
  exit 1
fi

echo "Central: ${CENTRAL_FQDN} (${CENTRAL_IP})"
echo "Tenants: ${TENANTS[*]}"

rand_password() {
  # 20 caracteres alfanuméricos: seguros para basic-auth, YAML y shell sin escapado.
  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-20
}

htpasswd_line() {
  local user="$1" pass="$2" salt
  salt=$(openssl rand -hex 4)
  local hash
  hash=$(openssl passwd -apr1 -salt "${salt}" "${pass}")
  echo "${user}:${hash}"
}

# --- 1. CA del laboratorio --------------------------------------------------
echo "Generando CA del laboratorio..."
openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
  -keyout "${PKI_DIR}/ca.key" -out "${PKI_DIR}/ca.crt" \
  -subj "/O=lab-monitoring/CN=Lab Monitoring CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  >/dev/null 2>&1

# --- 2. Certificado de servidor para la central, firmado por esa CA --------
echo "Generando certificado de servidor para ${CENTRAL_FQDN} / ${CENTRAL_IP}..."
openssl req -newkey rsa:2048 -nodes \
  -keyout "${PKI_DIR}/server.key" -out "${PKI_DIR}/server.csr" \
  -subj "/O=lab-monitoring/CN=${CENTRAL_FQDN}" >/dev/null 2>&1

cat > "${PKI_DIR}/server.ext" <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${CENTRAL_FQDN},IP:${CENTRAL_IP}
EOF

openssl x509 -req -in "${PKI_DIR}/server.csr" \
  -CA "${PKI_DIR}/ca.crt" -CAkey "${PKI_DIR}/ca.key" -CAcreateserial \
  -out "${PKI_DIR}/server.crt" -days 825 -sha256 \
  -extfile "${PKI_DIR}/server.ext" >/dev/null 2>&1

rm -f "${PKI_DIR}/server.csr" "${PKI_DIR}/server.ext"
chmod 600 "${PKI_DIR}/ca.key" "${PKI_DIR}/server.key"

# --- 3. Credenciales de ingesta por tenant + htpasswd -----------------------
# Solo hacen falta credenciales de INGESTA: son las que usa Alloy en los
# clientes contra el proxy. Grafana, en cambio, habla con Mimir/Loki en
# directo por la red interna de Docker Compose (nunca a través del proxy,
# no es un cliente) e identifica el tenant con la cabecera X-Scope-OrgID;
# no necesita ninguna contraseña para ello. Ver README, sección "Grafana
# y aislamiento por tenant".
echo "Generando credenciales de ingesta por tenant..."
: > "${NGINX_DIR}/htpasswd-ingest"

{
  echo "tenant_secrets:"
  for tenant in "${TENANTS[@]}"; do
    ingest_user="${tenant}-ingest"
    ingest_pass=$(rand_password)

    htpasswd_line "${ingest_user}" "${ingest_pass}" >> "${NGINX_DIR}/htpasswd-ingest"

    echo "  ${tenant}:"
    echo "    ingest_user: \"${ingest_user}\""
    echo "    ingest_password: \"${ingest_pass}\""
  done
  grafana_admin_pass=$(rand_password)
  echo "grafana_admin_user: \"admin\""
  echo "grafana_admin_password: \"${grafana_admin_pass}\""
} > "${GENERATED_DIR}/tenants.yml"

chmod 600 "${NGINX_DIR}/htpasswd-ingest" "${GENERATED_DIR}/tenants.yml"

cat > "${SECRETS_DIR}/README.txt" <<EOF
Secretos generados el $(date -u +%Y-%m-%dT%H:%M:%SZ).
No versionar este directorio (ya está en .gitignore).

- pki/ca.crt        -> CA del laboratorio. Se instala en los 4 clientes.
- pki/ca.key        -> clave privada de la CA. Nunca sale del host.
- pki/server.crt/.key -> certificado TLS de central-monitoring (SAN: ${CENTRAL_FQDN}, ${CENTRAL_IP}).
- nginx/htpasswd-ingest -> credenciales de ingesta para el proxy (una por cliente).
- generated/tenants.yml -> mismas credenciales en claro, en YAML, para que
  Ansible configure Alloy y los datasources de Grafana con ellas.

Para regenerar todo (invalida VMs ya provisionadas): $0 --force
EOF

echo "Listo. Secretos en ${SECRETS_DIR} (fuera del control de versiones)."
