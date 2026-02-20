#!/usr/bin/env bash
# Delete all AWS resources that have tag Project=AWSGoat (used by AWSGoat Terraform default_tags).
# Run in the same region as the deployment; set AWS_REGION.
# Requires: aws cli, jq

set -euo pipefail
TAG_KEY="${TAG_KEY:-Project}"
TAG_VALUE="${TAG_VALUE:-AWSGoat}"
REGION="${AWS_REGION:-eu-west-3}"

echo "Listing resources with tag ${TAG_KEY}=${TAG_VALUE} in region ${REGION}..."

# Get all resource ARNs with the tag (paginated)
get_tagged_resources() {
  local next_token=""
  local all_arns=""
  while true; do
    local cmd="aws resourcegroupstaggingapi get-resources --region ${REGION} --tag-filters Key=${TAG_KEY},Values=${TAG_VALUE}"
    [ -n "$next_token" ] && cmd="${cmd} --starting-token ${next_token}"
    local out
    out=$(eval "$cmd" 2>/dev/null) || { echo "get-resources failed (check permissions)"; return 1; }
    local arns
    arns=$(echo "$out" | jq -r '.ResourceTagMappingList[].ResourceARN // empty')
    [ -n "$arns" ] && all_arns="${all_arns}"$'\n'"${arns}"
    next_token=$(echo "$out" | jq -r '.PaginationToken // empty')
    [ -z "$next_token" ] || [ "$next_token" = "null" ] && break
  done
  echo "$all_arns" | grep -v '^$' || true
}

delete_ec2_instances() {
  local ids
  ids=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null) || true
  [ -z "$ids" ] && return 0
  echo "Terminating EC2 instances: $ids"
  aws ec2 terminate-instances --region "$REGION" --instance-ids $ids 2>/dev/null || true
  echo "Waiting for instances to terminate..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $ids 2>/dev/null || true
}

delete_ecs_services_and_clusters() {
  local clusters
  clusters=$(aws ecs list-clusters --region "$REGION" --query 'clusterArns[]' --output text 2>/dev/null) || true
  [ -z "$clusters" ] && return 0
  for cluster_arn in $clusters; do
    local cluster_name
    cluster_name=$(echo "$cluster_arn" | awk -F'/' '{print $NF}')
    local tags
    tags=$(aws ecs list-tags-for-resource --resource-arn "$cluster_arn" --region "$REGION" 2>/dev/null) || true
    echo "$tags" | jq -e --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '.tags[] | select(.key==$k and .value==$v)' >/dev/null 2>&1 || continue
    local services
    services=$(aws ecs list-services --cluster "$cluster_name" --region "$REGION" --query 'serviceArns[]' --output text 2>/dev/null) || true
    for svc_arn in $services; do
      local svc_name
      svc_name=$(echo "$svc_arn" | awk -F'/' '{print $NF}')
      echo "Deleting ECS service $svc_name"
      aws ecs update-service --cluster "$cluster_name" --service "$svc_name" --desired-count 0 --region "$REGION" 2>/dev/null || true
      aws ecs delete-service --cluster "$cluster_name" --service "$svc_name" --force --region "$REGION" 2>/dev/null || true
    done
    echo "Deleting ECS cluster $cluster_name"
    aws ecs delete-cluster --cluster "$cluster_name" --region "$REGION" 2>/dev/null || true
  done
}

# Deregister ECS task definitions by family prefix (module-2: ECS-Lab-Task-definition); not deleted when service/cluster are removed
delete_ecs_task_definitions() {
  local next_token=""
  while true; do
    local json
    json=$(aws ecs list-task-definitions --region "$REGION" --family-prefix "ECS-Lab-Task-definition" $([ -n "$next_token" ] && echo "--starting-token $next_token") --output json 2>/dev/null) || break
    echo "$json" | jq -r '.taskDefinitionArns[]? // empty' 2>/dev/null | while read -r arn; do
      [ -z "$arn" ] && continue
      echo "Deregistering ECS task definition $arn"
      aws ecs deregister-task-definition --task-definition "$arn" --region "$REGION" 2>/dev/null || true
    done
    next_token=$(echo "$json" | jq -r '.nextToken // empty' 2>/dev/null)
    [ -z "$next_token" ] && break
  done
}

