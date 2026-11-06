variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ for the subnet. Empty = first available AZ in the region."
  type        = string
  default     = ""
}

variable "project" {
  description = "Name prefix and Project tag for every resource."
  type        = string
  default     = "skywatch"
}

variable "admin_cidr" {
  description = "Your public IP as a /32 (curl -s https://checkip.amazonaws.com). Allowed to SSH and to reach the Kubernetes API."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && !startswith(var.admin_cidr, "0.0.0.0/")
    error_message = "admin_cidr must be a valid CIDR (e.g. 203.0.113.10/32) and must not be 0.0.0.0/0."
  }
}

variable "app_cidrs" {
  description = "CIDRs allowed to open the SkyWatch frontend (NodePort on the workers). Empty = admin_cidr only. Use [\"0.0.0.0/0\"] to make it public."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "control_plane_instance_type" {
  description = "Instance type of the K3s server (control plane only, no app workloads)."
  type        = string
  default     = "t3.small"
}

variable "worker_instance_type" {
  description = "Instance type of the K3s agents (run Argo CD and SkyWatch)."
  type        = string
  default     = "t3.medium"
}

variable "worker_count" {
  description = "Number of K3s agents. The chart spreads each component one replica per worker, so at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 2
    error_message = "worker_count must be at least 2."
  }
}

variable "root_volume_size_gb" {
  description = "Size of each node's encrypted gp3 root volume."
  type        = number
  default     = 20
}

variable "frontend_node_port" {
  description = "NodePort of the frontend Service (must match helm/skywatch values)."
  type        = number
  default     = 30080
}

variable "ssh_public_key_path" {
  description = "Public key uploaded as the EC2 key pair (the private key never leaves your machine)."
  type        = string
  default     = "~/.ssh/skywatch_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Private key Ansible uses to connect (path only; written into the git-ignored inventory)."
  type        = string
  default     = "~/.ssh/skywatch_ed25519"
}

variable "run_ansible" {
  description = "Run the Ansible bootstrap (K3s + Argo CD) as part of terraform apply. false = infrastructure only."
  type        = bool
  default     = true
}
