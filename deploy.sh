#!/usr/bin/env bash
#
# deploy.sh — provision (idempotent) and deploy the static site to
# S3 + CloudFront with a custom domain, in AWS account 594041868357.
#
# What it does, only creating what is missing:
#   1. Verifies you are authenticated to the correct account.
#   2. Creates a private S3 bucket (Block Public Access on).
#   3. Requests/reuses an ACM certificate (us-east-1) for the domain + www,
#      auto-validating via Route 53 if the hosted zone lives in this account,
#      otherwise printing the DNS records for you to add.
#   4. Creates/reuses a CloudFront distribution fronting the bucket via an
#      Origin Access Control (OAC); the bucket stays private.
#   5. Attaches a bucket policy scoped to that one distribution.
#   6. Syncs ./ (site files) to the bucket with sensible cache headers:
#      images/ long-cached and immutable, other root assets (favicon,
#      robots.txt, og image, …) hourly, index.html short-cached.
#   7. Invalidates only the paths this run actually changed.
#   8. Prints the DNS records to point the domain at CloudFront.
#
# Re-runs are safe: existing resources are detected and reused, and normally
# only steps 6–7 (sync + invalidate) do real work.
#
# Usage:
#   ./deploy.sh                 # full provision + deploy
#   ./deploy.sh --sync-only     # skip provisioning, just sync + invalidate
#
set -euo pipefail

# ------------------------------------------------------------------ config ---
EXPECTED_ACCOUNT="594041868357"
DOMAIN="dennisschoenfelder.com"
ALT_DOMAIN="www.${DOMAIN}"
BUCKET="${BUCKET:-${DOMAIN}}"             # bucket is private; name is just a label
REGION="us-east-1"                        # ACM for CloudFront MUST be us-east-1
SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_COMMENT="${DOMAIN} static site"
OAC_NAME="${DOMAIN}-oac"

# Locally this runs under a named profile. Under GitHub Actions the OIDC
# action puts short-lived credentials in the environment and there is no
# profile to name — passing --profile there would fail every call — so the
# flag is only added when a profile is actually in play.
if [[ -n "${AWS_PROFILE:-}" ]]; then
  CRED_DESC="profile: ${AWS_PROFILE}"                     # caller named one
