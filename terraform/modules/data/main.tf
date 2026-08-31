# ---------------------------------------------------------------------------
# Data module
#
# The persistence tier: a DynamoDB product catalog plus the backup and
# recovery controls around it.
#
# DynamoDB was chosen over RDS deliberately. It has no instance to pay for
# when idle, no subnet group or failover topology to manage, and it is
# reached through a free VPC gateway endpoint rather than through the NAT
# Gateway. For a read-mostly catalog of a few dozen rows that is the right
# shape; ARCHITECTURE.md records the trade-off against a relational store.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "products" {
  #checkov:skip=CKV_AWS_119:a customer managed key is ~USD 1/month to protect a public product catalog; AWS-owned key applies
  name = "${var.name_prefix}-products"

  # On-demand rather than provisioned. The environment is torn down between
  # working sessions, so paying for reserved capacity around the clock would
  # be waste; on-demand costs nothing while no requests are served.
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "id"

  attribute {
    name = "id"
    type = "S"
  }

  # Point-in-time recovery gives a 35-day continuous restore window with a
  # ~5 minute RPO. This is the primary recovery control; the AWS Backup plan
  # below layers scheduled snapshots on top for longer retention.
  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  server_side_encryption {
    # AWS-owned key. A customer-managed KMS key would add ~USD 1/month plus
    # per-request charges for no benefit at this data sensitivity; SECURITY.md
    # records the reasoning.
    enabled = false
  }

  # Off so scripts/down.sh can tear the environment down cleanly. A production
  # table would set this to true.
  deletion_protection_enabled = var.enable_deletion_protection

  tags = {
    Name = "${var.name_prefix}-products"
    Tier = "data"
  }
}

# ---------------------------------------------------------------------------
# Seed catalog
#
# Managed as code so a freshly recreated environment comes up with a populated
# storefront and the demo needs no manual step.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table_item" "products" {
  for_each = { for product in var.seed_products : product.id => product }

  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    id       = { S = each.value.id }
    name     = { S = each.value.name }
    category = { S = each.value.category }
    price    = { N = tostring(each.value.price) }
    stock    = { N = tostring(each.value.stock) }
  })

  # Terraform only manages the seed rows. Items written by the application at
  # runtime are left alone rather than being reverted on the next apply.
  lifecycle {
    ignore_changes = [item]
  }
}

# ---------------------------------------------------------------------------
# AWS Backup
#
# Scheduled, immutable-by-retention snapshots held in a separate vault. This
# is the control that survives the failure PITR does not cover: an operator or
# pipeline deleting the table itself.
# ---------------------------------------------------------------------------

resource "aws_backup_vault" "this" {
  #checkov:skip=CKV_AWS_166:recovery points hold public catalog data and are encrypted with an AWS-managed key
  count = var.enable_backup_plan ? 1 : 0

  name = "${var.name_prefix}-backup-vault"

  # Force destroy so teardown does not leave an undeletable vault behind
  # between working sessions. A production vault would keep this false and add
  # a vault lock.
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}-backup-vault"
    Tier = "data"
  }
}

resource "aws_backup_plan" "this" {
  count = var.enable_backup_plan ? 1 : 0

  name = "${var.name_prefix}-backup-plan"

  rule {
    rule_name         = "daily-retain-${var.backup_retention_days}-days"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = var.backup_schedule

    # If a scheduled window is missed the job still runs, rather than silently
    # skipping a day.
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.backup_retention_days
    }

    recovery_point_tags = {
      Name = "${var.name_prefix}-daily"
    }
  }

  tags = {
    Name = "${var.name_prefix}-backup-plan"
  }
}

data "aws_iam_policy_document" "backup_assume" {
  count = var.enable_backup_plan ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count = var.enable_backup_plan ? 1 : 0

  name               = "${var.name_prefix}-backup-role"
  description        = "Assumed by AWS Backup to snapshot and restore the product catalog table."
  assume_role_policy = data.aws_iam_policy_document.backup_assume[0].json
}

# AWS-managed policies, scoped to the backup service role. Hand-rolling the
# equivalent permissions would be strictly worse: AWS updates these as the
# service adds resource types.
resource "aws_iam_role_policy_attachment" "backup" {
  count = var.enable_backup_plan ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  count = var.enable_backup_plan ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# Selection by explicit ARN rather than by tag. Tag-based selection silently
# stops protecting a resource the moment someone edits a tag.
resource "aws_backup_selection" "this" {
  count = var.enable_backup_plan ? 1 : 0

  name         = "${var.name_prefix}-catalog-selection"
  plan_id      = aws_backup_plan.this[0].id
  iam_role_arn = aws_iam_role.backup[0].arn

  resources = [aws_dynamodb_table.products.arn]
}
