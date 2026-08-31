output "storefront_url" {
  description = "Public URL of the storefront. Printed by scripts/up.sh and used in the demo."
  value       = module.compute.alb_url
}

output "dashboard_url" {
  description = "Direct console link to the CloudWatch dashboard."
  value       = module.monitoring.dashboard_url
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.networking.vpc_id
}

output "availability_zones" {
  description = "Availability zones the platform spans."
  value       = module.networking.availability_zones
}

output "public_subnet_ids" {
  description = "Public subnet IDs hosting the load balancer and NAT Gateway."
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs hosting the application instances."
  value       = module.networking.private_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "Public IPs the private tier egresses from."
  value       = module.networking.nat_gateway_public_ips
}

output "autoscaling_group_name" {
  description = "Auto Scaling group running the application tier."
  value       = module.compute.autoscaling_group_name
}

output "target_group_arn" {
  description = "Target group ARN. Used by scripts/up.sh to wait for healthy targets."
  value       = module.compute.target_group_arn
}

output "products_table_name" {
  description = "DynamoDB catalog table backing the storefront."
  value       = module.data.products_table_name
}

output "app_log_group_name" {
  description = "CloudWatch log group receiving application logs."
  value       = module.compute.app_log_group_name
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs."
  value       = module.networking.flow_log_group_name
}

output "alerts_topic_arn" {
  description = "Shared SNS topic every alarm publishes to, owned by the bootstrap layer."
  value       = module.monitoring.alerts_topic_arn
}

output "alarm_names" {
  description = "Configured alarms, in decreasing severity."
  value       = module.monitoring.alarm_names
}

output "backup_vault_name" {
  description = "AWS Backup vault holding scheduled recovery points."
  value       = module.data.backup_vault_name
}

output "ami_id" {
  description = "Amazon Linux 2023 AMI the launch template was pinned to at apply time."
  value       = module.compute.ami_id
}
