# AWSGoat Project Review

This document summarizes a full review of the Terraform configs, GitHub Actions workflows, scripts, and consistency across the project. Run `terraform validate` in each Terraform root (backend-bootstrap, modules/module-1, modules/module-2) locally to confirm syntax.

---

## 1. Backend bootstrap

| Item | Status |
|------|--------|
| **Purpose** | Creates the S3 state bucket `do-not-delete-awsgoat-state-files-<account_id>-<region>` with versioning and public access block. |
| **State** | Local (no backend). |
| **Provider** | AWS; region from `var.region` (default `eu-west-3`). |
| **Variables** | `region` (default `eu-west-3`). |
| **Output** | `bucket_name` for use as `-backend-config bucket=...`. |

**Verdict:** Correct. Bucket name matches workflows and delete script (which skips this prefix).

---

## 2. Modules (module-1 and module-2)

### Common

- **Backend:** Partial S3 backend; `bucket`, `key`, `region`, `workspace_key_prefix` passed via `-backend-config` in CI.
- **Provider:** AWS with `region = var.region` and `default_tags = { Project = "AWSGoat" }`.
- **Variables:** `student_id` (default `"default"`), `region` (default `eu-west-3`).
- **Locals:** `name_suffix = var.student_id == "default" ? "" : "-${lower(replace(var.student_id, "_", "-"))}"`, `common_tags = { Project = "AWSGoat" }`.

### Module-1 (Lambda / API Gateway / S3 / DynamoDB)

- **AWS provider:** `~> 5.24.0`.
- **Notable names (with `local.name_suffix`):** IAM `blog_app_lambda`, `blog_app_lambda_data`, `AWS_GOAT_ROLE`; policies `lambda-data-policies`, `dev-ec2-lambda-policies`; Lambda `blog-application`, `blog-application-data`; S3 buckets (production/dev/temp); DynamoDB `blog-users`, `blog-posts`; API Gateway rest APIs and resources.

### Module-2 (ECS / RDS / ALB)

- **AWS provider:** `~> 3.27`.
- **Notable names (with `local.name_suffix`):** VPC `AWS_GOAT_VPC`; SGs `ECS-SG`, `Database-Security-Group`, `Load-Balancer-SG`; IAM roles `ecs-instance-role`, `ec2Deployer-role`, `ecs-task-role`; instance profiles `ec2Deployer`, `ecs-instance-profile`; policies `aws-goat-instance-policy`, `aws-goat-instance-boundary-policy`, `ec2DeployerAdmin-policy`; RDS `aws-goat-db`, subnet group `database-subnets`; ALB `aws-goat-m2-alb`, TG `aws-goat-m2-tg`; ECS cluster `ecs-lab-cluster`, service `ecs_service_worker`, ASG `ECS-lab-asg`; Secrets Manager `RDS_CREDS`.

**Verdict:** Naming and tags are consistent. Module-1 and module-2 use different AWS provider major versions (5.x vs 3.x); no functional conflict, but consider aligning for consistency.

---

## 3. Scripts

### import-existing-resources.sh

- **Usage:** `./import-existing-resources.sh <module-1|module-2> [student_id]`. Uses Terraform workspace = student_id; env: `ACCOUNT_ID`, `AWS_REGION` (default `eu-west-3`).
- **module-2:** Imports VPC, IAM (roles, policies, instance profiles), secret, DB subnet group, DB instance, security groups, subnets, IGW, route table, ALB, target group, listener, ECS cluster/task/service, launch template, ASG. Skips import if resource already in state.
- **module-1:** No imports defined (script exits after message).
- **Naming:** SUFFIX = "" for default, else "-${STUDENT_ID}". Matches Terraform `name_suffix` (e.g. student_id `01` → `-01`). Instance profile names: `ec2Deployer${SUFFIX}`, `ecs-instance-profile${SUFFIX}` — match Terraform.

**Verdict:** Logic and names align with module-2 Terraform. Safe to run before apply.

### delete-resources-by-tag-awsgoat.sh

- **Purpose:** Delete all resources tagged `Project=AWSGoat` (and by name where APIs don’t expose tags). Env: `TAG_KEY`, `TAG_VALUE`, `AWS_REGION` (default `eu-west-3`).
- **Order:** EC2 instances → ECS (scale down, delete services/clusters) → ASGs/launch templates → ALBs/TGs → RDS → RDS DB subnet groups → Lambda → API Gateway → DynamoDB → Secrets Manager → S3 (skips `do-not-delete-awsgoat-state-files-*`) → SGs (by name and tag) → VPC/subnets/IGW/route tables → IAM (by tag then by name).
- **Name patterns:** ALB `aws-goat-m2-alb*`, TG `aws-goat-m2-tg*`, RDS subnet group `database-subnets*`, SGs (ECS-SG, Database-Security-Group, Load-Balancer-SG, aws-goat-m2-sg, rds-db-sg, aws-goat-db-sg), IAM roles `blog_app_lambda`, `blog_app_lambda_data`, `AWS_GOAT_ROLE`, `ecs-instance-role`, `ec2Deployer-role`, `ecs-task-role`, policies `lambda-data-policies`, `dev-ec2-lambda-policies`, `aws-goat-instance-policy`, `aws-goat-instance-boundary-policy`, `ec2DeployerAdmin-policy`.

