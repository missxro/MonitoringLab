#!/usr/bin/env bash
# Valida el requisito 7: al restaurar un gateway, qué datos se recuperan
# y qué límites tienen los buffers. Corta y restaura el forwarding de
# cliente-a-gateway UNA sola vez, de forma autocontenida (no depende de
# haber ejecutado antes validate-06).
#
# Ejecutado: sí, para una interrupción CORTA (~45s), deliberadamente
# dentro de la capacidad de los buffers:
#   - Métricas: Alloy sigue raspando localhost:9100 en local durante el
#     corte (solo falla el ENVÍO); las muestras se acumulan en su WAL en
#     disco (/var/lib/alloy/data, ver wal.truncate_frequency=2h en
#     config.alloy.j2) y se drenan en orden al recuperar la red.
#   - Logs: journald y los ficheros de nginx conservan las líneas en su
#     propio almacenamiento (Alloy no las genera, solo las lee); el
#     componente loki.write las reintenta desde un buffer en memoria, más
#     pequeño y menos duradero que el WAL de métricas.
#
# NO ejecutado (solo documentado, ver README): qué pasa con una
# interrupción mucho más larga que esos buffers. Con un WAL de métricas
# de horas pero un buffer de logs en memoria de minutos, una caída larga
# pierde antes los logs generados durante la caída que las métricas. No
# hay recuperación ilimitada en ningún caso: ambos tienen techo.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUTAGE_SECONDS=45

section "Cortando el forwarding de cliente-a-gateway durante ${OUTAGE_SECONDS}s"
outage_start_ns=$(date +%s%N)
vm_ssh cliente-a-gateway "sudo sysctl -w net.ipv4.ip_forward=0"
sleep "${OUTAGE_SECONDS}"
outage_end_ns=$(date +%s%N)
vm_ssh cliente-a-gateway "sudo sysctl -w net.ipv4.ip_forward=1"
pass "Forwarding restaurado tras ${OUTAGE_SECONDS}s de corte"

echo "  Esperando 30s a que el WAL de Alloy drene lo acumulado..."
sleep 30

section "Métricas: ¿se han recuperado las muestras generadas durante el corte?"
now_ns=$(date +%s%N)
range=$(central_curl "-H 'X-Scope-OrgID: cliente-a' -G 'http://localhost:9009/prometheus/api/v1/query_range' \
  --data-urlencode 'query=up{job=\"node\",hostname=\"cliente-a-vm2\"}' \
  --data-urlencode \"start=$(( outage_start_ns / 1000000000 - 15 ))\" \
  --data-urlencode \"end=$(( now_ns / 1000000000 ))\" \
  --data-urlencode 'step=15'")
points=$(echo "${range}" | grep -oE '\[[0-9]+\.[0-9]+,"1"\]' | wc -l)
expected=$(( (outage_end_ns/1000000000 - outage_start_ns/1000000000 + 45) / 15 ))
echo "  Puntos recibidos en el rango del corte+margen: ${points} (esperados aprox.: ${expected})"
if (( points * 100 >= expected * 70 )); then
  pass "La mayoría de las muestras del corte han llegado (WAL drenado correctamente)"
else
  fail "Se han perdido más muestras de las esperadas para un corte de ${OUTAGE_SECONDS}s"
fi

section "Logs: ¿han llegado las entradas de journald generadas DURANTE el corte?"
logs=$(central_curl "-H 'X-Scope-OrgID: cliente-a' -G 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={job=\"journald\",hostname=\"cliente-a-vm2\"}' \
  --data-urlencode 'start=${outage_start_ns}' \
  --data-urlencode 'end=${outage_end_ns}'")
if echo "${logs}" | grep -q '"stream"'; then
  pass "Hay entradas de journald con marca de tiempo dentro de la ventana del corte"
else
  info "No se han encontrado líneas de journald específicamente en esa ventana (puede no haber habido actividad que registrar; no es necesariamente un fallo)"
fi

echo
echo "  Límites reales de estos buffers en este laboratorio (documentado, no forzado aquí):"
echo "    - WAL de métricas (Alloy): horas (wal.truncate_frequency=2h en config.alloy.j2)."
echo "    - Reintento de logs (Alloy -> Loki): minutos, en memoria, no en disco."
echo "    - Retención ya aceptada en Loki: 168h (limits_config.retention_period en loki.yaml.j2)."
echo "  Una caída más larga que el buffer de logs perdería logs de esa ventana ANTES de agotar el WAL de métricas."

final_summary
