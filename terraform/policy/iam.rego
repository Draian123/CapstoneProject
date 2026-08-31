# IAM least privilege
#
# Blocks the two IAM shapes that quietly undo every other control: an
# inline policy granting Action "*" on Resource "*", and an attachment of
# the AdministratorAccess managed policy.
#
# These are warnings in most scanners. Here they are hard failures, because
# a pipeline that can grant itself administrator can also disable the
# pipeline that was supposed to stop it.
package main

import rego.v1

# Managed policies too broad to attach to a workload identity.
forbidden_managed_policies := {
	"arn:aws:iam::aws:policy/AdministratorAccess",
	"arn:aws:iam::aws:policy/PowerUserAccess",
	"arn:aws:iam::aws:policy/IAMFullAccess",
}

deny contains msg if {
	some resource in changed_resources
	resource.type in {"aws_iam_role_policy_attachment", "aws_iam_user_policy_attachment"}

	policy_arn := resource.change.after.policy_arn
	policy_arn in forbidden_managed_policies

	msg := sprintf(
		"%s attaches %s. Grant only the specific permissions the workload needs.",
		[resource.address, policy_arn],
	)
}

# Wildcard action on wildcard resource, in any of the places a policy document
# can appear.
policy_documents contains {"address": address, "json": document} if {
	some resource in changed_resources
	resource.type in {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy", "aws_iam_group_policy"}

	document := resource.change.after.policy
	address := resource.address
}

deny contains msg if {
	some entry in policy_documents

	document := json.unmarshal(entry.json)
	some statement in document.Statement

	statement.Effect == "Allow"
	has_wildcard(statement.Action)
	has_wildcard(statement.Resource)

	msg := sprintf(
		"%s allows Action \"*\" on Resource \"*\", which is administrator access by another name.",
		[entry.address],
	)
}

# Action and Resource may each be a string or a list of strings.
has_wildcard(value) if {
	is_string(value)
	value == "*"
}

has_wildcard(value) if {
	is_array(value)
	some item in value
	item == "*"
}

# --- Long-lived credentials -------------------------------------------------

# Access keys are the credential that leaks: into a commit, a CI log, a
# laptop backup. Roles issue short-lived credentials instead, and every
# identity in this platform can use one.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_iam_access_key"

	msg := sprintf(
		"%s creates a long-lived IAM access key. Use an IAM role -- GitHub Actions federates via OIDC and EC2 uses an instance profile.",
		[resource.address],
	)
}

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_iam_user"

	msg := sprintf(
		"%s creates an IAM user. This platform authenticates workloads with roles, not users.",
		[resource.address],
	)
}
