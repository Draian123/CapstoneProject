output "vpc_id" {
  description = "ID of the VPC hosting the platform."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "Availability zones the platform spans."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs, one per AZ. Hosts the load balancer and NAT Gateway."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, one per AZ. Hosts the application instances."
  value       = aws_subnet.private[*].id
}

output "public_subnet_cidrs" {
  description = "CIDR blocks of the public subnets."
  value       = local.public_subnet_cidrs
}

output "private_subnet_cidrs" {
  description = "CIDR blocks of the private subnets."
  value       = local.private_subnet_cidrs
}

output "alb_security_group_id" {
  description = "Security group attached to the load balancer."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security group attached to the application instances."
  value       = aws_security_group.app.id
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs. A single-element list when single_nat_gateway is true."
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_public_ips" {
  description = "Public IPs the private tier egresses from. Useful for allow-listing with third parties."
  value       = aws_eip.nat[*].public_ip
}

output "dynamodb_vpc_endpoint_id" {
  description = "Gateway endpoint keeping DynamoDB traffic inside the VPC."
  value       = aws_vpc_endpoint.dynamodb.id
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
