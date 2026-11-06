output "nodes" {
  description = "Node name -> public and private IP."
  value       = { for name, i in aws_instance.node : name => { public_ip = i.public_ip, private_ip = i.private_ip } }
}

output "app_urls" {
  description = "SkyWatch frontend (NodePort on each worker)."
  value       = [for name, i in local.agents : "http://${i.public_ip}:${var.frontend_node_port}"]
}

output "kubeconfig" {
  description = "Kubeconfig written by Ansible (git-ignored)."
  value       = "export KUBECONFIG=${local.kubeconfig_path}"
}

output "ssh_control_plane" {
  description = "SSH to the K3s server."
  value       = "ssh -i ${var.ssh_private_key_path} -o UserKnownHostsFile=${local.known_hosts_path} ubuntu@${aws_instance.node["${var.project}-cp"].public_ip}"
}

output "argocd_ui" {
  description = "Argo CD UI (port-forward; not exposed publicly)."
  value       = "KUBECONFIG=${local.kubeconfig_path} kubectl -n argocd port-forward svc/argocd-server 8443:443  ->  https://localhost:8443"
}
