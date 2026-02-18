#!/usr/bin/env bash
# Import already-existing AWS resources into Terraform state.
# Use when a previous apply partially succeeded and state was lost or out of sync.
# Safe to run before every apply: imports succeed when resource exists in AWS; otherwise we ignore and apply will create.
set -euo pipefail

MODULE="${1:-}"
STUDENT_ID="${2:-default}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
REGION="${AWS_REGION:-eu-west-3}"

if [ -z "$MODULE" ]; then
  echo "Usage: $0 <module-1|module-2> [student_id]"
  exit 1
fi

if [ "$STUDENT_ID" = "default" ]; then
  SUFFIX=""
else
  SUFFIX="-${STUDENT_ID}"
fi

cd "$(dirname "$0")/../modules/$MODULE" || exit 1

if [ -z "$ACCOUNT_ID" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || true
fi
if [ -z "$ACCOUNT_ID" ]; then
  echo "ACCOUNT_ID not set and could not get from AWS; skipping imports."
  exit 0
fi

terraform workspace select "$STUDENT_ID" 2>/dev/null || true

run_import() {
  local addr="$1"
  local id="$2"
  terraform import -input=false -var="student_id=$STUDENT_ID" -var="region=$REGION" "$addr" "$id" 2>/dev/null || true
}

if [ "$MODULE" = "module-2" ]; then
  run_import "aws_iam_policy.ecs_instance_policy" "arn:aws:iam::${ACCOUNT_ID}:policy/aws-goat-instance-policy${SUFFIX}"
  run_import "aws_iam_policy.instance_boundary_policy" "arn:aws:iam::${ACCOUNT_ID}:policy/aws-goat-instance-boundary-policy${SUFFIX}"
  run_import "aws_iam_role.ec2-deployer-role" "ec2Deployer-role${SUFFIX}"
  run_import "aws_iam_policy.ec2_deployer_admin_policy" "arn:aws:iam::${ACCOUNT_ID}:policy/ec2DeployerAdmin-policy${SUFFIX}"
  run_import "aws_iam_role.ecs-task-role" "ecs-task-role${SUFFIX}"
  run_import "aws_iam_role.ecs-instance-role" "ecs-instance-role${SUFFIX}"
  # Secrets Manager: import by name (or ARN); name is RDS_CREDS + suffix
  run_import "aws_secretsmanager_secret.rds_creds" "RDS_CREDS${SUFFIX}"
  echo "Import step finished (module-2)."
elif [ "$MODULE" = "module-1" ]; then
  # Add module-1 imports here if we see similar EntityAlreadyExists errors
  echo "Import step finished (module-1, no imports defined)."
else
  echo "Unknown module: $MODULE"
  exit 1
fi
