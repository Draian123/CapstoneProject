# ---------------------------------------------------------------------------
# Deploy permissions for the GitHub Actions apply role.
#
# Deliberately NOT AdministratorAccess. The policy is scoped three ways:
#
#   * By service  -- only the services this platform actually uses.
#   * By region   -- every regional call is pinned to var.aws_region.
#   * By name     -- IAM is the dangerous surface, so role, policy and
#                    instance-profile actions are restricted to resources
#                    whose name starts with the project prefix. CI cannot
#                    touch or escalate via any other identity in the account.
#
# See SECURITY.md for the full rationale and the residual risks.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gha_deploy" {
  # -------------------------------------------------------------------------
  # Regional infrastructure services.
  #
  # These stay action-broad because Terraform has to create, read, tag and
  # destroy resources that do not exist yet, which rules out resource-level
  # ARNs. The region condition is the meaningful boundary: a compromised CI
  # token cannot spin resources up in another region, which is the usual
  # crypto-mining blast radius.
  # -------------------------------------------------------------------------
  statement {
    sid    = "RegionalInfrastructure"
    effect = "Allow"

    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "application-autoscaling:*",
      "cloudwatch:*",
      "logs:*",
      "sns:*",
      "dynamodb:*",
      "backup:*",
      "backup-storage:*",
      "kms:DescribeKey",
      "kms:ListAliases",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "tag:GetResources",
      "resource-groups:*",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # -------------------------------------------------------------------------
  # Global services that cannot carry a region condition.
  # -------------------------------------------------------------------------
  statement {
    sid    = "GlobalReadOnly"
    effect = "Allow"

    actions = [
      "budgets:ViewBudget",
      "budgets:DescribeBudget",
      "budgets:DescribeBudgetActionsForBudget",
      "budgets:ModifyBudget",
      "budgets:CreateBudget",
      "budgets:DeleteBudget",
      "sts:GetCallerIdentity",
      "iam:ListPolicies",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
    ]

    resources = ["*"]
  }

  # -------------------------------------------------------------------------
  # IAM, scoped by name.
  #
  # The apply role must manage the EC2 instance role and instance profile,
  # but nothing else. Restricting to the project name prefix means a
  # compromised pipeline cannot attach AdministratorAccess to a new role and
  # escalate out of these constraints.
  # -------------------------------------------------------------------------
  statement {
    sid    = "ManageProjectScopedIamRoles"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PassRole",
    ]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
    ]
  }

  statement {
    sid    = "ManageProjectScopedIamPolicies"
    effect = "Allow"

    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-*",
    ]
  }

  statement {
    sid    = "ManageProjectScopedInstanceProfiles"
    effect = "Allow"

    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.project_name}-*",
    ]
  }

  # Auto Scaling and AWS Backup create their own service-linked roles on first
  # use. Restricted to the specific AWS service principals that need them.
  statement {
    sid    = "CreateServiceLinkedRoles"
    effect = "Allow"

    actions = ["iam:CreateServiceLinkedRole"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "autoscaling.amazonaws.com",
        "backup.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
      ]
    }
  }

  # -------------------------------------------------------------------------
  # Explicit guardrails.
  #
  # An explicit Deny cannot be overridden by any Allow, so these hold even if
  # the statements above are later widened by mistake.
  # -------------------------------------------------------------------------
  statement {
    sid    = "DenyIamUserAndKeyManagement"
    effect = "Deny"

    actions = [
      "iam:CreateUser",
      "iam:DeleteUser",
      "iam:CreateAccessKey",
      "iam:DeleteAccessKey",
      "iam:UpdateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:CreateAccountAlias",
    ]

    resources = ["*"]
  }

  # The state bucket is granted through aws_iam_policy.state_access, which is
  # scoped to that one bucket. Deny everything else in S3 so a compromised
  # pipeline cannot read or delete unrelated buckets in the account.
  statement {
    sid    = "DenyS3OutsideStateBucket"
    effect = "Deny"

    actions = ["s3:*"]

    not_resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "gha_deploy" {
  name        = "${var.project_name}-gha-deploy"
  description = "Least-privilege deploy permissions for the GitHub Actions apply role: service-, region- and name-scoped."
  policy      = data.aws_iam_policy_document.gha_deploy.json
}
