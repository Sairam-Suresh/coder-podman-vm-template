terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.5"
    }
    ct = {
      source  = "poseidon/ct"
      version = "0.14.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///session?socket=/run/user/1000/libvirt/virtqemud-sock"
}

# General Coder and user information
data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_task" "me" {}
data "coder_external_auth" "github" {
   id = "github"
}

variable "proxy_ip" {
  type        = string
  description = "IP address of the HTTP/HTTPS proxy server."
}

variable "proxy_port" {
  type        = number
  description = "Port number of the proxy server."
}

locals {
  # Use a sanitized username for resource naming
  username = "coder"
  # Unique name for the VM domain and its associated resources
  resource_name = "coder-${local.username}-${lower(data.coder_workspace.me.name)}"
  
  # Calculate the working directory to avoid circular dependencies with the git-clone module
  folder_name = data.coder_parameter.enable_git_clone.value == "true" ? replace(basename(try(data.coder_parameter.repo_url[0].value, "")), "/\\.git$/", "") : try(data.coder_parameter.manual_folder_name[0].value, "")
  workdir     = "/home/${local.username}/${local.folder_name}"

  workspace_dockerfile         = file("${path.module}/images/workspace.Dockerfile")
  workspace_desktop_dockerfile = file("${path.module}/images/workspace-desktop.Dockerfile")
  proxy_ip                     = var.proxy_ip
  proxy_port                   = var.proxy_port
}

resource "coder_ai_task" "task" {
  count  = data.coder_workspace.me.start_count
  app_id = module.copilot[count.index].task_app_id
}

variable "base_image_path" {
  type        = string
  description = "Path to the Fedora CoreOS QCOW2 image for the VM."
  default     = "/home/coder/fedora-coreos-qemu-x86_64.qcow2"
}

data "coder_parameter" "vm_vcpu" {
  type         = "number"
  name         = "vm_vcpu"
  display_name = "CPUs"
  description  = "Enter the number of virtual CPUs for the workspace VM."
  default      = 4
  form_type    = "slider"
  validation {
    min = 1
    max = 16
  }
  mutable = true
}

data "coder_parameter" "vm_memory" {
  type         = "number"
  name         = "vm_memory"
  display_name = "Memory"
  description  = "Enter the amount of Memory for the workspace VM in GiB."
  default      = 8
  form_type    = "slider"
  validation {
    min = 4
    max = 20
  }
  mutable = true
}

data "coder_parameter" "vm_disk_size" {
  type         = "number"
  name         = "vm_disk_size"
  display_name = "User Disk Size"
  description  = "Enter the amount of storage for the persistent User Data volume in GiB."
  default      = 20
  mutable      = false
}

data "coder_parameter" "install_de" {
  type         = "bool"
  name         = "install_de"
  display_name = "Desktop Environment"
  description  = "Install XFCE, KasmVNC, and Google Chrome for GUI access?"
  default      = "false"
  mutable      = true
}

data "coder_parameter" "enable_git_clone" {
  type         = "bool"
  name         = "enable_git_clone"
  display_name = "Clone a Repository?"
  description  = "If yes, enter the cloning URL. Else, provide a local folder name to create"
  default      = "false"
  form_type    = "checkbox"
}

data "coder_parameter" "enable_devcontainer" {
  type         = "bool"
  name         = "enable_devcontainer"
  display_name = "Enable Devcontainers"
  description  = "Installs Devcontainer Support."
  default      = "false"
  mutable      = true
}

data "coder_parameter" "repo_url" {
  count        = data.coder_parameter.enable_git_clone.value == "true" ? 1 : 0
  type         = "string"
  name         = "repo_url"
  display_name = "Git Repository URL"
  default      = "https://github.com/coder/coder"
}

data "coder_parameter" "manual_folder_name" {
  count        = data.coder_parameter.enable_git_clone.value == "false" ? 1 : 0
  type         = "string"
  name         = "manual_folder_name"
  display_name = "New Folder Name"
  description  = "Enter the name of the folder to create in your home directory."
  default      = "my-workspace"
}

