# Quay.io Setup Guide

This guide explains how to configure quay.io for automated container image builds and pushes.

## Prerequisites

- quay.io account
- Repository created in quay.io (e.g., `rh-john/eip-monitor`)
- GitHub repository with Actions enabled

## Setup Steps

### 1. Create Robot Account (Recommended)

1. Log in to quay.io
2. Navigate to your organization/user settings
3. Go to "Robot Accounts"
4. Click "Create Robot Account"
5. Name it (e.g., `github-actions-eip-monitor`)
6. Grant write permissions to your repository
7. Save the robot username and token

**Benefits:**
- More secure than personal credentials
- Can be revoked independently
- Better for automation

### 2. Configure GitHub Secrets

**Important**: Use **Secrets** (not Variables) for quay.io credentials because they contain sensitive authentication information.

In your GitHub repository:
1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Add the following secrets:

- **QUAY_USERNAME**: Robot account username (e.g., `rh-john+github-actions-eip-monitor`)
  - Type: Secret
  - Scope: Repository (default)
  
- **QUAY_TOKEN**: Robot account token (or use QUAY_PASSWORD for personal account)
  - Type: Secret
  - Scope: Repository (default)
  - **Note**: Prefer QUAY_TOKEN over QUAY_PASSWORD for robot accounts

- **QUAY_REPOSITORY**: **Just the namespace/organization** (e.g., `rh-john`)
  - Type: Secret (or Variable if you prefer - this is not sensitive but can be a secret for consistency)
  - Scope: Repository (default)
  - **Important**: Do NOT include the repository name or full path
  - The workflow constructs: `quay.io/$QUAY_REPOSITORY/eip-monitor`
  - Example: If `QUAY_REPOSITORY=rh-john`, images will be pushed to `quay.io/rh-john/eip-monitor`

**Why Secrets vs Variables?**
- **Secrets**: Encrypted, masked in logs, never exposed in output
- **Variables**: Plain text, visible in logs
- **For credentials**: Always use Secrets

**Repository vs Environment?**
- **Repository-level**: Works for all workflows in the repository (recommended for this use case)
- **Environment-level**: Use if you need different credentials per environment (e.g., dev/staging/prod)

### 3. Verify Setup

The GitHub Actions workflows will automatically:
- Authenticate to quay.io using the secrets
- Build container images
- Push images with appropriate tags

## Image Tagging

### Nightly Builds
- Format: `<branch>-<date>` (e.g., `dev-20241107`)
- Format: `sha-<commit-sha>` (e.g., `sha-55ca262`)

### Pre-releases (Staging)
- Format: `v<version>-rc<number>` (e.g., `v1.2.3-rc1`)
- Format: `staging-<date>`
- Format: `sha-<commit-sha>`

### Releases (Main)
- Format: `v<version>` (e.g., `v1.2.3`)
- Format: `latest`
- Format: `sha-<commit-sha>`

## Testing

To test the setup manually:

```bash
# Build and push test image
docker build -t quay.io/rh-john/eip-monitor:test .
docker push quay.io/rh-john/eip-monitor:test
```

## Troubleshooting

### Authentication Errors
- Verify QUAY_USERNAME and QUAY_TOKEN are correct
- Check robot account has write permissions
- Ensure repository path matches QUAY_REPOSITORY secret

### Push Failures
- Verify repository exists in quay.io
- Check robot account has access to repository
- Review GitHub Actions logs for detailed error messages

