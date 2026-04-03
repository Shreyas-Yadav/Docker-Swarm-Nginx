variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "AMI with Docker pre-installed (the custom AMI from the tutorial)"
  type        = string
  default     = "ami-03f5aa64b2abd7080"
}

variable "instance_type" {
  description = "EC2 instance type for all swarm nodes"
  type        = string
  default     = "t2.micro"
}

variable "key_name" {
  description = "Name of the EC2 key pair to use for SSH access"
  type        = string
}

variable "private_key_path" {
  description = "Local path to the private key (.pem) matching var.key_name"
  type        = string
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH into nodes (restrict to your IP in production)"
  type        = string
  default     = "0.0.0.0/0"
}