**Verdict:** Order respects dependencies. Name patterns and tags match module-1 and module-2. State bucket is explicitly skipped.

---

## 4. GitHub Actions workflows

### tf-apply-main.yml (Terraform Apply)

- **Inputs:** module (required), student_id (optional), region (optional). Defaults: student_id `default`, region `eu-west-3`.
- **Steps:** Checkout → Terraform setup → Set ACCOUNT_ID, STUDENT_ID, AWS_REGION → Ensure state bucket exists (run backend-bootstrap apply if missing, with `-var="region=${{ env.AWS_REGION }}"`) → Terraform init (bucket, key, region, workspace_key_prefix = module) → Workspace select/new if student_id != default → Import existing resources → Terraform plan → Terraform apply → Outputs.
- **Backend:** Bucket name `do-not-delete-awsgoat-state-files-$ACCOUNT_ID-$AWS_REGION`. Region from input or env.

**Verdict:** Correct. Bucket creation uses workflow region; init/apply use same bucket and region.

### tf-apply-bulk.yml (Terraform Apply Bulk)

- **Inputs:** number_of_instances (required), module, region (optional). Student IDs generated as `01`, `02`, … (max 50).
- **Jobs:** generate-ids → bootstrap (ensure state bucket) → terraform (matrix per student_id, max 5 parallel).
- **Bootstrap:** Sets ACCOUNT_ID, AWS_REGION from input; creates bucket in that region if missing.
- **Terraform job:** Sets ACCOUNT_ID, AWS_REGION; init uses same bucket and workspace_key_prefix; workspace select/new per matrix student_id; import → plan → apply.

**Verdict:** Correct. Region and bucket are consistent between bootstrap and terraform job.

### tf-destroy-main.yml (Terraform Destroy)

- **Inputs:** module, student_id (optional), region (optional).
- **Steps:** Checkout → Terraform setup → Set ACCOUNT_ID, STUDENT_ID, AWS_REGION → Init (same bucket, workspace_key_prefix) → Workspace select/new if not default → Terraform destroy.

**Verdict:** Correct. Same backend config as apply.

### tf-clean-up.yml (Terraform Clean Up)

- **Inputs:** region (optional).
- **Steps:** Checkout → Terraform setup → Set ACCOUNT_ID, AWS_REGION → List workspaces from S3 keys matching `*env:/*/terraform.tfstate` → For each (module, student_id): cd module, init, workspace select, destroy → Empty state bucket (with pagination for list-object-versions) → Delete bucket → Run delete-resources-by-tag-awsgoat.sh.
- **Workspace parsing:** Key format `<prefix>/env:/<workspace>/terraform.tfstate`; mod = prefix (e.g. module-1), ws = workspace (e.g. 01, default). Correct for Terraform S3 backend layout.
- **S3 empty loop:** Uses KeyMarker/VersionIdMarker pagination so buckets with more than 1000 versioned objects are fully emptied.

**Verdict:** Correct. Pagination fix applied for large state buckets.

---

## 5. Consistency summary

| Concern | Status |
|--------|--------|
| State bucket name | Same in backend-bootstrap, all workflows, and delete script (skip rule). |
| Region default | `eu-west-3` in bootstrap, modules, scripts, workflows, README. |
| workspace_key_prefix | Set to module name (module-1 / module-2) in all workflows; matches S3 key layout in clean-up. |
| student_id / name_suffix | Bulk uses `01`, `02`; Terraform and import script use `-01`, `-02`; delete script uses startswith/patterns that match. |
| IAM/ALB/TG/SG/RDS names | Delete script patterns match Terraform and import script. |
| Tag Project=AWSGoat | default_tags in modules; delete and import use same tag. |

---

## 6. Recommendations

1. **Terraform validate:** Run `terraform validate` in `backend-bootstrap`, `modules/module-1`, and `modules/module-2` (after `terraform init` in each) to confirm no syntax/configuration errors.
2. **AWS provider versions:** Consider aligning module-1 (5.x) and module-2 (3.x) to the same major version for consistency; optional.
3. **Module-1 import script:** If you see “resource already exists” or state drift after partial applies, add module-1 imports (Lambda, IAM, API Gateway, DynamoDB, S3) following the same pattern as module-2.
4. **Clean-up script:** Runs with `continue-on-error: true`; monitor workflow logs for failures (e.g. IAM or SG dependency errors) and re-run if needed.

---

## 7. Changes made during review

- **tf-clean-up.yml:** Added pagination to the state-bucket empty loop (KeyMarker / VersionIdMarker) so buckets with more than 1000 versioned objects are fully emptied before delete-bucket.
