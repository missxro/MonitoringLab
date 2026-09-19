#!/usr/bin/env bash
# Valida el requisito 2: cada VM de cliente alcanza la central a través de
# su propio gateway, con TLS validado de verdad contra la CA del
# laboratorio (sin -k / insecure_skip_verify).
#
# Ejecutado: sí, contra /healthz (sin credenciales, solo prueba
# conectividad+TLS).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "https://${CENTRAL_FQDN}/healthz desde las 4 VMs de cliente (TLS validado con la CA instalada)"

for vm in cliente-a-vm1 cliente-a-vm2 cliente-b-vm1 cliente-b-vm2; do
  resp=$(vm_ssh "${vm}" "curl -sS --fail https://${CENTRAL_FQDN}/healthz" || echo "CURL_ERROR")
  if [[ "${resp}" == "ok" ]]; then
    pass "${vm} -> central: TLS válido y proxy responde"
  else
    fail "${vm} -> central: sin respuesta válida (obtenido: '${resp}')"
  fi
done

section "Confirmación de la ruta explícita usada (no vía el adaptador NAT de Vagrant)"
for vm in cliente-a-vm1 cliente-a-vm2 cliente-b-vm1 cliente-b-vm2; do
  route=$(vm_ssh "${vm}" "ip route get ${CENTRAL_IP}" || true)
  echo "  ${vm}: ${route}"
  if echo "${route}" | grep -q "via 192.168.50.1"; then
    pass "${vm} llega a ${CENTRAL_IP} vía su gateway de LAN (192.168.50.1)"
  else
    fail "${vm} NO está usando la ruta explícita esperada"
  fi
done

final_summary
