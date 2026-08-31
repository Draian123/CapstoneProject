#!/usr/bin/env bash
#
# Answer the two questions that matter between working sessions:
#
#   1. Is anything still running?
#   2. What has this project cost so far this month?
#
# Read-only. Safe to run at any time.
#
# Usage: scripts/status.sh [dev|prod|all]        (defaults to all)
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET="${1:-all}"
case "${TARGET}" in
  dev|prod) ENVIRONMENTS=("${TARGET}") ;;
  all)      ENVIRONMENTS=("dev" "prod") ;;
  *)        die "unknown argument '${TARGET}'. Usage: scripts/status.sh [dev|prod|all]" ;;
esac

require_tools terraform aws
require_aws_auth

ACCOUNT_ID="$(aws_account_id)"
BUCKET="$(state_bucket_name)"

head1 "ce-capstone status"
printf '  Account       %s\n' "${ACCOUNT_ID}"
printf '  Region        %s\n' "${AWS_REGION_DEFAULT}"

if aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
  printf '  State bucket  %s %s(present)%s\n' "${BUCKET}" "${C_GREEN}" "${C_RESET}"
else
  printf '  State bucket  %s %s(missing -- run scripts/bootstrap.sh)%s\n' "${BUCKET}" "${C_RED}" "${C_RESET}"
  exit 1
fi

TOTAL_RUNNING=0

for env_name in "${ENVIRONMENTS[@]}"; do
  env_dir="${ENVIRONMENTS_DIR}/${env_name}"
  [[ -d "${env_dir}" ]] || continue

  head1 "Environment: ${env_name}"

  # Init quietly. A missing state object is a normal "never deployed" state,
  # not an error worth printing a stack trace for.
  if ! terraform_init_env "${env_dir}" "${env_name}" >/dev/null 2>&1; then
    printf '  %sunavailable%s  could not initialise backend\n' "${C_YELLOW}" "${C_RESET}"
    continue
  fi

  count="$(env_resource_count "${env_dir}")"

  if [[ "${count}" -eq 0 ]]; then
    printf '  %sDOWN%s  no resources in state -- this environment is not billing\n' "${C_GREEN}" "${C_RESET}"
    continue
  fi

  TOTAL_RUNNING=$((TOTAL_RUNNING + 1))
  printf '  %sUP%s    %s resources in state\n\n' "${C_YELLOW}" "${C_RESET}" "${count}"

  storefront="$(terraform -chdir="${env_dir}" output -raw storefront_url 2>/dev/null || echo 'n/a')"
  asg="$(terraform -chdir="${env_dir}" output -raw autoscaling_group_name 2>/dev/null || echo '')"
  tg="$(terraform -chdir="${env_dir}" output -raw target_group_arn 2>/dev/null || echo '')"

  printf '  Storefront    %s\n' "${storefront}"

  if [[ -n "${asg}" ]]; then
    in_service="$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "${asg}" \
      --query "length(AutoScalingGroups[0].Instances[?LifecycleState=='InService'])" \
      --output text 2>/dev/null || echo '?')"
    printf '  Instances     %s in service\n' "${in_service}"
  fi

  if [[ -n "${tg}" ]]; then
    healthy="$(aws elbv2 describe-target-health --target-group-arn "${tg}" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
      --output text 2>/dev/null || echo '?')"
    printf '  Healthy       %s targets\n' "${healthy}"
  fi

  # The two resources that bill whether or not anyone is using the site.
  nat_count="$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:Environment,Values=${env_name}" "Name=state,Values=available" \
    --query 'length(NatGateways)' --output text 2>/dev/null || echo '?')"
  printf '  NAT gateways  %s %s(~USD 0.045/hr each)%s\n' "${nat_count}" "${C_YELLOW}" "${C_RESET}"

  alarms_in_alarm="$(aws cloudwatch describe-alarms \
    --alarm-name-prefix "${PROJECT_NAME}-${env_name}" \
    --state-value ALARM \
    --query 'length(MetricAlarms)' --output text 2>/dev/null || echo '?')"
  printf '  Alarms firing %s\n' "${alarms_in_alarm}"

  printf '\n  %sBurn rate     ~USD %s/hour -- run scripts/down.sh %s when finished%s\n' \
    "${C_YELLOW}" "${HOURLY_BURN_USD}" "${env_name}" "${C_RESET}"
done

# ---------------------------------------------------------------------------
# Month-to-date spend.
#
# Filtered by the Project cost allocation tag, so this reflects this workload
# rather than everything in the account. The tag has to be activated once in
# Billing -> Cost allocation tags before it can be filtered on; until then the
# query returns nothing and the unfiltered total is shown instead.
# ---------------------------------------------------------------------------
head1 "Month-to-date cost"

MONTH_START="$(date -u +%Y-%m-01)"
TOMORROW="$(date -u -d '+1 day' +%Y-%m-%d 2>/dev/null || date -u -v+1d +%Y-%m-%d)"

tagged_cost="$(aws ce get-cost-and-usage \
  --time-period "Start=${MONTH_START},End=${TOMORROW}" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter "{\"Tags\":{\"Key\":\"Project\",\"Values\":[\"${PROJECT_NAME}\"]}}" \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' \
  --output text 2>/dev/null || echo '')"

account_cost="$(aws ce get-cost-and-usage \
  --time-period "Start=${MONTH_START},End=${TOMORROW}" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' \
  --output text 2>/dev/null || echo '')"

if [[ -n "${tagged_cost}" && "${tagged_cost}" != "None" ]]; then
  printf '  Project (tag Project=%s)  USD %.2f\n' "${PROJECT_NAME}" "${tagged_cost}"
else
  printf '  %sProject-tagged cost unavailable.%s Activate the Project cost allocation\n' "${C_YELLOW}" "${C_RESET}"
  printf '  tag in Billing -> Cost allocation tags; it backfills within ~24h.\n'
fi

if [[ -n "${account_cost}" && "${account_cost}" != "None" ]]; then
  printf '  Whole account             USD %.2f\n' "${account_cost}"
fi

printf '  Period                    %s to today\n' "${MONTH_START}"

if [[ "${TOTAL_RUNNING}" -gt 0 ]]; then
  printf '\n%s%s environment(s) currently running and billing.%s\n' \
    "${C_YELLOW}" "${TOTAL_RUNNING}" "${C_RESET}"
else
  printf '\n%sNothing is running. Only the state bucket remains, at effectively zero cost.%s\n' \
    "${C_GREEN}" "${C_RESET}"
fi
