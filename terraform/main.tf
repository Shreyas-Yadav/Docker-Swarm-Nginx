terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── Networking ───────────────────────────────────────────────────────────────

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "swarm" {
  name        = "docker-swarm-sg"
  description = "Docker Swarm cluster traffic"
  vpc_id      = data.aws_vpc.default.id

  # SSH from operator
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  # Swarm cluster management (manager only)
  ingress {
    from_port   = 2377
    to_port     = 2377
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # Node-to-node communication
  ingress {
    from_port   = 7946
    to_port     = 7946
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  ingress {
    from_port   = 7946
    to_port     = 7946
    protocol    = "udp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # Overlay network (VXLAN)
  ingress {
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # Nginx service — publicly accessible
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "docker-swarm-sg" }
}

# ─── EC2 Instances ────────────────────────────────────────────────────────────

resource "aws_instance" "manager_primary" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.swarm.id]

  tags = {
    Name = "swarm-manager-1"
    Role = "manager"
  }
}

resource "aws_instance" "manager" {
  count                  = 2
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.swarm.id]

  tags = {
    Name = "swarm-manager-${count.index + 2}"
    Role = "manager"
  }
}

resource "aws_instance" "worker" {
  count                  = 2
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.swarm.id]

  tags = {
    Name = "swarm-worker-${count.index + 1}"
    Role = "worker"
  }
}

# ─── Swarm Bootstrap ──────────────────────────────────────────────────────────
#
# A single local-exec script orchestrates swarm init, node joins, and stack
# deploy over SSH. This avoids the timing complexity of chaining multiple
# null_resources and keeps the bootstrap logic in one place.

resource "null_resource" "swarm_bootstrap" {
  depends_on = [
    aws_instance.manager_primary,
    aws_instance.manager,
    aws_instance.worker,
  ]

  # Re-run bootstrap if any instance is replaced
  triggers = {
    manager_primary_id = aws_instance.manager_primary.id
    manager_ids        = join(",", aws_instance.manager[*].id)
    worker_ids         = join(",", aws_instance.worker[*].id)
  }

  provisioner "file" {
    source      = "${path.module}/nginx.yaml"
    destination = "/tmp/nginx.yaml"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(var.private_key_path)
      host        = aws_instance.manager_primary.public_ip
    }
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i ${var.private_key_path}"
      LEADER_PUB="${aws_instance.manager_primary.public_ip}"
      LEADER_PRIV="${aws_instance.manager_primary.private_ip}"

      echo "==> Waiting for instances to be SSH-ready..."
      for host in $LEADER_PUB ${join(" ", aws_instance.manager[*].public_ip)} ${join(" ", aws_instance.worker[*].public_ip)}; do
        until $SSH ubuntu@$host "echo ready" 2>/dev/null; do sleep 5; done
        echo "    $host ready"
      done

      echo "==> Initializing Swarm on primary manager ($LEADER_PRIV)..."
      $SSH ubuntu@$LEADER_PUB "docker swarm init --advertise-addr $LEADER_PRIV || true"

      echo "==> Fetching join tokens..."
      MANAGER_TOKEN=$($SSH ubuntu@$LEADER_PUB "docker swarm join-token -q manager")
      WORKER_TOKEN=$($SSH ubuntu@$LEADER_PUB "docker swarm join-token -q worker")

      echo "==> Joining additional managers..."
      for host in ${join(" ", aws_instance.manager[*].public_ip)}; do
        $SSH ubuntu@$host "docker swarm join --token $MANAGER_TOKEN $LEADER_PRIV:2377 || true"
        echo "    $host joined as manager"
      done

      echo "==> Joining workers..."
      for host in ${join(" ", aws_instance.worker[*].public_ip)}; do
        $SSH ubuntu@$host "docker swarm join --token $WORKER_TOKEN $LEADER_PRIV:2377 || true"
        echo "    $host joined as worker"
      done

      echo "==> Deploying nginx stack..."
      $SSH ubuntu@$LEADER_PUB "docker stack deploy -c /tmp/nginx.yaml nginx"

      echo "==> Cluster ready. Node list:"
      $SSH ubuntu@$LEADER_PUB "docker node ls"
    EOT
  }
}
