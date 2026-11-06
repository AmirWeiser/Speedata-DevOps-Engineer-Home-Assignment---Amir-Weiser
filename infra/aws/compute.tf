data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_key_pair" "admin" {
  key_name   = "${var.project}-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

locals {
  nodes = merge(
    {
      "${var.project}-cp" = {
        role            = "server"
        instance_type   = var.control_plane_instance_type
        security_groups = [aws_security_group.cluster.id, aws_security_group.control_plane.id]
      }
    },
    {
      for i in range(var.worker_count) : "${var.project}-worker-${i + 1}" => {
        role            = "agent"
        instance_type   = var.worker_instance_type
        security_groups = [aws_security_group.cluster.id, aws_security_group.workers.id]
      }
    }
  )
}

resource "aws_instance" "node" {
  for_each = local.nodes

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = each.value.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = each.value.security_groups
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = true
  # No IAM instance profile: nothing on the nodes calls AWS APIs.

  credit_specification {
    cpu_credits = "unlimited" # no CPU throttling under load; surplus is billed ($0.05/vCPU-h)
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods (one network hop further) cannot reach IMDS
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = each.key
    Role = each.value.role
  }

  lifecycle {
    # A newer Ubuntu AMI must not replace a running cluster on the next apply.
    ignore_changes = [ami]
  }
}
