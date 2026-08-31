# Data protection and durability
#
# Encryption at rest, public-access blocking, backup posture, and the
# instance metadata hardening that keeps a web application bug from becoming
# a credential compromise.
package main

import rego.v1

# --- Encryption at rest -----------------------------------------------------

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_launch_template"

	some mapping in resource.change.after.block_device_mappings
	some ebs in mapping.ebs
	ebs.encrypted == "false"

	msg := sprintf(
		"%s launches instances with an unencrypted root volume.",
		[resource.address],
	)
}

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_ebs_volume"

	resource.change.after.encrypted == false

	msg := sprintf("%s is an unencrypted EBS volume.", [resource.address])
}

# --- S3 ---------------------------------------------------------------------

# Terraform state contains every resource attribute, including any value a
# provider marks sensitive. A publicly readable state bucket is a full
# infrastructure disclosure, so all four public access controls are required.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_s3_bucket_public_access_block"

	after := resource.change.after
	controls := {
		"block_public_acls": after.block_public_acls,
		"block_public_policy": after.block_public_policy,
		"ignore_public_acls": after.ignore_public_acls,
		"restrict_public_buckets": after.restrict_public_buckets,
	}

	some name, enabled in controls
	enabled == false

	msg := sprintf(
		"%s leaves %s disabled. All four public access controls must be enabled.",
		[resource.address, name],
	)
}

# A bucket with no public access block at all is worse than one with a
# misconfigured block, and is easy to miss because nothing looks wrong.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_s3_bucket"

	blocked_buckets := {ref |
		some other in changed_resources
		other.type == "aws_s3_bucket_public_access_block"
		ref := other.change.after.bucket
	}

	not resource.change.after.bucket in blocked_buckets
	not is_unknown(resource, "bucket")

	msg := sprintf(
		"%s has no aws_s3_bucket_public_access_block. Every bucket must explicitly block public access.",
		[resource.address],
	)
}

# --- DynamoDB ---------------------------------------------------------------

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_dynamodb_table"

	some pitr in resource.change.after.point_in_time_recovery
	pitr.enabled == false

	msg := sprintf(
		"%s has point-in-time recovery disabled, leaving no recovery path for accidental writes or deletes.",
		[resource.address],
	)
}

# --- Instance metadata ------------------------------------------------------

# IMDSv1 lets any process that can make an outbound HTTP request -- including
# one driven by a server-side request forgery bug in the application -- read
# the instance role credentials. Requiring IMDSv2 closes that path.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_launch_template"

	some options in resource.change.after.metadata_options
	options.http_tokens != "required"

	msg := sprintf(
		"%s does not require IMDSv2 (http_tokens must be \"required\"), exposing instance role credentials to SSRF.",
		[resource.address],
	)
}

# A hop limit above 1 lets a container on the instance reach the metadata
# service, which re-opens the same credential path from inside a workload.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_launch_template"

	some options in resource.change.after.metadata_options
	options.http_put_response_hop_limit > 1

	msg := sprintf(
		"%s sets an IMDS hop limit of %d. A limit above 1 exposes instance credentials to containerised workloads.",
		[resource.address, options.http_put_response_hop_limit],
	)
}

# --- Log retention ----------------------------------------------------------

# A log group with no retention keeps data forever. That is both a
# steadily growing bill and a data minimisation problem.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_cloudwatch_log_group"

	not resource.change.after.retention_in_days

	msg := sprintf(
		"%s has no retention_in_days, so logs are kept forever and the cost grows without bound.",
		[resource.address],
	)
}

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_cloudwatch_log_group"

	resource.change.after.retention_in_days == 0

	msg := sprintf(
		"%s sets retention_in_days to 0, which means never expire.",
		[resource.address],
	)
}
