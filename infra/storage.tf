# S3 bucket: server config (synced on each boot), gateway binary, and world backups.
resource "aws_s3_bucket" "main" {
  bucket = "friends-smp-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter { prefix = "backups/dated/" }
    expiration { days = 90 }
  }
}

resource "aws_s3_object" "mc_env" {
  bucket = aws_s3_bucket.main.id
  key    = "config/mc.env"
  content = templatefile("${path.module}/files/mc.env.tftpl", {
    minecraft_version = local.minecraft_version
    fabric_version    = local.fabric_version
    pack_url          = var.pack_url
    memory            = var.server_memory
    max_players       = var.max_players
    whitelist         = join(",", var.whitelist)
    ops               = join(",", var.ops)
  })
}

resource "aws_s3_object" "host_env" {
  bucket  = aws_s3_bucket.main.id
  key     = "config/host.env"
  content = "IDLE_MINUTES=${var.idle_minutes}\nBACKUP_BUCKET=${aws_s3_bucket.main.id}\n"
}

resource "aws_s3_object" "scripts" {
  for_each = toset(["idle-check.sh", "backup.sh"])
  bucket   = aws_s3_bucket.main.id
  key      = "config/${each.key}"
  source   = "${path.module}/files/${each.key}"
  etag     = filemd5("${path.module}/files/${each.key}")
}

# Built by infra/deploy.sh before `tofu apply`.
resource "aws_s3_object" "gateway_binary" {
  bucket = aws_s3_bucket.main.id
  key    = "gateway/gateway-linux-arm64"
  source = "${path.module}/../gateway/dist/gateway-linux-arm64"
  etag   = filemd5("${path.module}/../gateway/dist/gateway-linux-arm64")
}

# World disk. prevent_destroy: `tofu destroy` refuses to delete the world by accident.
resource "aws_ebs_volume" "world" {
  availability_zone = aws_subnet.public.availability_zone
  size              = var.world_disk_gb
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "friends-smp-world" }
  lifecycle { prevent_destroy = true }
}