elif [[ -n "${AWS_ACCESS_KEY_ID:-}${AWS_ROLE_ARN:-}${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ]]; then
  AWS_PROFILE=""; CRED_DESC="credentials from the environment"
else
  AWS_PROFILE="personal"; CRED_DESC="profile: personal"   # local default
fi

PROFILE_ARGS=()
if [[ -n "$AWS_PROFILE" ]]; then
  PROFILE_ARGS=(--profile "$AWS_PROFILE"); export AWS_PROFILE
else
  unset AWS_PROFILE
fi

export AWS_DEFAULT_REGION="$REGION"
aws() { command aws ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --region "$REGION" "$@"; }

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

SYNC_ONLY=false
[[ "${1:-}" == "--sync-only" ]] && SYNC_ONLY=true

# ------------------------------------------------------------- preflight ---
command -v aws >/dev/null || die "aws CLI not found."
command -v jq  >/dev/null || die "jq not found (brew install jq)."

log "Verifying credentials for account ${EXPECTED_ACCOUNT} (${CRED_DESC})…"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[[ -n "$ACCOUNT" ]] || die "Could not authenticate (${CRED_DESC}). Refresh the credentials, or set AWS_PROFILE=<profile>."
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || die "Authenticated to account ${ACCOUNT}, expected ${EXPECTED_ACCOUNT} (${CRED_DESC}). Aborting to avoid deploying to the wrong account."
log "Authenticated to ${ACCOUNT}."

# =============================================================== provision ===
if [[ "$SYNC_ONLY" == false ]]; then

  # ---- S3 bucket (private) --------------------------------------------------
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    log "Bucket s3://${BUCKET} already exists."
  else
    log "Creating private bucket s3://${BUCKET}…"
    # us-east-1 must NOT pass a LocationConstraint
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
    aws s3api put-public-access-block --bucket "$BUCKET" \
      --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-encryption --bucket "$BUCKET" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  fi

  # ---- ACM certificate (us-east-1, DNS validation) -------------------------
  log "Finding/requesting ACM certificate for ${DOMAIN}…"
  CERT_ARN="$(aws acm list-certificates --certificate-statuses PENDING_VALIDATION ISSUED \
      --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
      --output text)"
  if [[ -z "$CERT_ARN" || "$CERT_ARN" == "None" ]]; then
    log "Requesting new certificate (${DOMAIN}, ${ALT_DOMAIN})…"
    CERT_ARN="$(aws acm request-certificate \
      --domain-name "$DOMAIN" \
      --subject-alternative-names "$ALT_DOMAIN" \
      --validation-method DNS \
      --query CertificateArn --output text)"
    sleep 5   # let the validation options populate
  fi
  log "Certificate: ${CERT_ARN}"

  # Look up hosted zone (if the domain is managed by Route 53 in this account)
  HZ_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
      --query "HostedZones[?Name=='${DOMAIN}.'].Id | [0]" --output text 2>/dev/null || echo None)"
  HZ_ID="${HZ_ID##*/}"

  CERT_STATUS="$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
      --query Certificate.Status --output text)"
  if [[ "$CERT_STATUS" != "ISSUED" ]]; then
    log "Certificate is ${CERT_STATUS}; DNS validation records:"
    aws acm describe-certificate --certificate-arn "$CERT_ARN" \
      --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output table

    if [[ -n "$HZ_ID" && "$HZ_ID" != "None" ]]; then
      log "Hosted zone ${HZ_ID} found — upserting validation CNAMEs automatically…"
      aws acm describe-certificate --certificate-arn "$CERT_ARN" \
        --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output json \
      | jq -c 'unique_by(.Name) | .[]' | while read -r rr; do
          name="$(jq -r .Name <<<"$rr")"; value="$(jq -r .Value <<<"$rr")"
          aws route53 change-resource-record-sets --hosted-zone-id "$HZ_ID" \
            --change-batch "$(jq -n --arg n "$name" --arg v "$value" \
              '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$n,Type:"CNAME",TTL:300,ResourceRecords:[{Value:$v}]}}]}')" >/dev/null
        done
      log "Waiting for certificate to be issued (up to ~10 min)…"
      aws acm wait certificate-validated --certificate-arn "$CERT_ARN"
    else
      warn "Domain not in Route 53 for this account. Add the CNAME record(s) above at your DNS provider,"
      warn "then re-run this script. Exiting until the certificate is validated."
      exit 0
    fi
  fi
  log "Certificate is ISSUED."

  # ---- Origin Access Control (OAC) -----------------------------------------
  OAC_ID="$(aws cloudfront list-origin-access-controls \
      --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" --output text)"
  if [[ -z "$OAC_ID" || "$OAC_ID" == "None" ]]; then
    log "Creating Origin Access Control…"
    OAC_ID="$(aws cloudfront create-origin-access-control \
      --origin-access-control-config \
      "Name=${OAC_NAME},SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
      --query OriginAccessControl.Id --output text)"
  fi
  log "OAC: ${OAC_ID}"

  # ---- CloudFront distribution ---------------------------------------------
  DIST_ID="$(aws cloudfront list-distributions \
      --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '${DOMAIN}')].Id | [0]" \
      --output text 2>/dev/null || echo None)"

  if [[ -z "$DIST_ID" || "$DIST_ID" == "None" ]]; then
    log "Creating CloudFront distribution…"
    S3_DOMAIN="${BUCKET}.s3.${REGION}.amazonaws.com"
    CALLER_REF="${DOMAIN}-$(date +%s)"
    DIST_CONFIG="$(jq -n \
      --arg ref "$CALLER_REF" --arg comment "$CF_COMMENT" \
      --arg origin "$S3_DOMAIN" --arg oac "$OAC_ID" \
      --arg d1 "$DOMAIN" --arg d2 "$ALT_DOMAIN" --arg cert "$CERT_ARN" '
    {
      CallerReference: $ref,
      Comment: $comment,
      Enabled: true,
      DefaultRootObject: "index.html",
      Aliases: { Quantity: 2, Items: [$d1, $d2] },
      Origins: { Quantity: 1, Items: [ {
        Id: "s3-origin",
        DomainName: $origin,
        OriginAccessControlId: $oac,
        S3OriginConfig: { OriginAccessIdentity: "" }
      } ] },
      DefaultCacheBehavior: {
        TargetOriginId: "s3-origin",
        ViewerProtocolPolicy: "redirect-to-https",
        Compress: true,
        AllowedMethods: { Quantity: 2, Items: ["GET","HEAD"],
          CachedMethods: { Quantity: 2, Items: ["GET","HEAD"] } },
        CachePolicyId: "658327ea-f89d-4fab-a63d-7e88639e58f6"
      },
      CustomErrorResponses: { Quantity: 1, Items: [ {
        ErrorCode: 403, ResponseCode: "404",
        ResponsePagePath: "/index.html", ErrorCachingMinTTL: 10
      } ] },
      ViewerCertificate: {
        ACMCertificateArn: $cert, SSLSupportMethod: "sni-only",
        MinimumProtocolVersion: "TLSv1.2_2021"
      },
      PriceClass: "PriceClass_100",
      HttpVersion: "http2and3"
    }')"
    DIST_ID="$(aws cloudfront create-distribution \
      --distribution-config "$DIST_CONFIG" --query Distribution.Id --output text)"
  else
    log "CloudFront distribution already exists."
  fi
  DIST_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" \
      --query Distribution.DomainName --output text)"
  log "Distribution: ${DIST_ID} (${DIST_DOMAIN})"

  # ---- Bucket policy scoped to this distribution ---------------------------
  log "Applying bucket policy for CloudFront OAC…"
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(jq -n \
    --arg bucket "$BUCKET" --arg acct "$EXPECTED_ACCOUNT" --arg dist "$DIST_ID" '
    { Version: "2012-10-17", Statement: [ {
      Sid: "AllowCloudFrontOAC",
      Effect: "Allow",
      Principal: { Service: "cloudfront.amazonaws.com" },
      Action: "s3:GetObject",
      Resource: ("arn:aws:s3:::" + $bucket + "/*"),
      Condition: { StringEquals: {
        "AWS:SourceArn": ("arn:aws:cloudfront::" + $acct + ":distribution/" + $dist) } }
    } ] }')"

  # Persist IDs so --sync-only can find them later
  cat > "${SITE_DIR}/.deploy.env" <<EOF
BUCKET=${BUCKET}
DIST_ID=${DIST_ID}
DIST_DOMAIN=${DIST_DOMAIN}
CERT_ARN=${CERT_ARN}
EOF
fi

# =================================================================== deploy ===
if [[ "$SYNC_ONLY" == true ]]; then
  # .deploy.env is written by a full local run and is gitignored, so a CI
  # checkout never has one; there DIST_ID arrives from the environment.
  if [[ -f "${SITE_DIR}/.deploy.env" ]]; then
    # shellcheck disable=SC1091
    source "${SITE_DIR}/.deploy.env"
  fi
  [[ -n "${DIST_ID:-}" ]] || die "--sync-only needs DIST_ID: run a full deploy first (writes .deploy.env), or set DIST_ID in the environment."
fi

log "Syncing site files to s3://${BUCKET}…"

# Sync output is captured so the invalidation below can target only what
# changed; it is echoed straight back so the log still shows every transfer.
# Long-cache the immutable image assets…
IMG_OUT="$(aws s3 sync "${SITE_DIR}/images/" "s3://${BUCKET}/images/" \
  --delete --cache-control "public, max-age=31536000, immutable" \
  --exclude ".*" --no-progress)"
