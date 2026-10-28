#!/usr/bin/env bash
# Deploys the guarded sync sample with the AWS CLI. It runs README Steps 1 to 8 (and Step 9
# with --backup) in order, then runs the first guarded sync to record a GOOD recovery point.
#
#   ./scripts/deploy.sh [--email you@example.com] [--backup]
#
#   --email   Subscribe an email address to the alert topic (confirm the email you receive).
#   --backup  Also create the AWS Backup role, vaults, plan, and selection (README Step 9).
#
# Settings come from scripts/env.sh (PREFIX, AWS_REGION, models). If a run fails part way,
# run ./scripts/cleanup.sh and then run this script again.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

EMAIL=""
BACKUP="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) EMAIL="$2"; shift 2 ;;
    --backup) BACKUP="true"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

source scripts/env.sh
step() { echo; echo "==> $*"; }

if [ -n "$KB_ID" ] || aws s3api head-bucket --bucket "$SOURCE_BUCKET" > /dev/null 2>&1; then
  echo "Resources with prefix '$PREFIX' already exist. Run ./scripts/cleanup.sh first." >&2
  exit 1
fi
create_bucket() {  # us-east-1 doesn't accept a LocationConstraint
  if [ "$AWS_REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$@" > /dev/null
  else aws s3api create-bucket --bucket "$@" --create-bucket-configuration "LocationConstraint=$AWS_REGION" > /dev/null; fi
}

step "Step 1: S3 buckets"
create_bucket "$SOURCE_BUCKET"
aws s3api put-bucket-versioning --bucket "$SOURCE_BUCKET" --versioning-configuration Status=Enabled
create_bucket "$MANIFEST_BUCKET" --object-lock-enabled-for-bucket
aws s3api put-object-lock-configuration --bucket "$MANIFEST_BUCKET" \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":1}}}'
for b in "$SOURCE_BUCKET" "$MANIFEST_BUCKET"; do
  aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$b" --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VALUE}]"
done

step "Step 2: vector bucket and index"
aws s3vectors create-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" --tags "$TAG_KEY=$TAG_VALUE" > /dev/null
aws s3vectors create-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$INDEX_NAME" \
  --data-type float32 --dimension 1024 --distance-metric cosine \
  --metadata-configuration '{"nonFilterableMetadataKeys":["AMAZON_BEDROCK_TEXT","AMAZON_BEDROCK_METADATA"]}' \
  --tags "$TAG_KEY=$TAG_VALUE" > /dev/null

step "Step 3: knowledge base and data source"
aws iam create-role --role-name "${PREFIX}-kb-role" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
  --assume-role-policy-document "file://$(render policies/kb-trust.json)" > /dev/null
aws iam put-role-policy --role-name "${PREFIX}-kb-role" --policy-name kb-access \
  --policy-document "file://$(render policies/kb-permissions.json)"
sleep 15   # allow IAM to propagate
KB_ID=$(aws bedrock-agent create-knowledge-base --name "${PREFIX}-kb" \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-kb-role" \
  --knowledge-base-configuration '{"type":"VECTOR","vectorKnowledgeBaseConfiguration":{
      "embeddingModelArn":"arn:aws:bedrock:'"$AWS_REGION"'::foundation-model/amazon.titan-embed-text-v2:0",
      "embeddingModelConfiguration":{"bedrockEmbeddingModelConfiguration":{"dimensions":1024,"embeddingDataType":"FLOAT32"}}}}' \
  --storage-configuration '{"type":"S3_VECTORS","s3VectorsConfiguration":{"indexArn":"'"$INDEX_ARN"'"}}' \
  --tags "$TAG_KEY=$TAG_VALUE" --query knowledgeBase.knowledgeBaseId --output text)
export KB_ID
while [ "$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" --query knowledgeBase.status --output text)" = "CREATING" ]; do sleep 3; done
DS_ID=$(aws bedrock-agent create-data-source --knowledge-base-id "$KB_ID" --name policy-docs \
  --data-deletion-policy DELETE \
  --data-source-configuration '{"type":"S3","s3Configuration":{"bucketArn":"arn:aws:s3:::'"$SOURCE_BUCKET"'","bucketOwnerAccountId":"'"$ACCOUNT_ID"'"}}' \
  --vector-ingestion-configuration '{"chunkingConfiguration":{"chunkingStrategy":"FIXED_SIZE","fixedSizeChunkingConfiguration":{"maxTokens":300,"overlapPercentage":20}}}' \
  --query dataSource.dataSourceId --output text)
export DS_ID
echo "KB_ID=$KB_ID DS_ID=$DS_ID"

step "Step 4: sample documents and golden set"
python3 scripts/make_sample_corpus.py
aws s3 sync sample-data/corpus "s3://$SOURCE_BUCKET/" --content-type text/markdown --only-show-errors
aws s3api put-object --bucket "$MANIFEST_BUCKET" --key canary/golden-set.json \
  --body sample-data/golden-set.json --content-type application/json --checksum-algorithm SHA256 > /dev/null

step "Step 5: Lambda functions"
rm -rf build guard.zip && mkdir build
pip3 install --quiet --target build/ --platform manylinux2014_aarch64 --python-version 3.13 \
  --only-binary=:all: --requirement lambda/requirements.txt
cp lambda/guard.py lambda/kb-prompts.json build/
(cd build && zip -qr ../guard.zip .)
for fn in inspect rollback; do
  aws iam create-role --role-name "${PREFIX}-${fn}-role" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
    --assume-role-policy-document "file://$(render policies/lambda-trust.json)" > /dev/null
  aws iam put-role-policy --role-name "${PREFIX}-${fn}-role" --policy-name least-privilege \
    --policy-document "file://$(render "policies/${fn}-permissions.json")"
  aws iam attach-role-policy --role-name "${PREFIX}-${fn}-role" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
