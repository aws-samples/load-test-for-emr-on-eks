output "ide_url" {
  description = "IDE access URL via Systems Manager Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.ide.id} --region ${var.region}"
}

output "instance_id" {
  description = "IDE EC2 instance ID"
  value       = aws_instance.ide.id
}
