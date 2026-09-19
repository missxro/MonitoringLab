# Monitoring Lab

Vagrant + VirtualBox + Ansible: 7 VMs, dos clientes con LAN internas
idénticas (`192.168.50.0/24`) y aisladas entre sí, monitorizados de forma
centralizada con Grafana Alloy → Mimir/Loki → Grafana.

## Arquitectura

| VM | IP de tránsito | IP de LAN | Función |
|---|---|---|---|
| `central-monitoring` | 172.28.100.10 | — | Proxy HTTPS, Mimir, Loki, Grafana (Docker Compose) |
| `cliente-a-gateway` | 172.28.100.11 | 192.168.50.1 en LAN A | Router/NAT de cliente A |
| `cliente-b-gateway` | 172.28.100.12 | 192.168.50.1 en LAN B | Router/NAT de cliente B |
| `cliente-a-vm1` | — | 192.168.50.21 en LAN A | Alloy, node_exporter, nginx |
| `cliente-a-vm2` | — | 192.168.50.22 en LAN A | Alloy, node_exporter |
| `cliente-b-vm1` | — | 192.168.50.21 en LAN B | Alloy, node_exporter, nginx |
| `cliente-b-vm2` | — | 192.168.50.22 en LAN B | Alloy, node_exporter |

LAN A y LAN B son dos redes `intnet` de VirtualBox distintas (`lab-lan-a`,
`lab-lan-b`): mismo CIDR, switches virtuales separados, sin nada que las
conecte entre sí ni con el host. `cliente-a-vm1` y `cliente-b-vm1`
comparten IP (192.168.50.21) y nunca se ven.


Direccionamiento, versiones y tamaño de cada VM viven en un único fichero,
[`config/lab.yml`](config/lab.yml), leído directamente por el
`Vagrantfile` y por Ansible.

## Decisiones de red

- **`intnet`, no `private_network` a secas.** Una hostonly normal se
  registra a nivel de host y no admite CIDR duplicado. `virtualbox__intnet`
  crea un switch puramente entre VMs, sin presencia en el host: por eso
  LAN A y LAN B pueden compartir CIDR sin chocar.
- **NIC1 (gestión de Vagrant).** Primer adaptador NAT que crea Vagrant
  siempre, antes de cualquier red del `Vagrantfile`. Solo se usa para
  SSH/Ansible/salida a Internet. Nada en el repo la referencia por nombre
  de interfaz: el firewall filtra por IP/subred
  ([`nftables.conf.j2`](ansible/roles/gateway/templates/nftables.conf.j2)),
  y la ruta a la central se instala sin `dev`
  (`ip route replace 172.28.100.10/32 via 192.168.50.1`; el kernel
  resuelve solo la interfaz de salida). Sin esa ruta, el tráfico a la
  central saldría por NIC1 y fallaría.
- **Cliente → central.** Cada gateway hace `ip_forward` + `masquerade`
  hacia el tránsito. Su nftables solo permite un flujo nuevo: `LAN →
  172.28.100.10:443`. Todo lo demás nuevo se descarta; lo ya establecido
  siempre vuelve.
- **Los dos gateways no se ven entre sí**, aunque comparten el segmento de
  tránsito con la central: cada uno se autorrestringe en su propio
  nftables a aceptar tráfico de tránsito solo desde `172.28.100.10`.
- **La central no tiene rutas a ninguna LAN** (a propósito), y el tráfico
  le llega ya con NAT aplicado: solo ve la IP del gateway, nunca la de un
  host de cliente.
- **Persistencia.** `ip_forward` vía `sysctl.d`, nftables vía
  `/etc/nftables.conf` + `nftables.service`, ruta del cliente vía
  `lab-route.service` (systemd oneshot). Todo sobrevive a un reinicio.

## Aislamiento por tenant (Mimir/Loki)

El proxy (nginx + TLS con CA propia) es la única puerta de entrada de los
clientes y solo expone dos rutas, ambas de escritura:
`/mimir/api/v1/push` y `/loki/api/v1/push`. Mimir y Loki no se publican
en ningún otro sitio.

- Cada cliente autentica con sus propias credenciales
  (`cliente-a-ingest` / `cliente-b-ingest`) contra un `htpasswd` que no
  tiene ninguna otra ruta ni credencial.
- `map $remote_user $tenant_id` en
  [`nginx.conf.j2`](ansible/roles/central/templates/nginx/nginx.conf.j2)
  traduce esa identidad al tenant real.
- `proxy_set_header X-Scope-OrgID $tenant_id` sobrescribe cualquier
  cabecera que mande el cliente. El tenant lo decide el proxy, no la
  petición — demostrado en
  [`validate-04-cross-tenant-block.sh`](scripts/validate-04-cross-tenant-block.sh).

