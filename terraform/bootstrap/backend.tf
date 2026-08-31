# Written by scripts/bootstrap.sh after the state bucket was created.
#
# The bootstrap layer starts on the local backend -- it cannot use a bucket
# that does not exist yet -- and moves here on first run. From then on the
# bucket manages itself.
terraform {
  backend "s3" {
    bucket       = "ce-capstone-tfstate-697345203222"
    key          = "ce-capstone/bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
