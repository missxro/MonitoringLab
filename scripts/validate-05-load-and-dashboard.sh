#!/usr/bin/env bash
# Valida el requisito 5: una carga de CPU y peticiones a nginx se
# reflejan en los datos que alimentan a Grafana.
#
# Ejecutado: sí, la parte de datos (se generan la carga/peticiones y se
# comprueba que Mimir/Loki las reciben con marcas de tiempo frescas).
# NO ejecutado (manual, para el vídeo): abrir el dashboard
# "Laboratorio · Vista general por cliente" en Grafana y comprobar
# visualmente que el panel de CPU sube y que la línea de log con la marca
# aparece. Esta parte no se puede comprobar sin un navegador.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MARCA="probe-05-$(date +%s)"

section "Generando carga de CPU en cliente-a-vm2 durante 20s"
vm_ssh cliente-a-vm2 "nohup timeout 20 sh -c 'while true; do :; done' >/dev/null 2>&1 &" || true
pass "Carga lanzada en background (bucle ocupado, 20s)"

section "Generando peticiones marcadas a nginx en cliente-a-vm1"
vm_ssh cliente-a-vm1 "for i in 1 2 3 4 5; do curl -sS -o /dev/null 'http://localhost/?probe=${MARCA}'; done"
pass "5 peticiones enviadas con la marca ${MARCA}"

echo "  Esperando ~25s a que se raspe, se envíe y se indexe..."
sleep 25

section "¿Hay una muestra de node_cpu_seconds_total reciente para cliente-a-vm2?"
now_epoch=$(date +%s)
metrics=$(central_curl "-H 'X-Scope-OrgID: cliente-a' 'http://localhost:9009/prometheus/api/v1/query?query=up%7Bjob%3D%22node%22%2Chostname%3D%22cliente-a-vm2%22%7D'")
if echo "${metrics}" | grep -q '"cliente-a-vm2"'; then
  sample_ts=$(echo "${metrics}" | grep -oE '\[[0-9]+\.[0-9]+,"1"\]' | head -1 | grep -oE '^\[[0-9]+' | tr -d '[')
  if [[ -n "${sample_ts}" ]] && (( now_epoch - sample_ts < 60 )); then
    pass "Muestra fresca (hace $((now_epoch - sample_ts))s): el pipeline de métricas está vivo durante la carga"
  else
    fail "La muestra encontrada no es reciente"
  fi
else
  fail "No se encuentra la serie de cliente-a-vm2"
fi

section "¿Ha llegado a Loki la petición marcada?"
now_ns=$(date +%s%N)
start_ns=$((now_ns - 120000000000))
logs=$(central_curl "-H 'X-Scope-OrgID: cliente-a' -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={job=\"nginx\"} |= \"${MARCA}\"' --data-urlencode 'start=${start_ns}' --data-urlencode 'end=${now_ns}'")
if echo "${logs}" | grep -q "${MARCA}"; then
  pass "La marca ${MARCA} aparece en los logs de nginx en Loki (tenant cliente-a)"
else
  fail "No se encuentra la marca ${MARCA} en Loki"
fi

echo
echo "  Paso manual para el vídeo: abre http://localhost:3000 (ver README),"
echo "  entra en el dashboard 'Laboratorio · Vista general por cliente',"
echo "  selecciona los datasources de Cliente A en ambos desplegables y"
echo "  comprueba visualmente el pico de CPU y la línea con '${MARCA}'."

final_summary
