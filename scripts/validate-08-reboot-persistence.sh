#!/usr/bin/env bash
# Valida el requisito 8: rutas y servicios funcionan tras reiniciar las
# VMs. Reinicia las 7 VMs (vagrant reload, SIN --provision: lo que debe
# sobrevivir es lo que ya se aplicó, no una nueva pasada de Ansible) y
# repite las comprobaciones de conectividad e ingesta.
#
# Ejecutado: sí. No usa "vagrant destroy" ni borra volúmenes: "vagrant
# reload" solo reinicia la VM (equivalente a un apagado/encendido).
# Tarda varios minutos (7 VMs).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Reiniciando las 7 VMs (vagrant reload, sin reprovisionar)"
for vm in central-monitoring cliente-a-gateway cliente-b-gateway cliente-a-vm1 cliente-a-vm2 cliente-b-vm1 cliente-b-vm2; do
  echo "  Reiniciando ${vm}..."
  vagrant reload "${vm}" >/dev/null
done
pass "Las 7 VMs se han reiniciado"

echo "  Esperando 30s a que los servicios (Docker Compose, Alloy, nginx) terminen de arrancar..."
sleep 30

section "nftables y forwarding persistieron en los gateways"
for gw in cliente-a-gateway cliente-b-gateway; do
  fwd=$(vm_ssh "${gw}" "cat /proc/sys/net/ipv4/ip_forward")
  rules=$(vm_ssh "${gw}" "sudo nft list ruleset | grep -c 'ct state established,related accept' || true")
  if [[ "${fwd}" == "1" ]]; then pass "${gw}: ip_forward=1 tras reiniciar"; else fail "${gw}: ip_forward no persistió"; fi
  if [[ "${rules}" -ge 1 ]]; then pass "${gw}: el ruleset de nftables se recargó"; else fail "${gw}: nftables no recargó su ruleset"; fi
done

section "La ruta explícita hacia la central persistió en los clientes"
for vm in cliente-a-vm1 cliente-a-vm2 cliente-b-vm1 cliente-b-vm2; do
  route=$(vm_ssh "${vm}" "ip route get ${CENTRAL_IP}" || true)
  if echo "${route}" | grep -q "via 192.168.50.1"; then
    pass "${vm}: ruta hacia ${CENTRAL_IP} presente tras reiniciar"
  else
    fail "${vm}: la ruta hacia la central no persistió"
  fi
done

section "docker compose (central) volvió a estar operativo"
ps=$(vm_ssh central-monitoring "cd /opt/monitoring && sudo docker compose ps --format '{{.Name}}: {{.Status}}'" || true)
echo "${ps}" | sed 's/^/  /'
if echo "${ps}" | grep -q "Up"; then
  pass "Los contenedores de la central están arriba tras reiniciar"
else
  fail "Los contenedores de la central no se han recuperado"
fi

section "Vuelve a comprobarse la ingesta de extremo a extremo (reutiliza validate-03)"
"$(dirname "${BASH_SOURCE[0]}")/validate-03-tenant-ingest.sh" || OVERALL_FAIL=1

final_summary
