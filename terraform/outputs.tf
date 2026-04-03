output "manager_primary_public_ip" {
  description = "Public IP of the Swarm leader (use for SSH and service access)"
  value       = aws_instance.manager_primary.public_ip
}

output "manager_public_ips" {
  description = "Public IPs of the additional manager nodes"
  value       = aws_instance.manager[*].public_ip
}

output "worker_public_ips" {
  description = "Public IPs of the worker nodes"
  value       = aws_instance.worker[*].public_ip
}

output "nginx_url" {
  description = "URL to reach the deployed Nginx service"
  value       = "http://${aws_instance.manager_primary.public_ip}:8080"
}

output "ssh_command" {
  description = "SSH command to connect to the primary manager"
  value       = "ssh -i <your-key.pem> ubuntu@${aws_instance.manager_primary.public_ip}"
}
