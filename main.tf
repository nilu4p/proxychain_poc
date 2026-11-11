terraform {
  required_version = ">= 1.4"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

variable "vm_names" {
  description = "Noms des VM à déployer (l'ordre détermine les adresses IP)"
  type        = list(string)
  default     = ["c2", "exit_node", "middle_node", "entry_node", "router", "client"]
}

variable "cpus" {
  description = "Nombre de vCPU par VM"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "Mémoire par VM, en Mo"
  type        = number
  default     = 2048
}

variable "disk_size_gb" {
  description = "Taille du disque de chaque VM, en Go"
  type        = number
  default     = 20
}

variable "libvirt_uri" {
  description = "Connexion libvirt"
  type        = string
  default     = "qemu:///system"
}

variable "storage_pool" {
  description = "Pool de stockage libvirt"
  type        = string
  default     = "default"
}

variable "nat_network_name" {
  type    = string
  default = "poc_nat"
}

variable "nat_cidr" {
  type    = string
  default = "10.10.20.0/24"
}

variable "private_network_name" {
  type    = string
  default = "private_net"
}

variable "private_cidr" {
  type    = string
  default = "10.10.10.0/24"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

locals {
  work_dir       = abspath(path.module)
  image_path     = "${local.work_dir}/${basename(var.image_url)}"
  base_volume    = "poc-base-${basename(var.image_url)}"
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  private_key    = trimsuffix(pathexpand(var.ssh_public_key_path), ".pub")
  ansible_dir    = "${local.work_dir}/ansible"
  lock_file      = "${local.work_dir}/.deploy.lock"

  nat_gateway = cidrhost(var.nat_cidr, 1)
  seed_dir    = "${local.work_dir}/seed"

  vms = {
    for i, name in var.vm_names : name => {
      nat_ip     = cidrhost(var.nat_cidr, 11 + i)
      private_ip = cidrhost(var.private_cidr, 11 + i)

      mac_nat     = format("52:54:00:aa:00:%02x", i + 1)
      mac_private = format("52:54:00:bb:00:%02x", i + 1)

      # Nettoyage automatique des clés vides pour le user_data
      user_data = "#cloud-config\n${yamlencode(merge(
        {
          hostname   = replace(name, "_", "-")
          ssh_pwauth = false
          users = [{
            name                = "ubuntu"
            shell               = "/bin/bash"
            sudo                = "ALL=(ALL) NOPASSWD:ALL"
            ssh_authorized_keys = [local.ssh_public_key]
          }]
        },
        name == "client" ? {
          write_files = [
            {
              path        = "/var/lib/cloud/scripts/per-boot/apt-update.sh"
              permissions = "0755"
              content     = "#!/bin/sh\nexit 0\n"
            }
          ]
        } : {}
      ))}"

      # La solution ultime pour contourner le typage Terraform sans crasher Netplan
      network_config = yamlencode({
        version = 2
        ethernets = merge(
          name != "client" ? {
            public = {
              match = { macaddress = format("52:54:00:aa:00:%02x", i + 1) }
              dhcp4 = true
            }
          } : {},
          contains(["router", "client"], name) ? {
            private = merge(
              {
                match       = { macaddress = format("52:54:00:bb:00:%02x", i + 1) }
                dhcp4       = false
                addresses   = ["${cidrhost(var.private_cidr, 11 + i)}/${split("/", var.private_cidr)[1]}"]
              },
              # Ce filtre supprime dynamiquement les clés si elles valent 'null'
              {
                for k, v in {
                  routes      = name == "client" ? [{ to = "default", via = cidrhost(var.private_cidr, 15) }] : null
                  nameservers = name == "client" ? { addresses = ["1.1.1.1", "8.8.8.8"] } : null
                } : k => v if v != null
              }
            )
          } : {}
        )
      })

      meta_data = yamlencode({
        instance-id    = name
        local-hostname = replace(name, "_", "-")
      })
    }
  }
}

