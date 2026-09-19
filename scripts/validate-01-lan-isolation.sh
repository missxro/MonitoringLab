#!/usr/bin/env bash
# Valida el requisito 1: LAN A y LAN B están separadas pese a compartir
# CIDR (192.168.50.0/24) e IPs (cliente-a-vm1 y cliente-b-vm1 son AMBAS
# 192.168.50.21, en switches virtuales distintos).
#
# Ejecutado: sí. Método: cada VM1 sirve una página que contiene su propio
# nombre de host. Se pide esa misma IP (.21) desde dentro de cada LAN y se
# comprueba que la respuesta identifica siempre a la VM1 DE ESA LAN, nunca
# a la del otro cliente, aunque la IP pedida sea idéntica.
# Revisado estáticamente (no ejecutado): el tipo de adaptador de red que
# VirtualBox usó para cada NIC, vía VBoxManage, para confirmar que son
# redes "intnet" (sin presencia en el host) y no "hostonly" compartidas.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Mismo IP (192.168.50.21), contenido distinto según la LAN de origen"

resp_a=$(vm_ssh cliente-a-vm2 "curl -sS http://192.168.50.21/" || true)
resp_b=$(vm_ssh cliente-b-vm2 "curl -sS http://192.168.50.21/" || true)

if echo "${resp_a}" | grep -q "cliente-a-vm1"; then
  pass "Desde cliente-a-vm2, 192.168.50.21 responde como cliente-a-vm1"
else
  fail "Desde cliente-a-vm2, 192.168.50.21 NO respondió como cliente-a-vm1"
fi

if echo "${resp_b}" | grep -q "cliente-b-vm1"; then
  pass "Desde cliente-b-vm2, 192.168.50.21 responde como cliente-b-vm1"
else
  fail "Desde cliente-b-vm2, 192.168.50.21 NO respondió como cliente-b-vm1"
fi

if echo "${resp_a}" | grep -q "cliente-b-vm1"; then
  fail "cliente-a-vm2 ha visto contenido de cliente-b-vm1: las LAN NO están aisladas"
fi
if echo "${resp_b}" | grep -q "cliente-a-vm1"; then
  fail "cliente-b-vm2 ha visto contenido de cliente-a-vm1: las LAN NO están aisladas"
fi

section "Tipo de adaptador de red en VirtualBox (revisión estática, no dinámica)"
for vm in cliente-a-gateway cliente-a-vm1 cliente-a-vm2 cliente-b-gateway cliente-b-vm1 cliente-b-vm2; do
  info "${vm}:"
  VBoxManage showvminfo "${vm}" --machinereadable 2>/dev/null \
    | grep -E '^nic[0-9]+=|^intnet[0-9]+=' || true
done
info "Se espera intnetN=\"lab-lan-a\" en las VMs de cliente-a y intnetN=\"lab-lan-b\" en las de cliente-b: son switches virtuales distintos, sin adaptador hostonly compartido y sin presencia en el host."

final_summary
