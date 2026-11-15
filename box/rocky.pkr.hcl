packer {
  required_version = ">= 1.10.0"

  required_plugins {
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = ">= 1.1.0"
    }
    vagrant = {
      source  = "github.com/hashicorp/vagrant"
      version = ">= 1.1.0"
    }
  }
}

locals {
  iso_url      = pathexpand(var.iso_path)
  iso_checksum = "file:${pathexpand(var.iso_checksum_file)}"
}

source "virtualbox-iso" "rocky" {
  vm_name       = var.vm_name
  guest_os_type = "RedHat_64"
  headless      = var.headless
  firmware      = "efi"

  iso_url      = local.iso_url
  iso_checksum = local.iso_checksum

  cpus                 = var.cpus
  memory               = var.memory
  disk_size            = var.disk_size
  hard_drive_interface = "sata"
  iso_interface        = "sata"
  gfx_controller       = "vmsvga"
  gfx_vram_size        = 16

  vboxmanage = [
    ["modifyvm", "{{ .Name }}", "--nat-localhostreachable1", "on"],
    ["modifyvm", "{{ .Name }}", "--rtc-use-utc", "on"],
  ]

  # Serves the kickstart file.
  http_directory = "http"

  # GRUB (EFI) menu: select "Install Rocky Linux" (skip media test), edit the
  # kernel line to append the kickstart location, then boot with F10.
  boot_wait = "5s"
  boot_command = [
    "<up><wait>e<wait>",
    "<down><wait><down><wait><end>",
    " inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg",
    "<wait><f10>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = "45m"
  ssh_handshake_attempts = 100

  guest_additions_mode = "upload"
  guest_additions_path = "/home/${var.ssh_username}/VBoxGuestAdditions.iso"

  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"

  output_directory = "output/${var.vm_name}"
}

build {
  sources = ["source.virtualbox-iso.rocky"]

  # Update the OS, then reboot so Guest Additions build against the new kernel.
  provisioner "shell" {
    execute_command   = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash -eux '{{ .Path }}'"
    expect_disconnect = true
    scripts           = ["scripts/base.sh"]
  }

  provisioner "shell" {
    execute_command  = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash -eux '{{ .Path }}'"
    environment_vars = ["SSH_USERNAME=${var.ssh_username}"]
    pause_before     = "30s"
    scripts = [
      "scripts/guest-additions.sh",
      "scripts/vagrant.sh",
      "scripts/cleanup.sh",
    ]
  }

  post-processor "vagrant" {
    output              = "output/${var.vm_name}-{{ .Provider }}.box"
    keep_input_artifact = true
    compression_level   = 9
  }
}
