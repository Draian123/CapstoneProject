# ---------------------------------------------------------------------------
# Compute module
#
# The request-serving tier:
#
#   internet -> ALB (public subnets) -> target group -> ASG (private subnets)
#
# Instances are cattle. There is no SSH key pair anywhere in this module and
# no inbound port 22 rule; operator access is through SSM Session Manager,
# which is audited in CloudTrail and needs no bastion host.
# ---------------------------------------------------------------------------

data "aws_region" "current" {}

# Resolved from the SSM public parameter rather than pinned, so instances are
# always launched on a patched AMI. The launch template records whichever ID
# was current at apply time, which keeps the rollout deterministic within a
# single deployment.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-${var.instance_architecture}"
}

locals {
  app_log_group = "/aws/ec2/${var.name_prefix}/app"

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    app_payload_b64    = base64gzip(file(var.app_source_path))
    app_port           = var.app_port
    aws_region         = data.aws_region.current.region
    products_table     = var.products_table_name
    environment        = var.environment
    app_log_group      = local.app_log_group
    log_dir            = "/var/log/ce-capstone"
    log_retention_days = var.log_retention_days
    metrics_namespace  = var.metrics_namespace
  })
}

# ---------------------------------------------------------------------------
# Application log group
#
# Created here rather than left to the CloudWatch agent so that retention is
# enforced by Terraform. An agent-created group defaults to never expire,
# which is a slow-growing bill nobody notices.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = local.app_log_group
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.name_prefix}-app-logs"
    Tier = "app"
  }
}

# ---------------------------------------------------------------------------
# Instance role
#
# Three grants, nothing more: write telemetry, be managed by SSM, read the one
# catalog table. There are no credentials on disk; the SDK and CLI pick up
# short-lived role credentials from the instance metadata service.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "instance_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-app-instance-role"
  description        = "Role assumed by storefront instances: CloudWatch telemetry, SSM management, read-only catalog access."
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json

  tags = {
    Name = "${var.name_prefix}-app-instance-role"
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Enables Session Manager. This is what makes it possible to have no SSH
# ingress rule, no key pair and no bastion host.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read-only, and only on the catalog table. The storefront never writes, so it
# is not granted PutItem, UpdateItem or DeleteItem.
data "aws_iam_policy_document" "catalog_read" {
  statement {
    sid    = "ReadProductCatalog"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:DescribeTable",
    ]

    resources = [var.products_table_arn]
  }
}

resource "aws_iam_policy" "catalog_read" {
  name        = "${var.name_prefix}-catalog-read"
  description = "Read-only access to the product catalog table, scoped to that single table."
  policy      = data.aws_iam_policy_document.catalog_read.json
}

resource "aws_iam_role_policy_attachment" "catalog_read" {
  role       = aws_iam_role.instance.name
  policy_arn = aws_iam_policy.catalog_read.arn
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-app-instance-profile"
  role = aws_iam_role.instance.name

  tags = {
    Name = "${var.name_prefix}-app-instance-profile"
  }
}

# ---------------------------------------------------------------------------
# Load balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # Reject requests with malformed headers instead of forwarding them, which
  # closes off request-smuggling and header-injection tricks against the app.
  drop_invalid_header_fields = true

  # Off so scripts/down.sh can tear the environment down between working
  # sessions. A production listener would set this to true.
  enable_deletion_protection = var.enable_deletion_protection

  idle_timeout = 60

  tags = {
    Name = "${var.name_prefix}-alb"
    Tier = "public"
  }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # Drain in 30s rather than the 300s default. Scale-in and instance refresh
  # complete quickly, which matters when the environment is recreated often.
  deregistration_delay = 30

  health_check {
    enabled = true
    path    = var.health_check_path

    # Two consecutive passes to enter service, three failures to leave it:
    # quick to recover, slow to flap.
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
    protocol            = "HTTP"
  }

  tags = {
    Name = "${var.name_prefix}-tg"
    Tier = "app"
  }

  # The listener references this target group, so a replacement has to exist
  # before the old one is removed.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Name = "${var.name_prefix}-http-listener"
  }
}

# ---------------------------------------------------------------------------
# Launch template
# ---------------------------------------------------------------------------

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-app-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  # No key_name. There is no SSH path into these instances by design.

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [var.app_security_group_id]

  user_data = base64encode(local.user_data)

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.root_volume_size_gb

      # gp3 is roughly 20% cheaper per GB than gp2 and decouples IOPS from
      # volume size, so a small root volume still gets 3000 baseline IOPS.
      volume_type = "gp3"

      # Encryption at rest is not optional here; the account has EBS default
      # encryption expectations and this makes it explicit in code.
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"

    # IMDSv2 only. Blocks the server-side request forgery path that turns an
    # application bug into stolen instance-role credentials.
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    # Basic 5-minute monitoring. Detailed monitoring is roughly USD 2.10 per
    # instance per month for 1-minute granularity that this workload does not
    # need; the CloudWatch agent already reports memory at 60s.
    enabled = var.enable_detailed_monitoring
  }

  # Tags applied to the instances and volumes the ASG launches from this
  # template. Provider default_tags do not reach them, so cost allocation
  # would otherwise have a hole exactly where the spend is.
  tag_specifications {
    resource_type = "instance"

    tags = merge(var.tags, {
      Name = "${var.name_prefix}-app"
      Tier = "app"
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(var.tags, {
      Name = "${var.name_prefix}-app-root"
      Tier = "app"
    })
  }

  tags = {
    Name = "${var.name_prefix}-app-lt"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Auto Scaling group
# ---------------------------------------------------------------------------

resource "aws_autoscaling_group" "app" {
  name_prefix = "${var.name_prefix}-asg-"

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.app.arn]

  # ELB health, not EC2 health. EC2 health only notices a stopped instance;
  # ELB health also replaces an instance whose process is wedged but whose
  # hypervisor is fine.
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period

  # Keeps capacity even across AZs, so losing one zone loses a predictable
  # fraction of the fleet rather than an arbitrary one.
  availability_zone_distribution {
    capacity_distribution_strategy = "balanced-best-effort"
  }

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Rolling replacement whenever the launch template changes, which is how an
  # application update ships. Holding 66% healthy means at least two of three
  # instances serve throughout, so a deploy is not visible to users.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 66
      instance_warmup        = var.health_check_grace_period
      auto_rollback          = true
    }

    triggers = ["launch_template", "desired_capacity"]
  }

  # Wait for instances to pass the ELB health check before apply returns.
  # Without this, apply succeeds while the storefront is still 503-ing.
  wait_for_capacity_timeout = "10m"
  min_elb_capacity          = var.min_size

  dynamic "tag" {
    for_each = merge(var.tags, {
      Name = "${var.name_prefix}-app"
      Tier = "app"
    })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Target tracking rather than step scaling: AWS manages the alarm thresholds
# and the scale-in cooldown, and the intent -- "hold average CPU near 50%" --
# is stated directly instead of being encoded in four alarm definitions.
resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${var.name_prefix}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  estimated_instance_warmup = var.health_check_grace_period

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = var.cpu_target_utilization
  }
}
