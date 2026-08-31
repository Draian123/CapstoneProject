# ---------------------------------------------------------------------------
# Networking module
#
# Builds the network foundation the platform runs on:
#
#   * A VPC spanning az_count availability zones.
#   * A public tier holding the load balancer and the NAT Gateway.
#   * A private tier holding the application instances, with no route from the
#     internet inwards.
#   * Security groups chained so each tier only accepts traffic from the tier
#     directly in front of it.
#   * A DynamoDB gateway endpoint, so data-tier traffic never leaves the VPC
#     and never touches the NAT Gateway.
#
# Subnet CIDRs are derived from vpc_cidr with cidrsubnet() rather than being
# listed by hand, so the module works unchanged for any VPC size or AZ count.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 -> /24s. Public subnets take the first block of indices, private
  # subnets the next, which keeps the two ranges visually distinct in the
  # console (10.0.0.x/10.0.1.x public, 10.0.10.x/10.0.11.x private).
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]

  nat_gateway_count = var.single_nat_gateway ? 1 : var.az_count
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Required for the DynamoDB gateway endpoint and for instances to resolve
  # AWS service endpoints privately.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
    Tier = "network"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# The default security group is created by AWS and allows all traffic between
# its members. Nothing is placed in it, but stripping its rules removes an
# accidental-attachment footgun and satisfies CIS 5.3 / checkov CKV2_AWS_12.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-do-not-use"
  }
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Instances are never launched directly into public subnets -- only the ALB
  # and NAT Gateway live here -- so auto-assignment stays off.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# ---------------------------------------------------------------------------
# NAT Gateway
#
# Provides outbound-only internet access for the private tier: package
# installs at boot and CloudWatch agent telemetry. Nothing on the internet can
# initiate a connection back through it.
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
    Tier = "public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ even when sharing a single NAT Gateway. The
# tables are cheap, and keeping them per-AZ means switching
# single_nat_gateway to false later is a pure variable change with no
# resource restructuring.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-private-rt-${local.azs[count.index]}"
    Tier = "private"
  }
}

resource "aws_route" "private_nat" {
  count = var.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# DynamoDB gateway endpoint
#
# Gateway endpoints are free and route DynamoDB traffic over the AWS network
# rather than out through the NAT Gateway. That removes both the per-GB NAT
# processing charge and the internet exposure for all data-tier calls.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-dynamodb-endpoint"
  }
}

# ---------------------------------------------------------------------------
# Security groups
#
# Chained rather than flat: the internet may reach the ALB, only the ALB may
# reach the application, and the application may only make outbound HTTPS
# calls. Rules are declared as standalone resources so the intent of each one
# can carry its own description.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Public entry point. Accepts HTTP from the internet and forwards to the application tier."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-alb-sg"
    Tier = "public"
  }

  # The ALB is referenced by the compute module; replacing it in place avoids
  # a dependency-ordering failure on update.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the public internet to the storefront."
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"

  tags = {
    Name = "${var.name_prefix}-alb-ingress-http"
  }
}

# Egress is restricted to the application security group, not left open. A
# compromised load balancer cannot be used to reach anything else.
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward requests to the application tier only."
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"

  tags = {
    Name = "${var.name_prefix}-alb-egress-app"
  }
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Application tier. Accepts traffic only from the load balancer; no direct internet ingress."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-app-sg"
    Tier = "private"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Source is the ALB security group, not a CIDR. The rule stays correct no
# matter how the ALB nodes are re-addressed.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Application port, reachable only from the load balancer."
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"

  tags = {
    Name = "${var.name_prefix}-app-ingress-alb"
  }
}

# Outbound HTTPS only. Needed for dnf package installs at boot, the CloudWatch
# agent, and the DynamoDB endpoint. Plain HTTP egress is deliberately absent.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound HTTPS for package installation, CloudWatch telemetry and DynamoDB."
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = {
    Name = "${var.name_prefix}-app-egress-https"
  }
}

# ---------------------------------------------------------------------------
# VPC flow logs
#
# Records accepted and rejected connections for incident investigation. The
# retention window is short by design: this is a demonstration environment and
# CloudWatch Logs ingestion is charged per GB.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = {
    Name = "${var.name_prefix}-flow-logs"
  }
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name_prefix}-flow-logs-role"
  description        = "Allows the VPC flow logs service to write into this VPC log group only."
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${var.name_prefix}-flow-logs-policy"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.flow_logs.arn
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn

  tags = {
    Name = "${var.name_prefix}-flow-log"
  }
}