resource "terraform_data" "networks" {
  triggers_replace = [
    var.libvirt_uri,
    var.nat_network_name,
    var.nat_cidr,
    var.private_network_name,
    var.private_cidr,
    "v8_clean_yaml_serialization"
  ]

  input = {
    uri         = var.libvirt_uri
    nat_net     = var.nat_network_name
    private_net = var.private_network_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      LIBVIRT_DEFAULT_URI = var.libvirt_uri
      
      NAT_NET             = var.nat_network_name
      NAT_GW              = local.nat_gateway
      NAT_MASK            = cidrnetmask(var.nat_cidr)
      DHCP_START          = cidrhost(var.nat_cidr, 100)
      DHCP_END            = cidrhost(var.nat_cidr, 200)
      
      PRIVATE_NET         = var.private_network_name
      PRIVATE_GW          = cidrhost(var.private_cidr, 1)
      PRIVATE_MASK        = cidrnetmask(var.private_cidr)
      PRIVATE_DHCP_START  = cidrhost(var.private_cidr, 100)
      PRIVATE_DHCP_END    = cidrhost(var.private_cidr, 200)
    }

    command = <<-EOT
      set -euo pipefail

      if ! command -v virsh >/dev/null; then
        echo "Outil manquant sur l'hôte : virsh" >&2
        exit 127
      fi

      TMP=$(mktemp -d)
      trap 'rm -rf "$TMP"' EXIT

      ensure_net() {
        name=$1
        xml=$2
        if ! virsh net-info "$name" >/dev/null 2>&1; then
          printf '%s\n' "$xml" > "$TMP/$name.xml"
          virsh net-define "$TMP/$name.xml"
        fi
        virsh net-autostart "$name"
        if ! virsh net-info "$name" | grep -Eq '^Active:\s+yes'; then
          virsh net-start "$name"
        fi
      }

      ensure_net "$NAT_NET" "<network>
        <name>$NAT_NET</name>
        <forward mode='nat'/>
        <bridge stp='on' delay='0'/>
        <ip address='$NAT_GW' netmask='$NAT_MASK'>
          <dhcp><range start='$DHCP_START' end='$DHCP_END'/></dhcp>
        </ip>
      </network>"

      ensure_net "$PRIVATE_NET" "<network>
        <name>$PRIVATE_NET</name>
        <bridge stp='on' delay='0'/>
        <ip address='$PRIVATE_GW' netmask='$PRIVATE_MASK'>
          <dhcp><range start='$PRIVATE_DHCP_START' end='$PRIVATE_DHCP_END'/></dhcp>
        </ip>
      </network>"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]

    environment = {
      LIBVIRT_DEFAULT_URI = self.input.uri
      NAT_NET             = self.input.nat_net
      PRIVATE_NET         = self.input.private_net
    }

    command = <<-EOT
      set -uo pipefail
      for name in "$NAT_NET" "$PRIVATE_NET"; do
        if virsh net-info "$name" >/dev/null 2>&1; then
          virsh net-destroy "$name" 2>/dev/null || true
          virsh net-undefine "$name"
        fi
      done
    EOT
  }
}

