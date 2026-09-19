#!/usr/bin/env bash
# Valida el requisito 4: credenciales de cliente-a con una cabecera que
# pide cliente-b no permiten escribir en cliente-b.
#
# Se usa la API de push de Loki (JSON simple) como mecanismo concreto: el
# proxy aplica la MISMA lógica (mapa usuario->tenant + proxy_set_header
# X-Scope-OrgID, ver nginx.conf.j2) a la ruta de Loki y a la de Mimir, así
# que demostrarlo aquí es representativo de ambas.
#
# Ejecutado: sí, de principio a fin (push + las dos consultas que prueban
# dónde aterrizó realmente la línea).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USER_A=$(get_secret cliente-a.ingest_user)
PASS_A=$(get_secret cliente-a.ingest_password)

MARCA="validacion-04-$(date +%s)"
TS_NS=$(date +%s%N)

section "Push a Loki con credenciales de cliente-a y X-Scope-OrgID: cliente-b (suplantación)"
http_code=$(vm_ssh cliente-a-vm1 "curl -sS -o /dev/null -w '%{http_code}' \
  -u '${USER_A}:${PASS_A}' \
  -H 'X-Scope-OrgID: cliente-b' \
  -H 'Content-Type: application/json' \
  --data '{\"streams\":[{\"stream\":{\"job\":\"${MARCA}\"},\"values\":[[\"${TS_NS}\",\"intento de escritura en cliente-b usando credenciales de cliente-a\"]]}]}' \
  https://${CENTRAL_FQDN}/loki/api/v1/push")

echo "  Código HTTP del push: ${http_code}"
if [[ "${http_code}" == "204" ]]; then
  pass "El proxy aceptó el push (credenciales válidas de cliente-a)"
else
  fail "El proxy no aceptó el push (código ${http_code}); no se puede continuar esta prueba"
fi

sleep 3

section "¿Aterrizó en cliente-b? (debería ser que NO)"
in_b=$(central_curl "-H 'X-Scope-OrgID: cliente-b' -G 'http://localhost:3100/loki/api/v1/query' --data-urlencode 'query={job=\"${MARCA}\"}'")
if echo "${in_b}" | grep -q '"stream"'; then
  fail "La línea aterrizó en cliente-b: la suplantación de tenant NO se ha bloqueado"
else
  pass "cliente-b no tiene esa línea: la cabecera enviada por el cliente se ignoró"
fi

section "¿Aterrizó en cliente-a, su tenant real según las credenciales? (debería ser que SÍ)"
in_a=$(central_curl "-H 'X-Scope-OrgID: cliente-a' -G 'http://localhost:3100/loki/api/v1/query' --data-urlencode 'query={job=\"${MARCA}\"}'")
if echo "${in_a}" | grep -q '"stream"'; then
  pass "La línea aterrizó en cliente-a: el proxy asignó el tenant por identidad autenticada, no por cabecera"
else
  fail "La línea no aparece ni en cliente-a: revisa el mapa \$tenant_id en nginx.conf"
fi

final_summary
