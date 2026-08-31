#!/usr/bin/env bash
#
# Tear an environment down so it stops billing.
#
# Destroys the environment layer only. The bootstrap layer -- remote state and
# the CI roles -- is left alone: it costs effectively nothing, and destroying
# it would mean losing the state that makes the next scripts/up.sh a single
# command.
#
# Usage:
#   scripts/down.sh [dev|prod]        (defaults to dev, prompts to confirm)
#   scripts/down.sh dev --yes         skip the prompt, for end-of-session use
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME="dev"
ASSUME_YES=false

for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=true ;;
    dev|prod) ENV_NAME="${arg}" ;;
    *) die "unknown argument '${arg}'. Usage: scripts/down.sh [dev|prod] [--yes]" ;;
  esac
done

ENV_DIR="$(resolve_env_dir "${ENV_NAME}")"

require_tools terraform aws
require_aws_auth
ensure_alert_email

head1 "Tearing down ${ENV_NAME}"

info "initialising against remote state"
terraform_init_env "${ENV_DIR}" "${ENV_NAME}"

RESOURCE_COUNT="$(env_resource_count "${ENV_DIR}")"
if [[ "${RESOURCE_COUNT}" -eq 0 ]]; then
  ok "${ENV_NAME} is already down -- state holds no resources, nothing is billing"
  exit 0
fi

info "${RESOURCE_COUNT} resources currently tracked in state"

# prod carries deletion protection on the load balancer and catalog table, so
# a destroy fails part-way rather than silently taking production apart. Say
# so up front instead of letting Terraform error out ten minutes in.
if [[ "${ENV_NAME}" == "prod" ]]; then
  warn "prod sets enable_deletion_protection = true."
  warn "Destroy will fail until that is set to false and applied. This is deliberate."
fi

if [[ "${ASSUME_YES}" != true ]]; then
  printf '\nThis destroys every resource in %s. Type the environment name to confirm: ' "${ENV_NAME}"
  read -r confirmation
  [[ "${confirmation}" == "${ENV_NAME}" ]] || die "confirmation did not match. Nothing was destroyed."
fi

info "destroying"
terraform -chdir="${ENV_DIR}" destroy -input=false -auto-approve

REMAINING="$(env_resource_count "${ENV_DIR}")"

head1 "${ENV_NAME} is down"
if [[ "${REMAINING}" -eq 0 ]]; then
  ok "state is empty -- nothing in this environment is billing"
else
  warn "${REMAINING} resources still tracked in state. Run scripts/status.sh ${ENV_NAME} to inspect."
fi

cat <<SUMMARY

  Still present, and intended to be:

    * The remote state bucket and the GitHub Actions roles (bootstrap layer).
      Effectively zero cost, and required for the next bring-up.

  Bring it back with:

      scripts/up.sh ${ENV_NAME}

SUMMARY
