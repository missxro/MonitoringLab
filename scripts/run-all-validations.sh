#!/usr/bin/env bash
# Ejecuta las validaciones NO disruptivas (1 a 5) en orden.
#
# Las validaciones 6, 7 y 8 se dejan fuera de este runner a propósito:
# cortan a propósito el forwarding de un gateway o reinician las 7 VMs.
# Son seguras (no usan "vagrant destroy" ni borran volúmenes) pero conviene
# lanzarlas de una en una y a sabiendas. Ejecútalas por separado:
#   scripts/validate-06-gateway-outage.sh
#   scripts/validate-07-recovery-buffers.sh
#   scripts/validate-08-reboot-persistence.sh   (tarda varios minutos)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

overall=0
for n in 01-lan-isolation 02-reachability 03-tenant-ingest 04-cross-tenant-block 05-load-and-dashboard; do
  script="${DIR}/validate-${n}.sh"
  echo
  echo "############################################################"
  echo "# ${script}"
  echo "############################################################"
  if ! "${script}"; then
    overall=1
  fi
done

echo
if [[ "${overall}" -eq 0 ]]; then
  echo "Todas las validaciones 1-5 han pasado."
else
  echo "Alguna validación ha fallado. Revisa la salida anterior."
fi
exit "${overall}"