delete_albs_and_tgs() {
  # describe-load-balancers does NOT return Tags; use name pattern for module-2 ALBs and tag-based via describe-tags for others
  local albs
  albs=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].[LoadBalancerArn,LoadBalancerName]' --output json 2>/dev/null) || true
  echo "$albs" | jq -r '.[] | select(.[1] | test("^aws-goat-m2-alb")) | .[0]' 2>/dev/null | while read -r arn; do
    [ -z "$arn" ] && continue
    echo "Deleting ALB $arn"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" 2>/dev/null || true
  done
  # Tag-based ALB fallback: get tags via describe-tags (describe-load-balancers doesn't return tags)
  local all_alb_arns
  all_alb_arns=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null) || true
  if [ -n "$all_alb_arns" ]; then
    for arn in $all_alb_arns; do
      [ -z "$arn" ] && continue
      tags=$(aws elbv2 describe-tags --resource-arns "$arn" --region "$REGION" --query "TagDescriptions[?ResourceArn=='$arn'].Tags[]" --output json 2>/dev/null) || true
      if echo "$tags" | jq -e --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '.[]? | select(.Key==$k and .Value==$v)' >/dev/null 2>&1; then
        echo "Deleting ALB (by tag) $arn"
        aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" 2>/dev/null || true
      fi
    done
  fi
  # Target groups: delete by name pattern (module-2 aws-goat-m2-tg*); use text output for reliable parsing
  aws elbv2 describe-target-groups --region "$REGION" --query 'TargetGroups[].[TargetGroupArn,TargetGroupName]' --output text 2>/dev/null | while IFS=$'\t' read -r arn name; do
    [ -z "$arn" ] && continue
    case "$name" in
      aws-goat-m2-tg*) echo "Deleting target group $name ($arn)"; aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" 2>/dev/null || true ;;
      *) ;;
    esac
  done
  # Second pass: any remaining TGs with Project=AWSGoat tag
  aws elbv2 describe-target-groups --region "$REGION" --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null | while read -r arn; do
    [ -z "$arn" ] && continue
    tg_tags=$(aws elbv2 describe-tags --resource-arns "$arn" --region "$REGION" --output json 2>/dev/null | jq -r '.TagDescriptions[0].Tags[]? | "\(.Key)=\(.Value)"' 2>/dev/null) || true
    if echo "$tg_tags" | grep -q "^${TAG_KEY}=${TAG_VALUE}$"; then
      echo "Deleting target group (by tag) $arn"
      aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" 2>/dev/null || true
    fi
  done
}

delete_rds_instances() {
  local instances
  instances=$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[].[DBInstanceIdentifier,TagList]' --output json 2>/dev/null) || true
  echo "$instances" | jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '
    .[] | select(.[1][]? | select(.Key==$k and .Value==$v)) | .[0]
  ' 2>/dev/null | while read -r id; do
    [ -z "$id" ] && continue
    echo "Deleting RDS instance $id"
    aws rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot --delete-automated-backups --region "$REGION" 2>/dev/null || true
  done
}

# RDS DB subnet groups (module-2); delete after instances so no DependencyViolation
delete_rds_db_subnet_groups() {
  local groups
  groups=$(aws rds describe-db-subnet-groups --region "$REGION" --query 'DBSubnetGroups[].[DBSubnetGroupName,TagList]' --output json 2>/dev/null) || true
  echo "$groups" | jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '
    .[] | select(.[1][]? | select(.Key==$k and .Value==$v)) | .[0]
  ' 2>/dev/null | while read -r name; do
    [ -z "$name" ] && continue
    echo "Deleting RDS DB subnet group $name"
    aws rds delete-db-subnet-group --db-subnet-group-name "$name" --region "$REGION" 2>/dev/null || true
  done
  # By name pattern (module-2: database-subnets*)
  aws rds describe-db-subnet-groups --region "$REGION" --query 'DBSubnetGroups[].DBSubnetGroupName' --output text 2>/dev/null | while read -r name; do
    [ -z "$name" ] && continue
    case "$name" in
      database-subnets*) echo "Deleting RDS DB subnet group (by name) $name"; aws rds delete-db-subnet-group --db-subnet-group-name "$name" --region "$REGION" 2>/dev/null || true ;;
      *) ;;
    esac
  done
}

