# Three security groups, attached by role:
#   cluster       (all nodes)      : K3s traffic between nodes + outbound HTTP(S)
#   control_plane (server)         : SSH and Kubernetes API from the admin IP
#   workers       (agents)         : SSH from the admin IP, frontend NodePort from app_cidrs
# DNS (VPC resolver) and NTP (169.254.169.123) are not filtered by security groups.

locals {
  app_cidrs = length(var.app_cidrs) > 0 ? var.app_cidrs : [var.admin_cidr]

  # K3s "Inbound Rules for K3s Nodes" (single server, flannel VXLAN, no embedded registry).
  k3s_internal_ports = {
    api     = { protocol = "tcp", port = 6443, description = "K3s API (agents to server)" }
    vxlan   = { protocol = "udp", port = 8472, description = "Flannel VXLAN (pod network)" }
    kubelet = { protocol = "tcp", port = 10250, description = "Kubelet (logs, exec, metrics)" }
  }
}

resource "aws_security_group" "cluster" {
  name        = "${var.project}-cluster"
  description = "Traffic between K3s nodes and outbound HTTP(S)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-cluster" }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_internal" {
  for_each = local.k3s_internal_ports

  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.value.description
}

resource "aws_vpc_security_group_egress_rule" "cluster_internal" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "-1"
  description                  = "Node to node (limited by the ingress rules above)"
}

# Accepted exception to Trivy AWS-0104 (unrestricted egress): the nodes must reach GHCR,
# GitHub, Docker Hub and Open-Meteo, whose CDN-backed IPs change. Egress is limited to
# ports 80/443; destination filtering would need an egress proxy or AWS Network Firewall.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "web" {
  for_each = { http = 80, https = 443 }

  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "Outbound ${upper(each.key)}: packages, K3s, GHCR images, GitHub, Open-Meteo"
}

resource "aws_security_group" "control_plane" {
  name        = "${var.project}-control-plane"
  description = "Admin access to the K3s server"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-control-plane" }
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_admin" {
  for_each = { ssh = 22, kube_api = 6443 }

  security_group_id = aws_security_group.control_plane.id
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "Admin ${each.key} from admin_cidr"
}

resource "aws_security_group" "workers" {
  name        = "${var.project}-workers"
  description = "Admin SSH and the SkyWatch frontend on the K3s agents"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-workers" }
}

resource "aws_vpc_security_group_ingress_rule" "workers_ssh" {
  security_group_id = aws_security_group.workers.id
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "Admin ssh from admin_cidr"
}

resource "aws_vpc_security_group_ingress_rule" "workers_app" {
  for_each = toset(local.app_cidrs)

  security_group_id = aws_security_group.workers.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.frontend_node_port
  to_port           = var.frontend_node_port
  description       = "SkyWatch frontend NodePort"
}
