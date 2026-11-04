output "instance_id" {
  value = aws_instance.app.id
}

output "public_ip" {
  value = aws_instance.app.public_ip
}

output "app_url" {
  value = "http://${aws_instance.app.public_ip}/"
}

output "health_url" {
  value = "http://${aws_instance.app.public_ip}/health"
}

output "ssm_command" {
  description = "Open a shell on the instance (no SSH needed)"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.region}"
}