delete_lambda_functions() {
  local funcs
  funcs=$(aws lambda list-functions --region "$REGION" --query 'Functions[].[FunctionName,Tags]' --output json 2>/dev/null) || true
  echo "$funcs" | jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '
    .[] | select(.[1][$k]? == $v) | .[0]
  ' 2>/dev/null | while read -r name; do
    [ -z "$name" ] && continue
    echo "Deleting Lambda $name"
    aws lambda delete-function --function-name "$name" --region "$REGION" 2>/dev/null || true
  done
}

delete_apigateway_apis() {
  local apis
  apis=$(aws apigateway get-rest-apis --region "$REGION" --query 'items[].[id,tags]' --output json 2>/dev/null) || true
  echo "$apis" | jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '
    .[] | select(.[1][$k]? == $v) | .[0]
  ' 2>/dev/null | while read -r id; do
    [ -z "$id" ] && continue
    echo "Deleting API Gateway $id"
    aws apigateway delete-rest-api --rest-api-id "$id" --region "$REGION" 2>/dev/null || true
  done
}

delete_s3_buckets() {
  local buckets
  buckets=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null) || true
  for bucket in $buckets; do
    local tags
    tags=$(aws s3api get-bucket-tagging --bucket "$bucket" 2>/dev/null) || continue
    echo "$tags" | jq -e --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '.TagSet[] | select(.Key==$k and .Value==$v)' >/dev/null 2>&1 || continue
    # Skip state bucket so we don't delete Terraform state
    if [[ "$bucket" == do-not-delete-awsgoat-state-files-* ]]; then
      echo "Skipping state bucket $bucket"
      continue
    fi
    echo "Emptying and deleting bucket $bucket"
    aws s3 rm "s3://${bucket}" --recursive 2>/dev/null || true
    aws s3api delete-bucket --bucket "$bucket" 2>/dev/null || true
  done
}

delete_dynamodb_tables() {
  local tables
  tables=$(aws dynamodb list-tables --region "$REGION" --query 'TableNames[]' --output text 2>/dev/null) || true
  for table in $tables; do
    local tags
    tags=$(aws dynamodb list-tags-of-resource --resource-arn "arn:aws:dynamodb:${REGION}:$(aws sts get-caller-identity --query Account --output text):table/${table}" --region "$REGION" 2>/dev/null) || continue
    echo "$tags" | jq -e --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '.Tags[]? | select(.Key==$k and .Value==$v)' >/dev/null 2>&1 || continue
    echo "Deleting DynamoDB table $table"
    aws dynamodb delete-table --table-name "$table" --region "$REGION" 2>/dev/null || true
  done
}

delete_secretsmanager_secrets() {
  local secrets
  secrets=$(aws secretsmanager list-secrets --region "$REGION" --query 'SecretList[].[ARN,Tags]' --output json 2>/dev/null) || true
  echo "$secrets" | jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '
    .[] | select(.[1][]? | select(.Key==$k and .Value==$v)) | .[0]
  ' 2>/dev/null | while read -r arn; do
    [ -z "$arn" ] && continue
    echo "Deleting secret $arn"
    aws secretsmanager delete-secret --secret-id "$arn" --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
  done
}