resource "terraform_data" "vm" {
  for_each = local.vms

  triggers_replace = [
    each.key,
    var.cpus,
    var.memory_mb,
    var.disk_size_gb,
    var.image_url,
    var.storage_pool,
    each.value.nat_ip,
    sha256(each.value.user_data),
    sha256(each.value.network_config),
    sha256(each.value.meta_data),
    terraform_data.networks.id,
  ]

  input = {
    vm_name  = each.key
    uri      = var.libvirt_uri
    nat_net  = var.nat_network_name
    mac_nat  = each.value.mac_nat
    seed_dir = local.seed_dir
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      LIBVIRT_DEFAULT_URI = var.libvirt_uri

      VM        = each.key
      VM_HOST   = replace(each.key, "_", "-")
      CPUS      = var.cpus
      MEMORY    = var.memory_mb
      DISK_GB   = var.disk_size_gb
      POOL      = var.storage_pool
      IMAGE_URL = var.image_url
      IMAGE     = local.image_path
      BASE_VOL  = local.base_volume
      LOCK      = local.lock_file
      USER_DATA = each.value.user_data
      NET_CONF  = each.value.network_config
      META_DATA = each.value.meta_data

      NAT_NET     = var.nat_network_name
      NAT_GW      = local.nat_gateway
      NAT_IP      = each.value.nat_ip
      
      PRIVATE_NET = var.private_network_name
      MAC_NAT     = each.value.mac_nat
      MAC_PRIVATE = each.value.mac_private

      SEED_DIR  = local.seed_dir
    }

    command = <<-EOT
      set -euo pipefail

      for tool in virsh virt-install qemu-img curl flock genisoimage; do
        if ! command -v "$tool" >/dev/null; then
          echo "Outil manquant sur l'hôte : $tool" >&2
          exit 127
        fi
      done

      CREATED=0
      DHCP_HOST="<host mac='$MAC_NAT' name='$VM_HOST' ip='$NAT_IP'/>"

      on_exit() {
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$CREATED" -eq 1 ]; then
          virsh destroy "$VM" 2>/dev/null || true
          virsh undefine "$VM" --remove-all-storage 2>/dev/null || true
          virsh vol-delete --pool "$POOL" "$VM.qcow2" 2>/dev/null || true
          virsh vol-delete --pool "$POOL" "$VM-cidata.iso" 2>/dev/null || true
          if [ "$VM" != "client" ]; then
            virsh net-update "$NAT_NET" delete ip-dhcp-host "$DHCP_HOST" --live --config 2>/dev/null || true
          fi
          rm -rf "$SEED_DIR/$VM"
        fi
        exit "$rc"
      }
      trap on_exit EXIT

      exec 9>"$LOCK"
      flock 9

      if virsh dominfo "$VM" >/dev/null 2>&1; then
        exit 1
      fi

      if [ ! -f "$IMAGE" ]; then
        curl -fL -o "$IMAGE.tmp" "$IMAGE_URL"
        mv "$IMAGE.tmp" "$IMAGE"
      fi
      if ! virsh vol-info --pool "$POOL" "$BASE_VOL" >/dev/null 2>&1; then
        VSIZE=$(qemu-img info --output=json "$IMAGE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')
        virsh vol-create-as "$POOL" "$BASE_VOL" "$VSIZE" --format qcow2
        virsh vol-upload --pool "$POOL" "$BASE_VOL" "$IMAGE"
        virsh pool-refresh "$POOL" >/dev/null
      fi

      CREATED=1

      virsh vol-delete --pool "$POOL" "$VM.qcow2" >/dev/null 2>&1 || true
      virsh vol-create-as "$POOL" "$VM.qcow2" "$DISK_GB"G --format qcow2 \
        --backing-vol "$BASE_VOL" --backing-vol-format qcow2

      if [ "$VM" != "client" ]; then
        virsh net-update "$NAT_NET" delete ip-dhcp-host "$DHCP_HOST" --live --config >/dev/null 2>&1 || true
        virsh net-update "$NAT_NET" add ip-dhcp-host "$DHCP_HOST" --live --config
      fi

      mkdir -p "$SEED_DIR/$VM"
      printf '%s' "$USER_DATA" > "$SEED_DIR/$VM/user-data"
      printf '%s' "$META_DATA" > "$SEED_DIR/$VM/meta-data"
      printf '%s' "$NET_CONF"  > "$SEED_DIR/$VM/network-config"
      : > "$SEED_DIR/$VM/vendor-data"

      # Injection de la configuration propre via ISO Cloud-Init
      genisoimage -output "$SEED_DIR/$VM/cidata.iso" -volid cidata -joliet -rock "$SEED_DIR/$VM/user-data" "$SEED_DIR/$VM/meta-data" "$SEED_DIR/$VM/vendor-data" "$SEED_DIR/$VM/network-config" 2>/dev/null
      
      ISO_SIZE=$(stat -c%s "$SEED_DIR/$VM/cidata.iso")
      virsh vol-delete --pool "$POOL" "$VM-cidata.iso" >/dev/null 2>&1 || true
      virsh vol-create-as "$POOL" "$VM-cidata.iso" "$ISO_SIZE" --format raw
      virsh vol-upload --pool "$POOL" "$VM-cidata.iso" "$SEED_DIR/$VM/cidata.iso"

      NET_ARGS=""
      if [ "$VM" = "router" ]; then
        NET_ARGS="--network network=$NAT_NET,mac=$MAC_NAT,model=virtio --network network=$PRIVATE_NET,mac=$MAC_PRIVATE,model=virtio"
      elif [ "$VM" = "client" ]; then
        NET_ARGS="--network network=$PRIVATE_NET,mac=$MAC_PRIVATE,model=virtio"
      else
        NET_ARGS="--network network=$NAT_NET,mac=$MAC_NAT,model=virtio"
      fi

      virt-install \
        --name "$VM" \
        --vcpus "$CPUS" \
        --memory "$MEMORY" \
        --osinfo linux2022 \
        --import \
        --disk "vol=$POOL/$VM.qcow2,bus=virtio" \
        --disk "vol=$POOL/$VM-cidata.iso,device=cdrom" \
        $NET_ARGS \
        --sysinfo "type=smbios,system.serial=ds=nocloud" \
        --graphics spice \
        --noautoconsole
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]

    environment = {
      LIBVIRT_DEFAULT_URI = self.input.uri
      VM                  = self.input.vm_name
      NAT_NET             = self.input.nat_net
      MAC_NAT             = self.input.mac_nat
      SEED_DIR            = self.input.seed_dir
    }

    command = <<-EOT
      set -uo pipefail

      if virsh dominfo "$VM" >/dev/null 2>&1; then
        virsh destroy "$VM" 2>/dev/null || true
        virsh undefine "$VM" --remove-all-storage || exit 1
      fi
      
      virsh vol-delete --pool default "$VM-cidata.iso" 2>/dev/null || true

      if [ "$VM" != "client" ]; then
        virsh net-update "$NAT_NET" delete ip-dhcp-host "<host mac='$MAC_NAT'/>" --live --config 2>/dev/null || true
      fi

      rm -rf "$SEED_DIR/$VM"
    EOT
  }
}

