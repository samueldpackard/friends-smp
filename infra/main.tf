# Friends SMP on AWS:
#   gateway  - tiny always-on VM with a static IP; players connect here. Wakes the server on join.
#   server   - big VM that runs only while people play; puts itself to sleep when idle.
#   data     - separate disk for the world; backups go to S3 on every sleep.
terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = { project = "friends-smp" }
  }
}

data "aws_caller_identity" "me" {}

locals {
  pack              = file("${path.module}/../pack/pack.toml")
  minecraft_version = regex("minecraft = \"([^\"]+)\"", local.pack)[0]
  fabric_version    = regex("fabric = \"([^\"]+)\"", local.pack)[0]
  image             = "itzg/minecraft-server:java25"
  server_ip         = "10.42.1.10"
  gateway_ip        = "10.42.1.5"
}

# ---------- Network: one VPC, one public subnet, no NAT (costs nothing) ----------

# Pick an availability zone where the server instance type exists.
data "aws_ec2_instance_type_offerings" "server" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.server_instance_type]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "friends-smp" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.42.1.0/24"
  availability_zone = sort(data.aws_ec2_instance_type_offerings.server.locations)[0]
  tags              = { Name = "friends-smp-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------- Firewalls ----------

resource "aws_security_group" "gateway" {
  name   = "friends-smp-gateway"
  vpc_id = aws_vpc.main.id
  ingress {
    description = "Minecraft"
    from_port   = 25565
    to_port     = 25565
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Simple Voice Chat"
    from_port   = 24454
    to_port     = 24454
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The server accepts game traffic only from the gateway. No SSH: admin access is via SSM.
resource "aws_security_group" "server" {
  name   = "friends-smp-server"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 25565
    to_port         = 25565
    protocol        = "tcp"
    security_groups = [aws_security_group.gateway.id]
  }
  ingress {
    from_port       = 24454
    to_port         = 24454
    protocol        = "udp"
    security_groups = [aws_security_group.gateway.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}
