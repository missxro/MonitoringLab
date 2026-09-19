#!/usr/bin/env bash
# Valida el requisito 6: cortar el forwarding de un gateway interrumpe
# SOLO la telemetría de ese cliente; el otro sigue funcionando.
#
# Ejecutado: sí. No usa "vagrant destroy" ni borra nada; solo apaga y
# vuelve a encender el forwarding IPv4 en cliente-a-gateway con sysctl
# (restaurado al final del script, y también por scripts/validate-07-*).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

last_sample_ts() {
  # último timestamp de muestra para up{job="node"} en el tenant $1
  central_curl "-H 'X-Scope-OrgID: $1' 'http://localhost:9009/prometheus/api/v1/query?query=up%7Bjob%3D%22node%22%7D'" \
    | grep -oE '\[[0-9]+\.[0-9]+,"1"\]' | head -1 | grep -oE '^\[[0-9]+' | tr -d '['
}

section "Cortando el forwarding de cliente-a-gateway (net.ipv4.ip_forward=0)"
vm_ssh cliente-a-gateway "sudo sysctl -w net.ipv4.ip_forward=0"
pass "Forwarding desactivado en cliente-a-gateway (temporalmente)"

t0_a=$(last_sample_ts cliente-a)
t0_b=$(last_sample_ts cliente-b)
echo "  Antes del corte -> cliente-a: ${t0_a}   cliente-b: ${t0_b}"

echo "  Esperando 40s (>2 ciclos de scrape) con el forwarding cortado..."
sleep 40

t1_a=$(last_sample_ts cliente-a)
t1_b=$(last_sample_ts cliente-b)
echo "  Tras el corte      -> cliente-a: ${t1_a}   cliente-b: ${t1_b}"

if [[ "${t1_a}" == "${t0_a}" ]]; then
  pass "cliente-a: la última muestra en Mimir no ha avanzado (su telemetría está cortada)"
else
  fail "cliente-a: la muestra ha avanzado igualmente; el corte no ha tenido efecto"
fi

if [[ -n "${t1_b}" && "${t1_b}" != "${t0_b}" ]]; then
  pass "cliente-b: la última muestra SÍ ha avanzado (no le afecta el corte del otro gateway)"
else
  fail "cliente-b: su telemetría también se ha detenido; el aislamiento entre clientes ha fallado"
fi

section "Restaurando el forwarding de cliente-a-gateway"
vm_ssh cliente-a-gateway "sudo sysctl -w net.ipv4.ip_forward=1"
pass "Forwarding restaurado. Ejecuta scripts/validate-07-recovery-buffers.sh para ver la recuperación."

final_summary
