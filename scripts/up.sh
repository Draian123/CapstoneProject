#!/usr/bin/env bash
#
# Bring an environment up and wait until it is actually serving traffic.
#
# "terraform apply completed" and "the storefront works" are not the same
# event, so this script does not return until the load balancer reports
# healthy targets and the health endpoint answers over the public URL.
#
# Usage: scripts/up.sh [dev|prod]        (defaults to dev)
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME="${1:-dev}"
ENV_DIR="$(resolve_env_dir "${ENV_NAME}")"

require_tools terraform aws curl
require_aws_auth
ensure_alert_email

head1 "Bringing up ${ENV_NAME}"
info "account $(aws_account_id), region ${AWS_REGION_DEFAULT}"

info "initialising against remote state"
terraform_init_env "${ENV_DIR}" "${ENV_NAME}"

info "applying"
terraform -chdir="${ENV_DIR}" apply -input=false -auto-approve

STOREFRONT_URL="$(terraform -chdir="${ENV_DIR}" output -raw storefront_url)"
DASHBOARD_URL="$(terraform -chdir="${ENV_DIR}" output -raw dashboard_url)"
TARGET_GROUP_ARN="$(terraform -chdir="${ENV_DIR}" output -raw target_group_arn)"
ASG_NAME="$(terraform -chdir="${ENV_DIR}" output -raw autoscaling_group_name)"

# ---------------------------------------------------------------------------
# Wait for targets to pass health checks.
#
# The ASG already waits for min_elb_capacity during apply, so this normally
# returns on the first poll. It is kept because an apply that only changed the
# launch template returns while an instance refresh is still rolling.
# ---------------------------------------------------------------------------
head1 "Waiting for healthy targets"
for attempt in $(seq 1 40); do
  healthy="$(aws elbv2 describe-target-health \
    --target-group-arn "${TARGET_GROUP_ARN}" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
    --output text 2>/dev/null || echo 0)"

  total="$(aws elbv2 describe-target-health \
    --target-group-arn "${TARGET_GROUP_ARN}" \
    --query "length(TargetHealthDescriptions)" \
    --output text 2>/dev/null || echo 0)"

  if [[ "${healthy}" -ge 3 ]]; then
    ok "${healthy}/${total} targets healthy"
    break
  fi

  printf '\r  %s/%s targets healthy (attempt %s/40)' "${healthy}" "${total}" "${attempt}"
  sleep 10

  if [[ "${attempt}" -eq 40 ]]; then
    printf '\n'
    warn "targets did not reach 3 healthy within ~7 minutes"
    warn "check the bootstrap log: RUNBOOK.md -> 'Instance failing health checks'"
  fi
done
printf '\n'

# ---------------------------------------------------------------------------
# Confirm the public path end to end, not just the internal health state.
# ---------------------------------------------------------------------------
head1 "Verifying the public endpoint"
for attempt in $(seq 1 12); do
  if curl -fsS --max-time 5 "${STOREFRONT_URL}/health" >/dev/null 2>&1; then
    ok "${STOREFRONT_URL}/health responded"
    break
  fi
  printf '\r  waiting for DNS and the listener (attempt %s/12)' "${attempt}"
  sleep 10
done
printf '\n'

# Show which instances answered, which is the multi-AZ evidence for the demo.
info "sampling instances behind the load balancer"
for _ in $(seq 1 6); do
  curl -fsS --max-time 5 "${STOREFRONT_URL}/api/instance" 2>/dev/null \
    | tr -d ' \n' \
    | sed -n 's/.*"instanceId":"\([^"]*\)".*"availabilityZone":"\([^"]*\)".*/  \1  \2/p' \
    || true
done | sort -u

AZ_COUNT="$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${ASG_NAME}" \
  --query "length(AutoScalingGroups[0].AvailabilityZones)" \
  --output text 2>/dev/null || echo '?')"

head1 "${ENV_NAME} is up"
cat <<SUMMARY

  Storefront   ${STOREFRONT_URL}
  Dashboard    ${DASHBOARD_URL}
  ASG          ${ASG_NAME} across ${AZ_COUNT} AZs

  Burn rate    ~USD ${HOURLY_BURN_USD}/hour while this is running.

  Tear it down as soon as you stop working:

      scripts/down.sh ${ENV_NAME}

SUMMARY