data "ct_config" "ign" {
  count = data.coder_workspace.me.start_count
  content = templatefile("${path.module}/config.bu", {
    coder_agent_token           = coder_agent.main[count.index].token
    coder_agent_url             = "https://coder.service.internal"
    coder_agent_init_script_b64 = base64encode(coder_agent.main[count.index].init_script)
    git_author_name             = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    git_author_email            = data.coder_workspace_owner.me.email
    git_committer_name          = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    git_committer_email         = data.coder_workspace_owner.me.email
    coder_workdir               = local.workdir
    install_de                  = data.coder_parameter.install_de.value
    workspace_dockerfile_b64        = base64encode(local.workspace_dockerfile)
    workspace_desktop_dockerfile_b64 = base64encode(local.workspace_desktop_dockerfile)
    proxy_ip                    = local.proxy_ip
    proxy_port                  = local.proxy_port
  })

  strict       = true
  pretty_print = true
}

# Libvirt Combustion resource to handle the Ignition configuration
resource "libvirt_combustion" "main" {
  name  = "${local.resource_name}-ign-intermediate"
  count = data.coder_workspace.me.start_count

  content = data.ct_config.ign[count.index].rendered

  lifecycle {
    replace_triggered_by = [data.ct_config.ign[count.index].rendered]
  }
}

resource "libvirt_volume" "ignition" {
  name   = "${local.resource_name}-ign-intermediate"
  count = data.coder_workspace.me.start_count
  pool   = "default"
  target = { format = {type = "raw"} }

  create = {
    content = {
      url = libvirt_combustion.main[count.index].path
    }
  }
}

# ----------------------------
# System Disk Trigger (Fedora CoreOS is immutable, only trigger on base image change)
# ----------------------------
resource "terraform_data" "os_disk_trigger" {
  triggers_replace = {
    # FCOS is immutable - only trigger replacement if the base image path changes
    base_image_path = var.base_image_path
  }
}

# ----------------------------
# System Disk (Fedora CoreOS - Immutable, persists across provisioning)
# ----------------------------
resource "libvirt_volume" "os_disk" {
  name     = "${local.resource_name}-os"
  pool     = "default"
  capacity = 10 * 1024 * 1024 * 1024 # 20 GB purely for the OS/system
  target   = { format = { type = "qcow2" } }

  backing_store = {
    path   = var.base_image_path
    format = {
      type = "qcow2"
    }
  }

  lifecycle {
    replace_triggered_by = [
      terraform_data.os_disk_trigger.id # Only triggers on base image change
    ]
  }
}

# ----------------------------
# Persistent User Data Disk 
# ----------------------------
resource "libvirt_volume" "userdata_disk" {
  name     = "${local.resource_name}-userdata"
  pool     = "default"
  capacity = data.coder_parameter.vm_disk_size.value * 1024 * 1024 * 1024
  target   = { format = { type = "qcow2" } }
}

resource "libvirt_domain" "main" {
  count  = data.coder_workspace.me.start_count

  name    = local.resource_name
  running = true
  
  # Injecting the coder_agent ID directly here forces the Coder UI 
  # to correctly assign and display the agent against this Libvirt VM resource.
  description = "Workspace VM for ${local.username}."

  memory      = data.coder_parameter.vm_memory.value
  memory_unit = "GiB"
  vcpu        = data.coder_parameter.vm_vcpu.value
  type        = "kvm"

  cpu = {
    mode = "host-passthrough"
  }  

  lifecycle {
    replace_triggered_by = [
      terraform_data.os_disk_trigger.id,
      libvirt_combustion.main[count.index].id
    ]
  }

  destroy = {
    graceful = true
    timeout  = 120
  }

  os = {
    type         = "hvm"
    arch         = "x86_64"
    machine      = "q35"
    boot_devices = [{dev = "hd"}]
  }

  devices = {
    disks = [
      {
        # The ignition for CoreOS
        # device = "cdrom"
        driver = { type = "raw" },
        source = {
          volume = {
            pool   = libvirt_volume.ignition[count.index].pool
            volume = libvirt_volume.ignition[count.index].name
          }
        },
        # target = {
        #   dev = "sda"
        #   bus = "sata"
        # }
      },
      {
        # vda: The OS disk (Fedora CoreOS)
        driver = { type = "qcow2" }
        source = {
          volume = {
            pool   = libvirt_volume.os_disk.pool
            volume = libvirt_volume.os_disk.name
          }
        }
        target = { bus = "virtio", dev = "vda" }
      },
      {
        # vdb: The Persistent User Data disk
        driver = { type = "qcow2" }
        source = {
          volume = {
            pool   = libvirt_volume.userdata_disk.pool
            volume = libvirt_volume.userdata_disk.name
          }
        }
        target = { bus = "virtio", dev = "vdb" }
      }
    ]

    interfaces = [
      {
        type  = "user"
        model = { type = "virtio" }
        backend = { type = "passt" }
      },
    ]

    consoles = [
      {
        type        = "pty"
        target_type = "serial"
        target_port = "0"
      }
    ]

    graphics = [
      {
        vnc = { auto_port = true }
      }
    ]

    videos = [
      {
        model = {
          type    = "cirrus"
          primary = "yes"
          heads   = 1
          vram    = 16384
        }
      }
    ]
  }
}

