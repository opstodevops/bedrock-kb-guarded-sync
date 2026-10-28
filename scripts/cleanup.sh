#!/usr/bin/env bash
# Deletes everything that scripts/deploy.sh and the README steps create, including knowledge
# bases, indexes, and restored buckets left over from recovery drills. Safe to run more than once.
#
#   ./scripts/cleanup.sh
#
# Settings come from scripts/env.sh. Recovery points in the logically air-gapped vault can't be
# deleted before they expire, so that vault may remain (the script tells you).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/env.sh
step() { echo; echo "==> $*"; }
try() {  # run a command, and report instead of failing if the resource is already gone
  local out
  if ! out=$("$@" 2>&1); then echo "  skipped: $(echo "$out" | grep -v '^$' | tail -1)"; fi
}

step "Workflow, functions, logs, and topic"
try aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN"
for fn in inspect rollback; do
  try aws lambda delete-function --function-name "${PREFIX}-${fn}"
  try aws logs delete-log-group --log-group-name "/aws/lambda/${PREFIX}-${fn}"
done
try aws sns delete-topic --topic-arn "$TOPIC_ARN"

step "Knowledge bases (including any rebuilt in recovery drills)"
try aws s3vectors delete-vector-bucket-policy --vector-bucket-name "$VECTOR_BUCKET"
for kb in $(aws bedrock-agent list-knowledge-bases \
    --query "knowledgeBaseSummaries[?starts_with(name,'${PREFIX}-')].knowledgeBaseId" --output text); do
  for ds in $(aws bedrock-agent list-data-sources --knowledge-base-id "$kb" \
      --query 'dataSourceSummaries[].dataSourceId' --output text); do
    try aws bedrock-agent delete-data-source --knowledge-base-id "$kb" --data-source-id "$ds"
    while aws bedrock-agent get-data-source --knowledge-base-id "$kb" --data-source-id "$ds" > /dev/null 2>&1; do sleep 5; done
  done
  try aws bedrock-agent delete-knowledge-base --knowledge-base-id "$kb"
  while aws bedrock-agent get-knowledge-base --knowledge-base-id "$kb" > /dev/null 2>&1; do sleep 5; done
  echo "  deleted knowledge base $kb"
done

step "Vector indexes and vector bucket"
for idx in $(aws s3vectors list-indexes --vector-bucket-name "$VECTOR_BUCKET" \
    --query 'indexes[].indexName' --output text 2>/dev/null); do
  try aws s3vectors delete-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$idx"
done
try aws s3vectors delete-vector-bucket --vector-bucket-name "$VECTOR_BUCKET"

empty_and_delete_bucket() {  # $1 = bucket, $2 = optional extra flag for delete-objects
  aws s3api head-bucket --bucket "$1" > /dev/null 2>&1 || { echo "  skipped: $1 doesn't exist"; return; }
  try aws s3api delete-bucket-policy --bucket "$1"
  while true; do
    aws s3api list-object-versions --bucket "$1" --max-items 1000 --output json \
      | jq '{Objects: [((.Versions // [])[], (.DeleteMarkers // [])[]) | {Key, VersionId}], Quiet: true}' > /tmp/delete.json
    [ "$(jq '.Objects | length' /tmp/delete.json)" -eq 0 ] && break
    aws s3api delete-objects --bucket "$1" --delete file:///tmp/delete.json ${2:-} > /dev/null || break
  done
  try aws s3api delete-bucket --bucket "$1"
  echo "  deleted bucket $1"
}

step "S3 buckets (the deny policy is removed first)"
empty_and_delete_bucket "$SOURCE_BUCKET"
for b in $(aws s3api list-buckets --prefix "${PREFIX}-restored-" --query 'Buckets[].Name' --output text); do
  empty_and_delete_bucket "$b"
done
# Manifests are under GOVERNANCE Object Lock (1 day); deleting them needs s3:BypassGovernanceRetention.
empty_and_delete_bucket "$MANIFEST_BUCKET" --bypass-governance-retention

step "AWS Backup"
for plan in $(aws backup list-backup-plans \
    --query "BackupPlansList[?BackupPlanName=='${PREFIX}-kb-source-plan'].BackupPlanId" --output text); do
  for sel in $(aws backup list-backup-selections --backup-plan-id "$plan" \
      --query 'BackupSelectionsList[].SelectionId' --output text); do
    try aws backup delete-backup-selection --backup-plan-id "$plan" --selection-id "$sel"
  done
  try aws backup delete-backup-plan --backup-plan-id "$plan"
done
for vault in "${PREFIX}-vault" "${PREFIX}-airgapped"; do
  aws backup describe-backup-vault --backup-vault-name "$vault" > /dev/null 2>&1 || continue
  for rp in $(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" \
      --query 'RecoveryPoints[].RecoveryPointArn' --output text); do
    try aws backup delete-recovery-point --backup-vault-name "$vault" --recovery-point-arn "$rp"
  done
  # Recovery point deletion is asynchronous; wait up to 2 minutes for the vault to empty.
  for _ in $(seq 1 12); do
    [ "$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" \
          --query "length(RecoveryPoints[?Status!='DELETING'])" --output text)" = "0" ] || break
    [ "$(aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" \
          --query 'length(RecoveryPoints)' --output text)" = "0" ] && break
    sleep 10
  done
  if aws backup delete-backup-vault --backup-vault-name "$vault" 2>/dev/null; then
    echo "  deleted vault $vault"
  else
    echo "  kept vault $vault: it still holds locked recovery points. Run this script again after they expire:"
    aws backup list-recovery-points-by-backup-vault --backup-vault-name "$vault" \
      --query 'RecoveryPoints[].{resource:ResourceName,deleteAt:CalculatedLifecycle.DeleteAt}' --output table
  fi
done

step "IAM roles"
for r in kb inspect rollback sfn backup; do
  role="${PREFIX}-${r}-role"
  aws iam get-role --role-name "$role" > /dev/null 2>&1 || continue
  for p in $(aws iam list-role-policies --role-name "$role" --query PolicyNames --output text); do
    try aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  for a in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    try aws iam detach-role-policy --role-name "$role" --policy-arn "$a"
  done
  try aws iam delete-role --role-name "$role"
  echo "  deleted role $role"
done

step "Local build output"
rm -rf build guard.zip sample-data/corpus /tmp/rendered

step "Tagged resources that remain ($TAG_KEY=$TAG_VALUE)"
aws resourcegroupstaggingapi get-resources --tag-filters "Key=$TAG_KEY,Values=$TAG_VALUE" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n'
echo "(The tagging API can take a few minutes to drop deleted resources.)"
