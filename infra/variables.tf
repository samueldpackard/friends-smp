variable "region" {
  type    = string
  default = "us-west-2" # Oregon
}

variable "aws_profile" {
  description = "AWS CLI profile (IAM Identity Center login)."
  type        = string
  default     = "friends-smp"
}

variable "server_instance_type" {
  description = "Main server VM. Runs only while people play. arm64 (Graviton) only."
  type        = string
  default     = "m8g.xlarge" # 4 vCPU, 16 GB
}

variable "server_memory" {
  description = "Java heap for Minecraft (leave ~4 GB for the OS and Docker)."
  type        = string
  default     = "12G"
}

variable "gateway_instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "world_disk_gb" {
  type    = number
  default = 30
}

variable "idle_minutes" {
  description = "Minutes with nobody online before the server goes to sleep."
  type        = number
  default     = 15
}

variable "max_players" {
  type    = number
  default = 15
}

variable "whitelist" {
  description = "Minecraft usernames allowed to join."
  type        = list(string)
  default     = ["FeelMyNub"]
}

variable "ops" {
  description = "Minecraft usernames with admin (operator) rights."
  type        = list(string)
  default     = ["FeelMyNub"]
}

variable "pack_url" {
  type    = string
  default = "https://samueldpackard.github.io/friends-smp/pack.toml"
}