resource "coder_agent" "main" {
  arch            = data.coder_provisioner.me.arch
  count           = data.coder_workspace.me.start_count
  os              = "linux"
  startup_script  = <<-EOT
    set -e

    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi
  EOT

  connection_timeout = 180
  
  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    DOCKER_HOST         = "unix:///run/user/1001/podman/podman.sock"
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Tailscale Ping to Homelab"
    key          = "8_ts_ping"
    script       = <<EOT
    tailscale ping -c 1 homelab 2>/dev/null | grep "pong" | awk '{print $NF}'
    EOT
    interval     = 25
    timeout      = 1
  }

  metadata {
    display_name = "Connection to Homelab"
    key          = "9_ts_conn_type"
    script       = <<EOT
    tailscale ping -c 1 homelab 2>/dev/null | grep "pong" | awk '{print $6}'
    EOT
    interval     = 25
    timeout      = 1
  }
}

module "code-server" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/code-server/coder"
  version = "~> 1.0"
  folder = local.workdir
  extensions = ["catppuccin.catppuccin-vsc-icons", "github.vscode-pull-request-github", "catppuccin.catppuccin-vsc"]

  open_in = "tab"

  settings = {
    "git.autofetch": true,
    "git.enableSmartCommit": true,
    "git.confirmSync": false,
    "workbench.iconTheme": "catppuccin-mocha",
    "workbench.colorTheme": "Catppuccin Mocha"
  }

  subdomain = true
  agent_id  = coder_agent.main[count.index].id
  order     = 1
}

module "antigravity" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/antigravity/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main[count.index].id
  folder = local.workdir

  mcp = jsonencode({
    mcpServers = {
      "github" : {
        "url" : "https://api.githubcopilot.com/mcp/",
        "headers" : {
          "Authorization" : "Bearer ${data.coder_external_auth.github.access_token}",
        },
        "type" : "http"
      }
    }
  })
}

module "copilot" {
  source   = "registry.coder.com/coder-labs/copilot/coder"
  version  = "0.3.0"
  count  = data.coder_workspace.me.start_count
  agent_id = coder_agent.main[count.index].id
  workdir  = local.workdir

  ai_prompt = data.coder_task.me.prompt

  pre_install_script = <<-EOT
    #!/bin/bash
    set -e

    if ! command -v node &> /dev/null; then
      curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
      sudo apt-get install -y nodejs
    fi

    export NPM_CONFIG_PREFIX="$HOME/.local"
    mkdir -p "$NPM_CONFIG_PREFIX"
    
    npm config set prefix $NPM_CONFIG_PREFIX

    if ! grep -q "NPM_CONFIG_PREFIX" ~/.bashrc; then
      echo 'export NPM_CONFIG_PREFIX="$HOME/.local"' >> ~/.bashrc
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    fi

    export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
  EOT
}

module "git-commit-signing" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/git-commit-signing/coder"
  version  = "1.0.31"
  agent_id = coder_agent.main[count.index].id
}

module "jetbrains_gateway" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/jetbrains-gateway/coder"

  jetbrains_ides = ["IU", "PS", "WS", "PY", "CL", "GO", "RM", "RD", "RR"]
  default        = "IU"
  folder         = "/home/coder"
  version        = "~> 1.0"

  agent_id   = coder_agent.main[count.index].id
  agent_name = "main"
}

module "git-clone" {
  count    = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.enable_git_clone.value == "true") ? 1 : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main[count.index].id
  url      = data.coder_parameter.repo_url[0].value
  base_dir = "/home/${local.username}" 
}

module "kasmvnc" {
  count               = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.install_de.value == "true") ? 1 : 0
  source              = "registry.coder.com/coder/kasmvnc/coder"
  version             = "1.2.3"
  agent_id            = coder_agent.main[count.index].id
  desktop_environment = "xfce"
  subdomain           = true
}

# resource "coder_devcontainer" "devcontainer" {
#   count            = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.enable_devcontainer.value == "true") ? 1 : 0
#   agent_id         = coder_agent.main[count.index].id
#   workspace_folder = local.workdir
# }