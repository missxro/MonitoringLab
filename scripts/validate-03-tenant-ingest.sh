#!/usr/bin/env bash
# Valida el requisito 3: llegan métricas y logs de las 4 VMs al tenant
# correcto. Se consulta Mimir y Loki EN LOCAL desde central-monitoring
# (sus puertos no están publicados hacia fuera: solo son accesibles ahí),
# con el X-Scope-OrgID correspondiente a cada tenant, y se comprueba que
# aparecen exactamente los dos hosts esperados de cada cliente.
#
# Ejecutado: sí.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

check_tenant() {
  local tenant="$1" host1="$2" host2="$3"

  section "Métricas de ${tenant} en Mimir (up{job=\"node\"})"
  local metrics
  metrics=$(central_curl "-H 'X-Scope-OrgID: ${tenant}' 'http://localhost:9009/prometheus/api/v1/query?query=up%7Bjob%3D%22node%22%7D'")
  echo "  ${metrics}" | head -c 400; echo
  for h in "${host1}" "${host2}"; do
    if echo "${metrics}" | grep -q "\"${h}\""; then
      pass "${tenant}: aparece ${h}"
    else
      fail "${tenant}: NO aparece ${h}"
    fi
  done
  for other_host in cliente-a-vm1 cliente-a-vm2 cliente-b-vm1 cliente-b-vm2; do
    if [[ "${other_host}" != "${host1}" && "${other_host}" != "${host2}" ]]; then
      if echo "${metrics}" | grep -q "\"${other_host}\""; then
        fail "${tenant}: aparece ${other_host}, que NO es suyo (fuga entre tenants)"
      fi
    fi
  done

  section "Logs de ${tenant} en Loki (journald, últimos 5 minutos)"
  local now_ns start_ns logs
  now_ns=$(date +%s%N)
  start_ns=$((now_ns - 300000000000))
  logs=$(central_curl "-H 'X-Scope-OrgID: ${tenant}' -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={job=\"journald\"}' --data-urlencode 'start=${start_ns}' --data-urlencode 'end=${now_ns}' --data-urlencode 'limit=5'")
  if echo "${logs}" | grep -q '"status":"success"' && echo "${logs}" | grep -q '"stream"'; then
    pass "${tenant}: hay entradas de journald recientes en Loki"
  else
    fail "${tenant}: no se han encontrado logs recientes en Loki"
  fi
}

check_tenant "cliente-a" "cliente-a-vm1" "cliente-a-vm2"
check_tenant "cliente-b" "cliente-b-vm1" "cliente-b-vm2"

final_summary
