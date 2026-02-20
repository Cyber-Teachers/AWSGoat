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
  run_import "aws_db_instance.database-instance" "aws-goat-db${SUFFIX}"

  # Security groups (by id, looked up by name in VPC)
  SG_ECS=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=ECS-SG${SUFFIX}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) || true
  [ -n "$SG_ECS" ] && [ "$SG_ECS" != "None" ] && run_import "aws_security_group.ecs_sg" "$SG_ECS"
  SG_DB=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=Database-Security-Group${SUFFIX}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) || true
  [ -n "$SG_DB" ] && [ "$SG_DB" != "None" ] && run_import "aws_security_group.database-security-group" "$SG_DB"
  SG_LB=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=Load-Balancer-SG${SUFFIX}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) || true
  [ -n "$SG_LB" ] && [ "$SG_LB" != "None" ] && run_import "aws_security_group.load_balancer_security_group" "$SG_LB"

  # Subnets (by id)
  SUBNET1=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=lab-subnet-public-1${SUFFIX}" --query 'Subnets[0].SubnetId' --output text 2>/dev/null) || true
  [ -n "$SUBNET1" ] && [ "$SUBNET1" != "None" ] && run_import "aws_subnet.lab-subnet-public-1" "$SUBNET1"
  SUBNET2=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=lab-subnet-public-1b${SUFFIX}" --query 'Subnets[0].SubnetId' --output text 2>/dev/null) || true
  [ -n "$SUBNET2" ] && [ "$SUBNET2" != "None" ] && run_import "aws_subnet.lab-subnet-public-1b" "$SUBNET2"

  # Internet gateway and route table
  IGW_ID=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null) || true
  [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ] && run_import "aws_internet_gateway.my_vpc_igw" "$IGW_ID"
  RT_ID=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=Public-Subnet-RT${SUFFIX}" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null) || true
  [ -n "$RT_ID" ] && [ "$RT_ID" != "None" ] && run_import "aws_route_table.my_vpc_us_east_1_public_rt" "$RT_ID"

  # ALB and target group: import by ARN (look up by name)
  ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" --names "aws-goat-m2-alb${SUFFIX}" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
  [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ] && run_import "aws_alb.application_load_balancer" "$ALB_ARN"
  TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" --names "aws-goat-m2-tg${SUFFIX}" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
  [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ] && run_import "aws_lb_target_group.target_group" "$TG_ARN"
  LISTENER_ARN=$(aws elbv2 describe-listeners --region "$REGION" --load-balancer-arn "$ALB_ARN" --query 'Listeners[0].ListenerArn' --output text 2>/dev/null) || true
  [ -n "$LISTENER_ARN" ] && [ "$LISTENER_ARN" != "None" ] && run_import "aws_lb_listener.listener" "$LISTENER_ARN"

  # ECS cluster, task definition, service
  run_import "aws_ecs_cluster.cluster" "ecs-lab-cluster${SUFFIX}"
  TASK_ARN=$(aws ecs list-task-definitions --region "$REGION" --family-prefix "ECS-Lab-Task-definition${SUFFIX}" --sort DESC --max-items 1 --query 'taskDefinitionArns[0]' --output text 2>/dev/null) || true
  [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ] && run_import "aws_ecs_task_definition.task_definition" "$TASK_ARN"
  run_import "aws_ecs_service.worker" "ecs-lab-cluster${SUFFIX}/ecs_service_worker${SUFFIX}"

  # Launch template and ASG
  LT_ID=$(aws ec2 describe-launch-templates --region "$REGION" --filters "Name=tag:Name,Values=ecs-launch-template${SUFFIX}" --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null) || true
  [ -n "$LT_ID" ] && [ "$LT_ID" != "None" ] && run_import "aws_launch_template.ecs_launch_template" "$LT_ID"
  run_import "aws_autoscaling_group.ecs_asg" "ECS-lab-asg${SUFFIX}"

  echo "Import step finished (module-2)."
elif [ "$MODULE" = "module-1" ]; then
  # Add module-1 imports here if we see similar EntityAlreadyExists errors
  echo "Import step finished (module-1, no imports defined)."
else
  echo "Unknown module: $MODULE"
  exit 1
fi