delete_asgs_and_launch_templates() {
  local asgs
  asgs=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --query 'AutoScalingGroups[].[AutoScalingGroupName,Tags]' --output json 2>/dev/null) || true
  echo "$asgs" | jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '
    .[] | select(.[1][]? | select(.Key==$k and .Value==$v)) | .[0]
  ' 2>/dev/null | while read -r name; do
    [ -z "$name" ] && continue
    echo "Deleting ASG $name"
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$name" --min-size 0 --max-size 0 --desired-capacity 0 --region "$REGION" 2>/dev/null || true
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$name" --force-delete --region "$REGION" 2>/dev/null || true
  done
  sleep 5
  local lts
  lts=$(aws ec2 describe-launch-templates --region "$REGION" --query 'LaunchTemplates[].[LaunchTemplateId,Tags]' --output json 2>/dev/null) || true
  echo "$lts" | jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '
    .[] | select(.[1][]? | select(.Key==$k and .Value==$v)) | .[0]
  ' 2>/dev/null | while read -r id; do
    [ -z "$id" ] && continue
    echo "Deleting launch template $id"
    aws ec2 delete-launch-template --launch-template-id "$id" --region "$REGION" 2>/dev/null || true
  done
}

# Delete security groups by name and by tag; skip default SG; retry loop for cross-refs
delete_sgs_by_name_and_tag() {
  local patterns="ECS-SG Database-Security-Group Load-Balancer-SG aws-goat-m2-sg rds-db-sg aws-goat-db-sg"
  local pass=0
  while [ $pass -lt 5 ]; do
    pass=$((pass + 1))
    # By name: known AWSGoat SG name patterns
    aws ec2 describe-security-groups --region "$REGION" --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null | while IFS=$'\t' read -r gid gname; do
      [ -z "$gid" ] && continue
      [ "$gname" = "default" ] && continue
      for p in $patterns; do
        case "$gname" in
          ${p}*) echo "Deleting security group (by name) $gname ($gid)"; aws ec2 delete-security-group --group-id "$gid" --region "$REGION" 2>/dev/null || true; break ;;
          *) ;;
        esac
      done
    done
    # By tag: Project=AWSGoat
    aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | while read -r gid; do
      [ -z "$gid" ] && continue
      gname=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$gid" --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null) || true
      [ "$gname" = "default" ] && continue
      echo "Deleting security group (by tag) $gname ($gid)"
      aws ec2 delete-security-group --group-id "$gid" --region "$REGION" 2>/dev/null || true
    done
    sleep 2
  done
}

# Delete internet gateways by tag and by name; detach from VPC first (catches orphaned IGWs if VPC was already removed)
delete_igws_by_tag_and_name() {
  # By tag: Project=AWSGoat
  aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'InternetGateways[].[InternetGatewayId,Attachments[0].VpcId]' --output text 2>/dev/null | while IFS=$'\t' read -r igw vpc; do
    [ -z "$igw" ] || [ "$igw" = "None" ] && continue
    [ -n "$vpc" ] && [ "$vpc" != "None" ] && aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
    echo "Deleting internet gateway (by tag) $igw"
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true
  done
  # By name pattern (module-2: My-VPC-IGW)
  aws ec2 describe-internet-gateways --region "$REGION" --query "InternetGateways[].[InternetGatewayId,Tags[?Key=='Name'].Value | [0],Attachments[0].VpcId]" --output text 2>/dev/null | while IFS=$'\t' read -r igw name vpc; do
    [ -z "$igw" ] || [ "$igw" = "None" ] && continue
    case "$name" in
      My-VPC-IGW*) [ -n "$vpc" ] && [ "$vpc" != "None" ] && aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
                   echo "Deleting internet gateway (by name) $name $igw"
                   aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true ;;
      *) ;;
    esac
  done
}

delete_ec2_sgs_vpc_subnets_igw() {
  delete_sgs_by_name_and_tag
  delete_igws_by_tag_and_name
  local vpcs
  vpcs=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'Vpcs[].VpcId' --output text 2>/dev/null) || true
  for vpc in $vpcs; do
    [ -z "$vpc" ] || [ "$vpc" = "None" ] && continue
    echo "Cleaning VPC $vpc..."
    local subnets
    subnets=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text 2>/dev/null) || true
    for sid in $subnets; do
      aws ec2 delete-subnet --subnet-id "$sid" --region "$REGION" 2>/dev/null || true
    done
    local igws
    igws=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null) || true
    for igw in $igws; do
      [ -z "$igw" ] && continue
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
      aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true
    done
    local rts
    rts=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null) || true
    for rt in $rts; do
      aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null || true
    done
    local sgs
    sgs=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null) || true
    for sg in $sgs; do
      [ -z "$sg" ] && continue
      aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || true
    done
    aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
  done
}

