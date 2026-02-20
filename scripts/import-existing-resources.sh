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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR/modules/$MODULE" || exit 1

if [ -z "$ACCOUNT_ID" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || true
fi
if [ -z "$ACCOUNT_ID" ]; then
  echo "ACCOUNT_ID not set and could not get from AWS; skipping imports."
  exit 0
fi

terraform workspace select "$STUDENT_ID" 2>/dev/null || terraform workspace new "$STUDENT_ID"

# Import only if the resource is not already in state (avoids "Resource already managed" noise).
run_import() {
  local addr="$1"
  local id="$2"
  if terraform state show "$addr" &>/dev/null; then
    return 0
  fi
  terraform import -input=false -var="student_id=$STUDENT_ID" -var="region=$REGION" "$addr" "$id" 2>/dev/null || true
}

if [ "$MODULE" = "module-2" ]; then
  # VPC (avoids VpcLimitExceeded when re-applying after partial run)
  VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=AWS_GOAT_VPC${SUFFIX}" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
  [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] && run_import "aws_vpc.lab-vpc" "$VPC_ID"
  run_import "aws_iam_policy.ecs_instance_policy" "arn:aws:iam::${ACCOUNT_ID}:policy/aws-goat-instance-policy${SUFFIX}"
  run_import "aws_iam_policy.instance_boundary_policy" "arn:aws:iam::${ACCOUNT_ID}:policy/aws-goat-instance-boundary-policy${SUFFIX}"
  run_import "aws_iam_role.ec2-deployer-role" "ec2Deployer-role${SUFFIX}"
  run_import "aws_iam_policy.ec2_deployer_admin_policy" "arn:aws:iam::${ACCOUNT_ID}:policy/ec2DeployerAdmin-policy${SUFFIX}"
  run_import "aws_iam_role.ecs-task-role" "ecs-task-role${SUFFIX}"
  run_import "aws_iam_role.ecs-instance-role" "ecs-instance-role${SUFFIX}"
  run_import "aws_iam_instance_profile.ec2-deployer-profile" "ec2Deployer${SUFFIX}"
  run_import "aws_iam_instance_profile.ecs-instance-profile" "ecs-instance-profile${SUFFIX}"
  run_import "aws_secretsmanager_secret.rds_creds" "RDS_CREDS${SUFFIX}"
  run_import "aws_db_subnet_group.database-subnet-group" "database-subnets${SUFFIX}"
  # ALB and target group: import by ARN (look up by name)
  ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" --names "aws-goat-m2-alb${SUFFIX}" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
  [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ] && run_import "aws_alb.application_load_balancer" "$ALB_ARN"
  TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" --names "aws-goat-m2-tg${SUFFIX}" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
  [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ] && run_import "aws_lb_target_group.target_group" "$TG_ARN"
  echo "Import step finished (module-2)."
elif [ "$MODULE" = "module-1" ]; then
  # Add module-1 imports here if we see similar EntityAlreadyExists errors
  echo "Import step finished (module-1, no imports defined)."
else
  echo "Unknown module: $MODULE"
  exit 1
fi