Grafana no pasa por el proxy: habla con Mimir/Loki en directo por la red
interna de Docker Compose, con 4 datasources (2 backends × 2 tenants),
cada uno con su `X-Scope-OrgID` fijado en el servidor.

## Versiones (fijadas en `config/lab.yml`, nada en `latest`)

| Componente | Versión | Dónde |
|---|---|---|
| Box de Vagrant | `debian/bookworm64` (Debian 12) | las 7 VMs |
| Grafana Alloy | 1.19.2 | clientes, `.deb` de `apt.grafana.com` |
| node_exporter | 1.12.1 | clientes, binario de GitHub Releases |
| nginx (demo) | repo de Debian 12 | `cliente-*-vm1` |
| Grafana Mimir | 3.2.1 | central, imagen Docker |
| Grafana Loki | 3.7.8 | central, imagen Docker |
| Grafana | 13.2.2 (`grafana-oss`) | central, imagen Docker |
| nginx (proxy) | 1.31.6-alpine | central, imagen Docker |

## Recursos

~8GB total. Ajustable en `config/lab.yml` (sección `hosts`):

| VM | RAM | vCPU |
|---|---|---|
| central-monitoring | 3072 MB | 2 |
| cliente-a-gateway | 256 MB | 1 |
| cliente-b-gateway | 256 MB | 1 |
| cliente-a-vm1 | 768 MB | 1 |
| cliente-a-vm2 | 640 MB | 1 |
| cliente-b-vm1 | 768 MB | 1 |
| cliente-b-vm2 | 640 MB | 1 |
| **Total** | **6.25 GB** | **8** |

## Requisitos

- VirtualBox ≥ 7.0, Vagrant ≥ 2.4.
- Ansible ≥ 2.15 + Python 3 en el **host** (el provisioning corre ahí,
  no dentro de las VMs — ver siguiente sección).
- `openssl` y `bash` para los scripts de `scripts/`.

## Provisioning

Ansible corre desde el host (provisioner `ansible`, no `ansible_local`),
una sola vez tras crear la última VM (`ansible.limit = "all"`). El
inventario lo genera Vagrant a partir de `ansible.groups` en el
`Vagrantfile`: no hay un `.ini` a mano que mantener sincronizado. Todos
los roles son idempotentes.

## Arranque

```bash
# 1. Generar los secretos del laboratorio (CA, certificados, credenciales).
#    Solo la primera vez: idempotente, no hace nada si ya existen.
./scripts/generate-secrets.sh

# 2. Crear las 7 VMs y provisionarlas.
vagrant up
```

```bash
./scripts/run-all-validations.sh
```

## Acceso a Grafana

`http://localhost:3000` (Vagrant reenvía el puerto por la NIC de gestión,
nunca por la red de tránsito — sin HTTPS en este salto, es un túnel
local host↔VM).

Usuario `admin`, contraseña en `secrets/generated/tenants.yml`
(`grafana_admin_password`, nunca versionada).

Dashboard: **"Laboratorio · Vista general por cliente"**. Tiene dos
desplegables (datasource de métricas y de logs): selecciona el mismo
cliente en ambos.

## Reprovisionado

```bash
vagrant provision                 # todas las VMs
vagrant provision cliente-a-vm1    # solo una
```

Seguro de repetir: no regenera secretos ni toca datos persistentes; los
`handlers` de Ansible solo reinician lo que ha cambiado de verdad.

## Validación

| Script | Qué demuestra |
|---|---|
| `validate-01-lan-isolation.sh` | LAN A y LAN B separadas pese a compartir CIDR/IP |
| `validate-02-reachability.sh` | Cada cliente llega a la central por su gateway, TLS validado |
| `validate-03-tenant-ingest.sh` | Métricas y logs de las 4 VMs llegan al tenant correcto |
| `validate-04-cross-tenant-block.sh` | Credenciales de A + cabecera de B no escriben en B |
| `validate-05-load-and-dashboard.sh` | Carga de CPU y peticiones a nginx llegan a los datos de Grafana |
| `validate-06-gateway-outage.sh` | Cortar el forwarding de un gateway afecta solo a ese cliente |
| `validate-07-recovery-buffers.sh` | Qué se recupera al restaurar un gateway y qué límites tienen los buffers |
| `validate-08-reboot-persistence.sh` | Rutas y servicios sobreviven a un reinicio de las VMs |

`run-all-validations.sh` encadena 01-05 (no disruptivas). 06, 07 y 08 se
lanzan a mano: cortan tráfico real o reinician VMs a propósito (ninguno
usa `vagrant destroy` ni borra volúmenes).
