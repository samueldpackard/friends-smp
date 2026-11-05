output "server_address" {
  description = "What players type into Minecraft."
  value       = aws_eip.gateway.public_ip
}

output "server_instance_id" {
  value = aws_instance.server.id
}

output "gateway_instance_id" {
  value = aws_instance.gateway.id
}

output "bucket" {
  value = aws_s3_bucket.main.id
}
