#!/usr/bin/env bash
#
# One-time setup. Creates the Terraform remote state bucket and the GitHub
# Actions OIDC roles, then migrates its own state into the bucket it just
# created so nothing important lives only on this laptop.
#
# Safe to re-run: Terraform reconciles, and the state migration is skipped once
# the backend is already configured.
#
# Usage: scripts/bootstrap.sh
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform aws
require_aws_auth

ACCOUNT_ID="$(aws_account_id)"
BUCKET="$(state_bucket_name)"

head1 "Bootstrap: shared state and CI identity"
info "account ${ACCOUNT_ID}, region ${AWS_REGION_DEFAULT}"
info "state bucket ${BUCKET}"

cd "${BOOTSTRAP_DIR}"

# Step 1: apply with whatever backend is currently configured. On a first run
# that is the local backend, because the S3 bucket does not exist yet.
info "initialising bootstrap layer"
terraform init -input=false

info "applying bootstrap layer"
terraform apply -input=false -auto-approve

# Step 2: now the bucket exists, move this layer's own state into it. Without
# this, losing the laptop would mean losing the ability to manage the state
# bucket and the CI roles.
if [[ ! -f backend.tf ]]; then
  head1 "Migrating bootstrap state into S3"

  cat > backend.tf <<TFBACKEND
# Written by scripts/bootstrap.sh after the state bucket was created.
#
# The bootstrap layer starts on the local backend -- it cannot use a bucket
# that does not exist yet -- and moves here on first run. From then on the
# bucket manages itself.
terraform {
  backend "s3" {
    bucket       = "${BUCKET}"
    key          = "${PROJECT_NAME}/bootstrap/terraform.tfstate"
    region       = "${AWS_REGION_DEFAULT}"
    encrypt      = true
    use_lockfile = true
  }
}
TFBACKEND

  terraform init -input=false -migrate-state -force-copy
  ok "bootstrap state now lives in s3://${BUCKET}/${PROJECT_NAME}/bootstrap/"
else
  ok "bootstrap state already remote"
fi

PLAN_ROLE="$(terraform output -raw gha_plan_role_arn)"
APPLY_ROLE="$(terraform output -raw gha_apply_role_arn)"

head1 "Bootstrap complete"
cat <<SUMMARY

  State bucket   ${BUCKET}
  Plan role      ${PLAN_ROLE}
  Apply role     ${APPLY_ROLE}

Next steps:

  1. Add these as GitHub Actions *repository variables* (Settings ->
     Secrets and variables -> Actions -> Variables). They are role ARNs, not
     credentials, so variables are the right home -- there is no secret here.

       AWS_PLAN_ROLE_ARN   = ${PLAN_ROLE}
       AWS_APPLY_ROLE_ARN  = ${APPLY_ROLE}

  2. Bring the dev environment up:

       scripts/up.sh dev

SUMMARY