delete_iam_roles_and_policies() {
  local roles
  roles=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null) || true
  for role in $roles; do
    local tags
    tags=$(aws iam list-role-tags --role-name "$role" 2>/dev/null) || continue
    echo "$tags" | jq -e --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '.Tags[]? | select(.Key==$k and .Value==$v)' >/dev/null 2>&1 || continue
    echo "Deleting IAM role $role"
    for policy in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$policy" 2>/dev/null || true
    done
    for profile in $(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null); do
      aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
      aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$role" 2>/dev/null || true
  done
  local policies
  policies=$(aws iam list-policies --scope Local --query 'Policies[].Arn' --output text 2>/dev/null) || true
  for arn in $policies; do
    local tags
    tags=$(aws iam list-policy-tags --policy-arn "$arn" 2>/dev/null) || continue
    echo "$tags" | jq -e --arg k "$TAG_KEY" --arg v "$TAG_VALUE" '.Tags[]? | select(.Key==$k and .Value==$v)' >/dev/null 2>&1 || continue
    echo "Deleting IAM policy $arn"
    for version in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?IsDefault==`false`].VersionId' --output text 2>/dev/null); do
      aws iam delete-policy-version --policy-arn "$arn" --version-id "$version" 2>/dev/null || true
    done
    aws iam delete-policy --policy-arn "$arn" 2>/dev/null || true
  done
}

# Fallback: delete IAM roles and policies created by module-1/module-2 by name pattern (catches untagged resources)
delete_iam_awsgoat_by_name() {
  local role_patterns="blog_app_lambda blog_app_lambda_data AWS_GOAT_ROLE ecs-instance-role ec2Deployer-role ecs-task-role"
  local policy_patterns="lambda-data-policies dev-ec2-lambda-policies aws-goat-instance-policy aws-goat-instance-boundary-policy ec2DeployerAdmin-policy"
  for prefix in $role_patterns; do
    local roles
    roles=$(aws iam list-roles --output json 2>/dev/null | jq -r --arg p "$prefix" '.Roles[] | select(.RoleName | startswith($p)) | .RoleName' 2>/dev/null) || true
    for role in $roles; do
      [ -z "$role" ] && continue
      echo "Deleting IAM role (by name): $role"
      for policy in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$policy" 2>/dev/null || true
      done
      for inline in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$role" --policy-name "$inline" 2>/dev/null || true
      done
      for profile in $(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null); do
        aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
        aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
      done
      aws iam delete-role --role-name "$role" 2>/dev/null || true
    done
  done
  for prefix in $policy_patterns; do
    local policies
    policies=$(aws iam list-policies --scope Local --output json 2>/dev/null | jq -r --arg p "$prefix" '.Policies[] | select(.PolicyName | startswith($p)) | .Arn' 2>/dev/null) || true
    for arn in $policies; do
      [ -z "$arn" ] && continue
      echo "Deleting IAM policy (by name): $arn"
      for version in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?IsDefault==`false`].VersionId' --output text 2>/dev/null); do
        aws iam delete-policy-version --policy-arn "$arn" --version-id "$version" 2>/dev/null || true
      done
      aws iam delete-policy --policy-arn "$arn" 2>/dev/null || true
    done
  done
}

# Run in dependency order
delete_ec2_instances
sleep 10
delete_ecs_services_and_clusters
delete_ecs_task_definitions
sleep 5
delete_asgs_and_launch_templates
delete_albs_and_tgs
delete_rds_instances
sleep 15
delete_rds_db_subnet_groups
delete_lambda_functions
delete_apigateway_apis
delete_dynamodb_tables
delete_secretsmanager_secrets
delete_s3_buckets
delete_ec2_sgs_vpc_subnets_igw
delete_iam_roles_and_policies
delete_iam_awsgoat_by_name

echo "Tag-based cleanup (Project=AWSGoat) completed."
