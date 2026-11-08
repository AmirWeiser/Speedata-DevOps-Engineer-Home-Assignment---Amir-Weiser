# Hand-off to Ansible. Terraform owns AWS resources; Ansible owns everything inside the
# instances (K3s) and the one-time Argo CD bootstrap; after that, Git owns the app.

locals {
  repo_root        = abspath("${path.module}/../..")
  inventory_path   = "${local.repo_root}/ansible/inventory.generated.yml"
  known_hosts_path = "${local.repo_root}/ansible/known_hosts.generated"
  kubeconfig_path  = "${local.repo_root}/kubeconfig-aws"

  servers = { for name, i in aws_instance.node : name => i if local.nodes[name].role == "server" }
  agents  = { for name, i in aws_instance.node : name => i if local.nodes[name].role == "agent" }

  # Files whose change must re-run the bootstrap (generated files excluded).
  bootstrap_files = concat(
    [for f in fileset("${local.repo_root}/ansible", "**") : "ansible/${f}" if !can(regex("generated", f))],
    [for f in fileset("${local.repo_root}/argocd", "**") : "argocd/${f}"],
    ["scripts/bootstrap-argocd.sh"],
  )
}

resource "local_file" "inventory" {
  filename        = local.inventory_path
  file_permission = "0644" # IPs and paths only; no secrets
  content = yamlencode({
    all = {
      vars = {
        ansible_user                 = "ubuntu"
        ansible_ssh_private_key_file = pathexpand(var.ssh_private_key_path)
        # Trust-on-first-use, in a per-deployment file that destroy removes, so a
        # recycled public IP never conflicts with ~/.ssh/known_hosts.
        ansible_ssh_common_args = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${local.known_hosts_path}"
        k3s_api_endpoint        = aws_instance.node["${var.project}-cp"].public_ip
        kubeconfig_path         = local.kubeconfig_path
      }
      children = {
        k3s_server = {
          hosts = { for name, i in local.servers : name => { ansible_host = i.public_ip, private_ip = i.private_ip } }
        }
        k3s_agents = {
          hosts = { for name, i in local.agents : name => { ansible_host = i.public_ip, private_ip = i.private_ip } }
        }
      }
    }
  })
}

resource "terraform_data" "bootstrap" {
  count = var.run_ansible ? 1 : 0

  # Re-run when the machines, their public IPs or the bootstrap code change.
  # Re-running is safe: the playbook is idempotent.
  triggers_replace = {
    instances = join(",", [for name, i in aws_instance.node : "${name}=${i.id}/${i.public_ip}"])
    bootstrap = sha1(join("", [for f in sort(local.bootstrap_files) : filesha1("${local.repo_root}/${f}")]))
  }

  provisioner "local-exec" {
    working_dir = "${local.repo_root}/ansible"
    command     = "ansible-playbook site.yml"
  }

  # Instances only depend on their security groups, not on the separate rule resources,
  # so wait explicitly for routing and every rule (SSH in, 80/443 out, K3s ports).
  depends_on = [
    local_file.inventory,
    aws_route_table_association.public,
    aws_vpc_security_group_ingress_rule.cluster_internal,
    aws_vpc_security_group_egress_rule.cluster_internal,
    aws_vpc_security_group_egress_rule.web,
    aws_vpc_security_group_ingress_rule.control_plane_admin,
    aws_vpc_security_group_ingress_rule.workers_ssh,
    aws_vpc_security_group_ingress_rule.workers_app,
  ]
}

# Removes the local files that belong to this environment when it is destroyed.
resource "terraform_data" "local_files" {
  input = {
    files = "'${local.kubeconfig_path}' '${local.known_hosts_path}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ${self.input.files}"
  }
}
