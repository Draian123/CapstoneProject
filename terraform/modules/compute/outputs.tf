output "alb_dns_name" {
  description = "Public DNS name of the load balancer. This is the storefront URL."
  value       = aws_lb.this.dns_name
}

output "alb_url" {
  description = "Fully qualified storefront URL."
  value       = "http://${aws_lb.this.dns_name}"
}

output "alb_arn" {
  description = "ARN of the load balancer."
  value       = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix, the dimension value CloudWatch uses for load balancer metrics."
  value       = aws_lb.this.arn_suffix
}

output "alb_zone_id" {
  description = "Hosted zone ID of the load balancer, for an alias record if a domain is added later."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "ARN of the application target group."
  value       = aws_lb_target_group.app.arn
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix, the dimension value CloudWatch uses for target metrics."
  value       = aws_lb_target_group.app.arn_suffix
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling group running the application tier."
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "ID of the launch template. A new version is what triggers an instance refresh."
  value       = aws_launch_template.app.id
}

output "launch_template_latest_version" {
  description = "Latest launch template version number."
  value       = aws_launch_template.app.latest_version
}

output "instance_role_arn" {
  description = "ARN of the role attached to application instances."
  value       = aws_iam_role.instance.arn
}

output "app_log_group_name" {
  description = "CloudWatch log group receiving application and bootstrap logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "ami_id" {
  description = "Amazon Linux 2023 AMI the launch template was pinned to at apply time."

  # SSM parameter values are sensitive by default, since parameters commonly
  # hold secrets. This one is a public AWS-published AMI ID, so unwrapping it
  # is safe and lets the ID show up in plan output and terraform output where
  # it is genuinely useful for confirming which image a fleet is running.
  value = nonsensitive(data.aws_ssm_parameter.al2023_ami.value)
}
