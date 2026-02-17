variable "student_id" {
  description = "Unique identifier for this student/lab instance. Enables multi-student deployment by isolating all resources (IAM roles, S3 buckets, Lambda, EC2) per student. Critical for privesc scenarios so each student has their own escalation path."
  type        = string
  default     = "default"
}

variable "region" {
  description = "AWS region for deployment. Can be set via TF_VAR_region (env) or -var. Defaults to eu-west-3 (Paris)."
  type        = string
  default     = "eu-west-3"
}