resource "local_file" "ansible_inventory" {
  filename             = "${local.work_dir}/inventory.yml"
  file_permission      = "0644"
  directory_permission = "0755"

  content = yamlencode({
    all = {
      vars = {
        ansible_user                 = "ubuntu"
        ansible_ssh_private_key_file = local.private_key
        ansible_ssh_common_args      = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
      }
      hosts = {
        for name, vm in local.vms : name => merge(
          {
            ansible_host     = name == "client" ? vm.private_ip : vm.nat_ip
            private_ip       = vm.private_ip
            private_hostname = replace(name, "_", "-")
          },
          name == "client" ? {
            ansible_ssh_common_args = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand=\"ssh -W %h:%p -q -i ${local.private_key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${cidrhost(var.nat_cidr, 15)}\""
          } : {}
        )
      }
    }
  })
}

resource "terraform_data" "ansible" {
  triggers_replace = [
    [for vm in terraform_data.vm : vm.id],
    sha256(local_file.ansible_inventory.content),
    sha256(join("", [
      for f in sort(fileset(local.ansible_dir, "**")) :
      filesha256("${local.ansible_dir}/${f}")
    ])),
  ]

  provisioner "local-exec" {
    working_dir = local.ansible_dir
    command     = "ansible-playbook site.yml"
  }
}

output "infra_1_attaque_publique" {
  description = "Adresses IP publiques (NAT) des noeuds d'attaque"
  value = {
    "1_Entry_Node (Cible du Payload Poseidon)" = local.vms["entry_node"].nat_ip
    "2_Middle_Node"                            = local.vms["middle_node"].nat_ip
    "3_Exit_Node"                              = local.vms["exit_node"].nat_ip
    "4_C2_Mythic (Interface Web sur port 7443)" = local.vms["c2"].nat_ip
  }
}

output "infra_2_passerelle_routeur" {
  description = "Le pare-feu separant les deux reseaux"
  value = {
    "Patte_Publique (NAT)"             = local.vms["router"].nat_ip
    "Patte_Privee (Passerelle Client)" = local.vms["router"].private_ip
  }
}

output "infra_3_entreprise_privee" {
  description = "Reseau cible isole"
  value = {
    "Client (Victime)" = local.vms["client"].private_ip
  }
}

output "infra_4_commandes_ssh" {
  description = "Commandes pretes a l'emploi pour se connecter aux machines"
  value = {
    "c2"          = "ssh ubuntu@${local.vms["c2"].nat_ip}"
    "entry_node"  = "ssh ubuntu@${local.vms["entry_node"].nat_ip}"
    "middle_node" = "ssh ubuntu@${local.vms["middle_node"].nat_ip}"
    "exit_node"   = "ssh ubuntu@${local.vms["exit_node"].nat_ip}"
    "router"      = "ssh ubuntu@${local.vms["router"].nat_ip}"
    "client"      = "ssh -J ubuntu@${local.vms["router"].nat_ip} ubuntu@${local.vms["client"].private_ip}"
  }
}
