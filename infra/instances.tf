# ---------- Permissions ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Main server: read its config, write backups, and allow admin shell access via SSM.
resource "aws_iam_role" "server" {
  name               = "friends-smp-server"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "server" {
  role = aws_iam_role.server.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.main.arn },
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.main.arn}/config/*" },
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.main.arn}/backups/*" },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "server_ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "server" {
  name = "friends-smp-server"
  role = aws_iam_role.server.name
}

# Gateway: see the server's state, start it (only that one VM), fetch its own binary.
resource "aws_iam_role" "gateway" {
  name               = "friends-smp-gateway"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "gateway" {
  role = aws_iam_role.gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:DescribeInstances"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:StartInstances"], Resource = aws_instance.server.arn },
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.main.arn}/gateway/*" },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gateway_ssm" {
  role       = aws_iam_role.gateway.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "gateway" {
  name = "friends-smp-gateway"
  role = aws_iam_role.gateway.name
}

# ---------- Main server ----------

resource "aws_instance" "server" {
  ami                                  = data.aws_ssm_parameter.al2023_arm64.value
  instance_type                        = var.server_instance_type
  subnet_id                            = aws_subnet.public.id
  private_ip                           = local.server_ip
  associate_public_ip_address          = true # outbound internet only (mod downloads); inbound is gateway-only
  vpc_security_group_ids               = [aws_security_group.server.id]
  iam_instance_profile                 = aws_iam_instance_profile.server.name
  instance_initiated_shutdown_behavior = "stop" # `shutdown -h now` = sleep, not delete
  user_data = templatefile("${path.module}/files/server-user-data.sh.tftpl", {
    bucket         = aws_s3_bucket.main.id
    image          = local.image
    data_volume_id = aws_ebs_volume.world.id
  })

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }
  metadata_options {
    http_tokens = "required"
  }
  tags = { Name = "friends-smp-server" }

  # Config lives in S3, so a new base image or edited first-boot script is no reason to rebuild the VM.
  lifecycle { ignore_changes = [ami, user_data] }
  depends_on = [aws_s3_object.mc_env, aws_s3_object.host_env, aws_s3_object.scripts]
}

resource "aws_volume_attachment" "world" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.world.id
  instance_id                    = aws_instance.server.id
  stop_instance_before_detaching = true
}

# ---------- Gateway ----------

resource "aws_instance" "gateway" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.gateway_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.gateway_ip
  vpc_security_group_ids = [aws_security_group.gateway.id]
  iam_instance_profile   = aws_iam_instance_profile.gateway.name
  user_data = templatefile("${path.module}/files/gateway-user-data.sh.tftpl", {
    bucket              = aws_s3_bucket.main.id
    region              = var.region
    backend_instance_id = aws_instance.server.id
    backend_ip          = local.server_ip
    max_players         = var.max_players
  })

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }
  metadata_options {
    http_tokens = "required"
  }
  tags = { Name = "friends-smp-gateway" }

  lifecycle { ignore_changes = [ami] }
  depends_on = [aws_s3_object.gateway_binary]
}

# Static public IP: the address players use. Never changes.
resource "aws_eip" "gateway" {
  instance = aws_instance.gateway.id
  domain   = "vpc"
  tags     = { Name = "friends-smp" }
}
