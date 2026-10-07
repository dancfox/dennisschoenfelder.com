#!/usr/bin/env bash
#
# setup-github-oidc.sh — one-time: let GitHub Actions deploy this site.
#
# Does everything DEPLOY.md sections 1-3 describe, idempotently: registers
# GitHub as an OIDC identity provider, creates a deploy role trusted only by
# this repository's production environment, and grants it exactly the S3 and
# CloudFront rights the deploy needs. Then prints the two values to paste
# into GitHub as repository secrets.
#
# Safe to re-run: anything that already exists is reused, not duplicated.
#
#   ./tools/setup-github-oidc.sh
#
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-personal}"
EXPECTED_ACCOUNT="594041868357"
DOMAIN="dennisschoenfelder.com"
REPO="dancfox/dennisschoenfelder.com"
ENVIRONMENT="production"
ROLE="dennisschoenfelder-gh-deploy"
REGION="us-east-1"

export AWS_PROFILE AWS_DEFAULT_REGION="$REGION"
aws() { command aws --profile "$AWS_PROFILE" --region "$REGION" "$@"; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI not found."
command -v jq  >/dev/null || die "jq not found (brew install jq)."

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || \
  die "Authenticated to '${ACCOUNT:-nothing}', expected ${EXPECTED_ACCOUNT}."
log "Authenticated to ${ACCOUNT}."

# ---- 1. OIDC identity provider (account-wide; may already exist) ----------
# An existing provider is not necessarily a usable one: if it was created for
# some other purpose without sts.amazonaws.com in its client ID list, the aud
# condition below never matches and the role refuses the token with
# "Not authorized to perform sts:AssumeRoleWithWebIdentity".
PROVIDER="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER" >/dev/null 2>&1; then
  AUDS="$(aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$PROVIDER" \
    --query 'ClientIDList' --output text)"
  if grep -qw "sts.amazonaws.com" <<<"$AUDS"; then
    log "OIDC provider already registered (audience present)."
  else
    log "OIDC provider exists but lacks the sts.amazonaws.com audience — adding it…"
    aws iam add-client-id-to-open-id-connect-provider \
      --open-id-connect-provider-arn "$PROVIDER" \
      --client-id sts.amazonaws.com
  fi
else
  log "Registering GitHub as an OIDC provider…"
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com >/dev/null
fi

# ---- 2. Role, trusted only by this repo's production environment ----------
# The workflow job declares `environment: production`, which puts the
# environment form in the token's subject claim. Branch refs will not match.
SUB="repo:${REPO}:environment:${ENVIRONMENT}"
TRUST="$(jq -n --arg p "$PROVIDER" --arg s "$SUB" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: { Federated: $p },
    Action: "sts:AssumeRoleWithWebIdentity",
    Condition: { StringEquals: {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": $s } }
  }] }')"

if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  log "Role ${ROLE} exists; refreshing its trust policy…"
  aws iam update-assume-role-policy --role-name "$ROLE" \
    --policy-document "$TRUST"
else
  log "Creating role ${ROLE}…"
  aws iam create-role --role-name "$ROLE" \
    --description "Deploys ${DOMAIN} from GitHub Actions" \
    --assume-role-policy-document "$TRUST" >/dev/null
fi

# ---- 3. Least-privilege policy, scoped to this bucket and distribution ----
log "Looking up the CloudFront distribution for ${DOMAIN}…"
DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '${DOMAIN}')].Id | [0]" \
  --output text 2>/dev/null || echo None)"
[[ -n "$DIST_ID" && "$DIST_ID" != "None" ]] || \
  die "No CloudFront distribution found for ${DOMAIN}. Run ./deploy.sh first."
log "Distribution: ${DIST_ID}"

aws iam put-role-policy --role-name "$ROLE" --policy-name site-deploy \
  --policy-document "$(jq -n --arg b "$DOMAIN" --arg a "$ACCOUNT" --arg d "$DIST_ID" '{
    Version: "2012-10-17",
    Statement: [
      { Sid: "SyncSiteObjects", Effect: "Allow",
        Action: ["s3:GetObject","s3:PutObject","s3:DeleteObject"],
        Resource: ("arn:aws:s3:::" + $b + "/*") },
      { Sid: "ListBucketForSync", Effect: "Allow",
        Action: "s3:ListBucket",
        Resource: ("arn:aws:s3:::" + $b) },
      { Sid: "InvalidateCache", Effect: "Allow",
        Action: "cloudfront:CreateInvalidation",
        Resource: ("arn:aws:cloudfront::" + $a + ":distribution/" + $d) }
    ] }')"
log "Permissions attached."

ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

# Echo what is actually in place. If a deploy still fails with
# "Not authorized to perform sts:AssumeRoleWithWebIdentity", these two lines
# are what to compare: the audience must contain sts.amazonaws.com, and the
# subject must equal the workflow's repo + environment exactly.
log "Verifying what was configured:"
printf '    provider audiences : %s\n' \
  "$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER" \
     --query 'ClientIDList' --output text)"
printf '    trust subject      : %s\n' \
  "$(aws iam get-role --role-name "$ROLE" \
     --query 'AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:sub"' \
     --output text)"
printf '    expected subject   : %s\n' "$SUB"

cat <<OUT

$(printf '\033[1;32m==>\033[0m') AWS side is done. Two secrets left, and they are the last manual step.

Open:  https://github.com/${REPO}/settings/secrets/actions

  AWS_DEPLOY_ROLE_ARN          ${ROLE_ARN}
  CLOUDFRONT_DISTRIBUTION_ID   ${DIST_ID}

Then create the environment (once):
  https://github.com/${REPO}/settings/environments  ->  New environment  ->  production

After that, every merge to main deploys itself -- from your phone, from
anywhere. Re-run a failed deploy at:
  https://github.com/${REPO}/actions
OUT
