# Deploying

The site deploys from GitHub Actions on every push to `main`
(`.github/workflows/deploy.yml`), and can be run on demand from the Actions
tab via **Run workflow**. Docs-only changes (`*.md`, `.gitignore`) are skipped.

The workflow runs `./deploy.sh --sync-only`, which uploads the site and
invalidates only the CloudFront paths that actually changed. It never
provisions: creating the bucket, certificate, OAC and distribution stays a
one-time local operation, because it needs far broader IAM rights than the
deploy role holds.

Local deploys still work exactly as before — `./deploy.sh` uses the `personal`
profile — and are still the way to provision or change infrastructure.

## One-time AWS setup

All of this happens in account **594041868357**, once.

### 1. Register GitHub as an OIDC identity provider

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

If your CLI still insists on `--thumbprint-list`, pass
`6938fd4d98bab03faadb97b34396831e3780aea1`. AWS validates GitHub's certificate
against its own trust store now and ignores the value, but older CLI versions
require the argument to be present.

Skip this step if the provider already exists — it is shared account-wide.

### 2. Create the deploy role

Trust policy — save as `trust.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::594041868357:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:dancfox/dennisschoenfelder.com:environment:production"
      }
    }
  }]
}
```

That `sub` is the important line. Because the workflow job declares
`environment: production`, GitHub's token carries the `environment:` subject
form rather than a branch ref — only a job targeting that environment can
assume this role. Pull requests from forks cannot. If you ever remove the
`environment:` block from the workflow, this must change to
`repo:dancfox/dennisschoenfelder.com:ref:refs/heads/main` or the role will
stop being assumable.

```bash
aws iam create-role \
  --role-name dennisschoenfelder-gh-deploy \
  --assume-role-policy-document file://trust.json
```

### 3. Grant it just enough

Save as `policy.json`, replacing `<DISTRIBUTION_ID>`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SyncSiteObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::dennisschoenfelder.com/*"
    },
    {
      "Sid": "ListBucketForSync",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::dennisschoenfelder.com"
    },
    {
      "Sid": "InvalidateCache",
      "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "arn:aws:cloudfront::594041868357:distribution/<DISTRIBUTION_ID>"
    }
  ]
}
```

```bash
aws iam put-role-policy \
  --role-name dennisschoenfelder-gh-deploy \
  --policy-name site-deploy \
  --policy-document file://policy.json
```

`s3:ListBucket` is what lets `aws s3 sync` compare local files against what is
already in the bucket; without it every run would re-upload everything.
`sts:GetCallerIdentity`, which the script's account guard calls, needs no
permission — it is always allowed.

The role cannot create or modify infrastructure, and cannot touch any other
bucket or distribution.

### 4. Add two repository secrets

Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::594041868357:role/dennisschoenfelder-gh-deploy` |
| `CLOUDFRONT_DISTRIBUTION_ID` | the distribution ID (see below) |

Neither is a credential. The role ARN is not secret in any real sense, and the
distribution ID is visible in response headers; they live in secrets only to
keep the account details out of the repo.

Find the distribution ID in your local `.deploy.env`, or:

```bash
aws cloudfront list-distributions --profile personal \
  --query "DistributionList.Items[?contains(Aliases.Items, 'dennisschoenfelder.com')].Id" \
  --output text
```

### 5. Create the environment

Settings → Environments → **New environment** → name it `production`.

GitHub creates it automatically on first run, but making it yourself first
lets you add required reviewers, turning every deploy into something you
approve by hand.

## First run

Merging to `main` deploys immediately. To watch it before trusting it, use
**Run workflow** from the Actions tab first. The log prints the account it
authenticated to, every file transferred, and the exact invalidation paths
before firing them.

## If it fails

| Symptom | Cause |
| --- | --- |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The `sub` in the trust policy does not match. Check it uses the `environment:production` form. |
| `Could not authenticate` | The role assumption step did not run, or `AWS_DEPLOY_ROLE_ARN` is unset. |
| `Authenticated to account NNN, expected 594041868357` | The role lives in the wrong account. |
| `--sync-only needs DIST_ID` | `CLOUDFRONT_DISTRIBUTION_ID` is unset or misnamed. |
| `AccessDenied` on `s3:ListBucket` | The bucket ARN in the policy has a trailing `/*`; the list statement needs the bare bucket ARN. |
