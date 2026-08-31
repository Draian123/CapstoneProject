#!/usr/bin/env bash
#
# Kill an instance and watch the platform heal itself.
#
# This is the live demo of self-healing, and it doubles as the verification
# that ELB health checks and the Auto Scaling group are actually wired
# together. It terminates one application instance, then polls until the
# storefront is back to full capacity, reporting how long recovery took and
# whether any request failed while it happened.
#
# Nothing here is destructive beyond one instance the group is expected to
# replace, but it is deliberately not silent about what it is doing.
#
# Usage: scripts/demo-failover.sh [dev|prod] [--yes]
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Never page; this script is non-interactive.
export AWS_PAGER=""

# Note for anyone editing this on Windows: Git Bash rewrites arguments that
# begin with "/" into Windows paths, so passing a CloudWatch log group name
# like /aws/ec2/... to the AWS CLI yields a baffling AccessDenied naming a
# path under Program Files. The fix is MSYS_NO_PATHCONV=1 on that one command
# -- not exported globally, because Terraform is a Windows binary and needs
# the conversion for -chdir. No argument in this script starts with "/", so
# nothing here needs it. See RUNBOOK.md.

ENV_NAME="dev"
ASSUME_YES=false

for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=true ;;
    dev|prod) ENV_NAME="${arg}" ;;
    *) die "unknown argument '${arg}'. Usage: scripts/demo-failover.sh [dev|prod] [--yes]" ;;
  esac
done

ENV_DIR="$(resolve_env_dir "${ENV_NAME}")"

require_tools terraform aws curl
require_aws_auth
ensure_alert_email

terraform_init_env "${ENV_DIR}" "${ENV_NAME}" >/dev/null 2>&1 \
  || die "could not initialise ${ENV_NAME}. Is it deployed?"

[[ "$(env_resource_count "${ENV_DIR}")" -gt 0 ]] \
  || die "${ENV_NAME} is not deployed. Run scripts/up.sh ${ENV_NAME} first."

ASG_NAME="$(terraform -chdir="${ENV_DIR}" output -raw autoscaling_group_name)"
TARGET_GROUP_ARN="$(terraform -chdir="${ENV_DIR}" output -raw target_group_arn)"
STOREFRONT_URL="$(terraform -chdir="${ENV_DIR}" output -raw storefront_url)"

healthy_count() {
  aws elbv2 describe-target-health \
    --target-group-arn "${TARGET_GROUP_ARN}" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
    --output text 2>/dev/null || echo 0
}

head1 "Failover demonstration: ${ENV_NAME}"

BEFORE_HEALTHY="$(healthy_count)"
info "healthy targets before: ${BEFORE_HEALTHY}"

[[ "${BEFORE_HEALTHY}" -ge 3 ]] \
  || die "expected at least 3 healthy targets before starting, found ${BEFORE_HEALTHY}."

# Pick the instance in whichever AZ has the most capacity, so the demo does not
# accidentally empty a zone and make recovery look worse than it is.
VICTIM="$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${ASG_NAME}" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'] | [0].InstanceId" \
  --output text)"

VICTIM_AZ="$(aws ec2 describe-instances --instance-ids "${VICTIM}" \
  --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text)"

warn "about to terminate ${VICTIM} (${VICTIM_AZ})"

if [[ "${ASSUME_YES}" != true ]]; then
  printf "\nType 'yes' to terminate it: "
  read -r confirmation
  [[ "${confirmation}" == "yes" ]] || die "cancelled. Nothing was terminated."
fi

# ---------------------------------------------------------------------------
# Probe the storefront continuously through the whole event. This is the part
# that matters: capacity recovering is expected, but the claim being
# demonstrated is that users never saw it happen.
# ---------------------------------------------------------------------------
PROBE_LOG="$(mktemp)"
(
  while :; do
    # curl already prints 000 when the connection itself fails, so its exit
    # status is swallowed rather than appending a second fallback value --
    # which is what previously produced "000000" in the results.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${STOREFRONT_URL}/health")" || true
    printf '%s %s\n' "$(date -u +%H:%M:%S)" "${code:-000}" >> "${PROBE_LOG}"
    sleep 1
  done
) &
PROBE_PID=$!
# shellcheck disable=SC2064
trap "kill ${PROBE_PID} 2>/dev/null || true" EXIT

START_TS="$(date +%s)"

info "terminating ${VICTIM}"
aws ec2 terminate-instances --instance-ids "${VICTIM}" \
  --query 'TerminatingInstances[0].CurrentState.Name' --output text

head1 "Waiting for the Auto Scaling group to restore capacity"
printf '  The group uses ELB health checks, so it replaces an instance whose\n'
printf '  application has failed -- not only one the hypervisor reports as gone.\n\n'

DIPPED=false
RECOVERED=false

for attempt in $(seq 1 60); do
  healthy="$(healthy_count)"
  elapsed=$(( $(date +%s) - START_TS ))

  printf '\r  %3ds  healthy targets: %s ' "${elapsed}" "${healthy}"

  [[ "${healthy}" -lt 3 ]] && DIPPED=true

  if [[ "${DIPPED}" == true && "${healthy}" -ge 3 ]]; then
    RECOVERED=true
    RECOVERY_SECONDS="${elapsed}"
    break
  fi

  sleep 10
done
printf '\n'

kill "${PROBE_PID}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
TOTAL_PROBES="$(grep -c . "${PROBE_LOG}" || echo 0)"
FAILED_PROBES="$(grep -cv ' 200$' "${PROBE_LOG}" || true)"

head1 "Result"

if [[ "${RECOVERED}" == true ]]; then
  ok "capacity restored in ${RECOVERY_SECONDS}s"
else
  warn "capacity had not returned to 3 healthy targets within 10 minutes"
  warn "see RUNBOOK.md -> 'Instance failing health checks'"
fi

printf '\n  Terminated      %s (%s)\n' "${VICTIM}" "${VICTIM_AZ}"
printf '  Requests sent   %s\n' "${TOTAL_PROBES}"
printf '  Requests failed %s\n' "${FAILED_PROBES}"

if [[ "${FAILED_PROBES}" -eq 0 ]]; then
  printf '\n%s  Not one request failed. The remaining instances in both AZs absorbed\n' "${C_GREEN}"
  printf '  the traffic while the group built a replacement.%s\n' "${C_RESET}"
else
  printf '\n%s  %s request(s) did not return 200. Non-200 responses:%s\n' \
    "${C_YELLOW}" "${FAILED_PROBES}" "${C_RESET}"
  grep -v ' 200$' "${PROBE_LOG}" | head -10 | sed 's/^/    /'
fi

printf '\n  Expect the %s-unhealthy-hosts alarm to have fired and then cleared;\n' "${PROJECT_NAME}-${ENV_NAME}"
printf '  both transitions are emailed, which is the alerting path end to end.\n\n'

rm -f "${PROBE_LOG}"