[[ -n "$IMG_OUT" ]] && printf '%s\n' "$IMG_OUT"

# …deploy the rest of the site root too (favicon.ico, robots.txt, the og
# image, any future page), skipping repo plumbing and the two prefixes that
# get their own cache headers above and below. Without this, anything added
# at the root would silently never reach the bucket.
ROOT_OUT="$(aws s3 sync "${SITE_DIR}/" "s3://${BUCKET}/" \
  --delete --cache-control "public, max-age=3600" \
  --exclude ".*" \
  --exclude ".git/*" \
  --exclude ".deploy.env" \
  --exclude "images/*" \
  --exclude "index.html" \
  --exclude "deploy.sh" \
  --exclude "*.md" --no-progress)"
[[ -n "$ROOT_OUT" ]] && printf '%s\n' "$ROOT_OUT"

# …short-cache the HTML so edits go live quickly.
aws s3 cp "${SITE_DIR}/index.html" "s3://${BUCKET}/index.html" \
  --cache-control "public, max-age=300" --content-type "text/html; charset=utf-8"

# Invalidate index.html (always, since it is re-uploaded every run) plus any
# long-cached asset this run added, changed, or removed. A blanket /* would
# purge the year-long image cache on every deploy, forcing CloudFront to
# re-pull megabytes from S3 to serve bytes it already had.
INVAL_PATHS=("/index.html")
while IFS= read -r key; do
  [[ -n "$key" ]] && INVAL_PATHS+=("/${key}")
done < <(printf '%s\n%s\n' "$IMG_OUT" "$ROOT_OUT" \
  | sed -nE "s#^(upload|copy|delete): .*s3://${BUCKET}/(.+)\$#\2#p" \
  | sort -u)

# Past ~15 paths a wildcard is cheaper than enumerating them (CloudFront
# bills per path, and /* counts as one).
if (( ${#INVAL_PATHS[@]} > 15 )); then
  log "${#INVAL_PATHS[@]} paths changed — invalidating /* instead."
  INVAL_PATHS=("/*")
fi

log "Invalidating ${#INVAL_PATHS[@]} path(s): ${INVAL_PATHS[*]}"
INVAL_ID="$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" \
  --paths "${INVAL_PATHS[@]}" --query Invalidation.Id --output text)"
log "Invalidation ${INVAL_ID} created."

# =================================================================== summary ==
echo
log "Deploy complete."
echo "  CloudFront URL : https://${DIST_DOMAIN}"
echo "  Site URL       : https://${DOMAIN}"
echo
echo "Point your DNS at CloudFront (if not already):"
echo "  ${DOMAIN}      ALIAS/ANAME/A  -> ${DIST_DOMAIN}"
echo "  ${ALT_DOMAIN}  CNAME          -> ${DIST_DOMAIN}"
echo "(Route 53: create A/AAAA 'alias' records to the distribution. Other DNS"
echo " hosts: use ALIAS/ANAME for the apex and CNAME for www.)"
