# Backend bootstrap

Creates the S3 bucket used by **module-1** and **module-2** for [remote state](https://developer.hashicorp.com/terraform/language/state/remote).

- **Bucket name:** `do-not-delete-awsgoat-state-files-<account_id>`
- **Versioning:** enabled (recommended for state recovery)
- **Public access:** blocked

The bulk deploy workflow runs this automatically when the bucket does not exist. You can also run it once per account manually:

```bash
cd backend-bootstrap
terraform init
terraform apply -var="region=eu-west-3"
```

Bootstrap state is stored locally (no backend). The bucket created here is used by the modules via their S3 backend configuration.
