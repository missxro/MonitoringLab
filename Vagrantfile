# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Laboratorio de monitorización centralizada para dos clientes con LAN
# solapadas. Toda la topología (IPs, versiones, tamaño de VM) viene de
# config/lab.yml: este fichero solo interpreta esos datos y los traduce a
# máquinas y redes de VirtualBox. No se usa libvirt en ningún punto.
#
# Requisito de proveedor: VirtualBox >= 7.0 y Vagrant >= 2.4. Ningún plugin
# adicional es necesario (el synced folder por defecto se desactiva para no
# depender de VirtualBox Guest Additions).

require "yaml"

LAB = YAML.load_file(File.join(File.dirname(__FILE__), "config", "lab.yml"))["lab"]

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = LAB["versions"]["vagrant_box"]
  config.vm.box_check_update = false

  # Ninguna VM del laboratorio necesita compartir ficheros con el host.
  # Desactivarlo evita depender de Guest Additions para vboxsf y acelera el
  # arranque.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  hosts = LAB["hosts"]
  host_names = hosts.keys
  last_host = host_names.last

  host_names.each do |name|
    hcfg = hosts[name]

    config.vm.define name do |node|
      node.vm.hostname = name

      node.vm.provider "virtualbox" do |vb|
        vb.name = name
        vb.memory = hcfg["ram_mb"]
        vb.cpus = hcfg["cpus"]
        # Recursos mínimos: sin audio ni USB, no aportan nada a este laboratorio.
        vb.customize ["modifyvm", :id, "--audio", "none"]
        vb.customize ["modifyvm", :id, "--usb", "off"]
      end

      # -----------------------------------------------------------------
      # Redes de laboratorio. NIC1 (no declarada aquí) es la que Vagrant
      # crea siempre en primer lugar como adaptador NAT propio para poder
      # hacer "vagrant ssh" y ejecutar el provisioning: nunca se usa para
      # tráfico del laboratorio y nunca se referencia por nombre de
      # interfaz (ver README, sección "Decisiones de red").
      # -----------------------------------------------------------------
      case hcfg["role"]
      when "central"
        node.vm.network "private_network",
          ip: hcfg["transit_ip"],
          netmask: "255.255.255.0",
          virtualbox__intnet: LAB["network"]["transit"]["intnet"],
          auto_config: true

        # Acceso a Grafana para quien ejecuta el laboratorio, SOLO desde el
        # propio host: viaja por el adaptador NAT de Vagrant (NIC1), nunca
        # por la red de tránsito. Ninguna LAN de cliente tiene ruta hasta
        # aquí: Grafana es una consola de administración, no un portal de
        # clientes (ver README y docker-compose.yml.j2, que además solo
        # publica ese puerto en 127.0.0.1 dentro de la propia VM).
        node.vm.network "forwarded_port",
          guest: 3000,
          host: 3000,
          host_ip: "127.0.0.1",
          auto_correct: true

      when "gateway"
        node.vm.network "private_network",
          ip: hcfg["transit_ip"],
          netmask: "255.255.255.0",
          virtualbox__intnet: LAB["network"]["transit"]["intnet"],
          auto_config: true

        lan = LAB["network"][hcfg["lan"]]
        node.vm.network "private_network",
          ip: hcfg["lan_ip"],
          netmask: "255.255.255.0",
          virtualbox__intnet: lan["intnet"],
          auto_config: true

      when "client"
        lan = LAB["network"][hcfg["lan"]]
        node.vm.network "private_network",
          ip: hcfg["lan_ip"],
          netmask: "255.255.255.0",
          virtualbox__intnet: lan["intnet"],
          auto_config: true
      end

      # -----------------------------------------------------------------
      # Provisioning: una sola pasada de Ansible, ejecutada desde el HOST
      # tras crear la última VM. Ver README para las dependencias exactas
      # y por qué se ejecuta desde el host y no dentro de las VMs.
      # -----------------------------------------------------------------
      if name == last_host
        node.vm.provision "ansible" do |ansible|
          ansible.compatibility_mode = "2.0"
          ansible.playbook = "ansible/site.yml"
          ansible.limit = "all"

          ansible.groups = {
            "central"   => ["central-monitoring"],
            "gateways"  => ["cliente-a-gateway", "cliente-b-gateway"],
            "cliente_a" => ["cliente-a-vm1", "cliente-a-vm2"],
            "cliente_b" => ["cliente-b-vm1", "cliente-b-vm2"],
            "clientes:children" => ["cliente_a", "cliente_b"],
            "web_vm1"   => host_names.select { |n| hosts[n]["nginx_web"] },
          }
        end
      end
    end
  end
end
