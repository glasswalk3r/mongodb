variable "vm_name" {
  type    = string
  default = "rockylinux"
}

variable "iso_path" {
  description = "Local path to the Rocky Linux DVD ISO"
  type        = string
  default     = "~/Downloads/Rocky-10.2-x86_64-dvd1.iso"
}

variable "iso_checksum_file" {
  description = "Local path to the Rocky Linux CHECKSUM file; the ISO's SHA256 is looked up by file name"
  type        = string
  default     = "~/Downloads/CHECKSUM"
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 4096
}

variable "disk_size" {
  description = "Disk size in MB"
  type        = number
  default     = 40960
}

variable "headless" {
  type    = bool
  default = true
}

variable "ssh_username" {
  type    = string
  default = "vagrant"
}

variable "ssh_password" {
  type      = string
  default   = "vagrant"
  sensitive = true
}
