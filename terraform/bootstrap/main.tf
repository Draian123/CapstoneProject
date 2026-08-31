# ---------------------------------------------------------------------------
# Bootstrap layer
#
# Applied ONCE, before any environment. Creates the two things every other
# layer depends on but cannot create for itself:
#
#   1. The S3 bucket holding Terraform remote state.
#   2. The GitHub OIDC trust relationship + CI roles, so GitHub Actions can
#      authenticate to AWS without any long-lived access keys stored as
#      repository secrets.
#
# Nothing here bills meaningfully (an empty versioned S3 bucket is fractions
# of a cent per month), so this layer is never torn down by scripts/down.sh.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are globally unique; suffixing with the account ID keeps this
  # reproducible in any account without hand-picking a name.
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  # OIDC subject claims. Plan runs from pull requests, apply only from main.
  sub_pull_request = "repo:${var.github_owner}/${var.github_repo}:pull_request"
  sub_main_branch  = "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"
}

# ---------------------------------------------------------------------------
# Remote state
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # State is the one thing we genuinely cannot rebuild. Refuse to destroy it
  # even if this layer is accidentally targeted by a destroy.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = local.state_bucket_name
  }
}

# Versioning is what makes state recoverable after a bad apply or a corrupt
# upload; it is also a prerequisite for S3-native state locking.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cost control: state files are small, but versioning means every apply keeps a
# copy forever. Expire non-current versions after 30 days.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# Reject any request that is not over TLS. Belt-and-braces alongside the
# default encryption rule above.
resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC federation
# ---------------------------------------------------------------------------

# Establishes the GitHub Actions token issuer as a trusted identity provider.
# With this in place, workflows exchange a short-lived GitHub-signed JWT for
# temporary AWS credentials -- there are no AWS keys in GitHub secrets at all.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.project_name}-github-oidc"
  }
}

data "aws_iam_policy_document" "gha_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Plan may run from a pull request or from main (drift detection).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.sub_pull_request, local.sub_main_branch]
    }
  }
}

data "aws_iam_policy_document" "gha_apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Apply is only ever reachable from the protected main branch. A pull
    # request, including one from a fork, cannot mint a token matching this
    # subject claim.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.sub_main_branch]
    }
  }
}

resource "aws_iam_role" "gha_plan" {
  name                 = "${var.project_name}-gha-plan"
  description          = "Read-only role assumed by GitHub Actions to run terraform plan on pull requests."
  assume_role_policy   = data.aws_iam_policy_document.gha_plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role" "gha_apply" {
  name                 = "${var.project_name}-gha-apply"
  description          = "Deploy role assumed by GitHub Actions to run terraform apply from main."
  assume_role_policy   = data.aws_iam_policy_document.gha_apply_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Both roles need to read state, and both need to take the S3-native lock
# while a plan or apply is in flight.
data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid    = "ReadWriteStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_policy" "state_access" {
  name        = "${var.project_name}-tfstate-access"
  description = "Read/write access to the Terraform remote state bucket, including S3-native lock files."
  policy      = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy_attachment" "gha_plan_state" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = aws_iam_policy.state_access.arn
}

resource "aws_iam_role_policy_attachment" "gha_apply_state" {
  role       = aws_iam_role.gha_apply.name
  policy_arn = aws_iam_policy.state_access.arn
}

resource "aws_iam_role_policy_attachment" "gha_apply_deploy" {
  role       = aws_iam_role.gha_apply.name
  policy_arn = aws_iam_policy.gha_deploy.arn
}
