#!/usr/bin/env bash
# Shared helpers for the lifecycle scripts. Sourced, not executed.

set -euo pipefail

PROJECT_NAME="ce-capstone"
AWS_REGION_DEFAULT="us-east-1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="${REPO_ROOT}/terraform/bootstrap"
ENVIRONMENTS_DIR="${REPO_ROOT}/terraform/environments"

# Hourly cost of the billable resources in one environment, used by status.sh
# and up.sh to keep the running cost visible. Kept in sync with COSTS.md.
HOURLY_BURN_USD="0.096"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info()  { printf '%s==>%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()    { printf '%s  ok%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()  { printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()   { printf '%serr %s %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; exit 1; }
head1() { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found on PATH: ${tool}"
  done
}

# Fail early and loudly rather than half-way through an apply.
require_aws_auth() {
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS credentials are not valid. Run 'aws configure' or refresh your session."
}

aws_account_id() {
  aws sts get-caller-identity --query Account --output text
}

# Environments are a closed set; reject typos before they reach Terraform.
resolve_env_dir() {
  local env="${1:-}"
  [[ -n "${env}" ]] || die "usage: $(basename "$0") <dev|prod>"
  case "${env}" in
    dev|prod) ;;
    *) die "unknown environment '${env}'. Expected 'dev' or 'prod'." ;;
  esac
  local dir="${ENVIRONMENTS_DIR}/${env}"
  [[ -d "${dir}" ]] || die "environment directory not found: ${dir}"
  printf '%s' "${dir}"
}

state_bucket_name() {
  printf '%s-tfstate-%s' "${PROJECT_NAME}" "$(aws_account_id)"
}

# The alert email is intentionally not committed (the repo is public), so it is
# supplied at apply time. Prefer an already-exported TF_VAR_alert_email, then a
# gitignored local file, and otherwise prompt once.
ensure_alert_email() {
  if [[ -n "${TF_VAR_alert_email:-}" ]]; then
    return 0
  fi

  local email_file="${REPO_ROOT}/.alert-email"
  if [[ -f "${email_file}" ]]; then
    TF_VAR_alert_email="$(tr -d '[:space:]' < "${email_file}")"
    export TF_VAR_alert_email
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "alert email not set. Export TF_VAR_alert_email or create ${email_file}."
  fi

  printf 'Email address for CloudWatch alarm notifications: '
  local entered
  read -r entered
  [[ -n "${entered}" ]] || die "an alert email is required."
  printf '%s\n' "${entered}" > "${email_file}"
  TF_VAR_alert_email="${entered}"
  export TF_VAR_alert_email
  ok "saved to ${email_file} (gitignored) so you are not asked again"
}

# Initialise an environment against the shared remote state bucket. The bucket
# name is resolved at runtime rather than hardcoded, so the repo is portable to
# any AWS account.
terraform_init_env() {
  local dir="$1" env="$2"
  local bucket
  bucket="$(state_bucket_name)"

  aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1 \
    || die "remote state bucket '${bucket}' does not exist. Run scripts/bootstrap.sh first."

  terraform -chdir="${dir}" init \
    -input=false \
    -reconfigure \
    -backend-config="bucket=${bucket}" \
    -backend-config="key=${PROJECT_NAME}/${env}/terraform.tfstate" \
    -backend-config="region=${AWS_REGION_DEFAULT}"
}

# Number of resources currently tracked in state. 0 means the environment is
# torn down and therefore not billing.
env_resource_count() {
  local dir="$1"
  terraform -chdir="${dir}" state list 2>/dev/null | grep -c . || true
}