done
sleep 15   # allow IAM to propagate
make_env() {  # $1 = comma-separated ALLOWED_ACTIONS
  jq -n --arg kb "$KB_ID" --arg ds "$DS_ID" --arg src "$SOURCE_BUCKET" --arg man "$MANIFEST_BUCKET" \
    --arg gen "$GEN_MODEL_ARN" --arg judge "$JUDGE_MODEL_ID" --arg actions "$1" \
    '{Variables:{KB_ID:$kb,DS_ID:$ds,SOURCE_BUCKET:$src,MANIFEST_BUCKET:$man,
                 GEN_MODEL_ARN:$gen,JUDGE_MODEL_ID:$judge,ALLOWED_ACTIONS:$actions}}'
}
make_env "capture_manifest,canary,triage" > /tmp/inspect-env.json
make_env "rollback" > /tmp/rollback-env.json
aws lambda create-function --function-name "${PREFIX}-inspect" \
  --runtime python3.13 --architectures arm64 --handler guard.handler \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-inspect-role" \
  --zip-file fileb://guard.zip --timeout 300 --memory-size 512 \
  --environment file:///tmp/inspect-env.json --tags "$TAG_KEY=$TAG_VALUE" > /dev/null
aws lambda create-function --function-name "${PREFIX}-rollback" \
  --runtime python3.13 --architectures arm64 --handler guard.handler \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-rollback-role" \
  --zip-file fileb://guard.zip --timeout 60 --memory-size 512 \
  --environment file:///tmp/rollback-env.json --tags "$TAG_KEY=$TAG_VALUE" > /dev/null
aws lambda wait function-active-v2 --function-name "${PREFIX}-inspect"
aws lambda wait function-active-v2 --function-name "${PREFIX}-rollback"

step "Step 6: notification topic and state machine"
aws sns create-topic --name "${PREFIX}-kb-integrity-alerts" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" > /dev/null
if [ -n "$EMAIL" ]; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" > /dev/null
  echo "Confirm the subscription in the email sent to $EMAIL."
fi
aws iam create-role --role-name "${PREFIX}-sfn-role" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
  --assume-role-policy-document "file://$(render policies/sfn-trust.json)" > /dev/null
aws iam put-role-policy --role-name "${PREFIX}-sfn-role" --policy-name guarded-sync \
  --policy-document "file://$(render policies/sfn-permissions.json)"
sleep 15   # allow IAM to propagate
aws stepfunctions validate-state-machine-definition \
  --definition "file://$(render statemachine/guarded-sync.asl.json)" --query result --output text
aws stepfunctions create-state-machine --name "${PREFIX}-guarded-sync" --type STANDARD \
  --definition "file://$(render statemachine/guarded-sync.asl.json)" \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-sfn-role" \
  --tags "key=$TAG_KEY,value=$TAG_VALUE" > /dev/null

step "Step 7: first guarded sync (baseline)"
EXEC_ARN=$(./scripts/run-guarded-sync.sh | tail -1)
STATUS=$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query status --output text)
if [ "$STATUS" != "SUCCEEDED" ]; then
  echo "The baseline guarded sync didn't succeed ($STATUS). See README Troubleshooting." >&2
  exit 1
fi

step "Step 8: protect the recovery history"
aws s3api put-bucket-policy --bucket "$SOURCE_BUCKET" --policy "file://$(render policies/source-bucket-policy.json)"
aws s3vectors put-vector-bucket-policy --vector-bucket-name "$VECTOR_BUCKET" \
  --policy "file://$(render policies/vector-bucket-policy.json)"

if [ "$BACKUP" = "true" ]; then
  step "Step 9: AWS Backup"
  aws iam create-role --role-name "${PREFIX}-backup-role" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
    --assume-role-policy-document file://policies/backup-trust.json > /dev/null
  for p in service-role/AWSBackupServiceRolePolicyForBackup service-role/AWSBackupServiceRolePolicyForRestores \
           AWSBackupServiceRolePolicyForS3Backup AWSBackupServiceRolePolicyForS3Restore; do
    aws iam attach-role-policy --role-name "${PREFIX}-backup-role" --policy-arn "arn:aws:iam::aws:policy/$p"
  done
  aws backup create-backup-vault --backup-vault-name "${PREFIX}-vault" \
    --backup-vault-tags "$TAG_KEY=$TAG_VALUE" > /dev/null
  aws backup create-logically-air-gapped-backup-vault --backup-vault-name "${PREFIX}-airgapped" \
    --min-retention-days 7 --max-retention-days 35 --backup-vault-tags "$TAG_KEY=$TAG_VALUE" > /dev/null
  sleep 15   # allow IAM to propagate
  BACKUP_PLAN_ID=$(aws backup create-backup-plan --backup-plan "file://$(render backup/backup-plan.json)" \
    --backup-plan-tags "$TAG_KEY=$TAG_VALUE" --query BackupPlanId --output text)
  aws backup create-backup-selection --backup-plan-id "$BACKUP_PLAN_ID" \
    --backup-selection "file://$(render backup/backup-selection.json)" > /dev/null
fi

echo
echo "Deployed. Knowledge base $KB_ID, data source $DS_ID, state machine $SM_ARN."
echo "Next: README Step 10 (simulate a poisoning attack)."
