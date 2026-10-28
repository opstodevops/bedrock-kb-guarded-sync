# Shared settings for the guarded sync sample. Source it in every new shell:
#
#   source scripts/env.sh
#
# It also looks up the IDs of resources that already exist, so you can open a new
# shell at any step of the README and continue.

export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_PAGER=""
export PREFIX="${PREFIX:-ragrestore}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || return 1 2>/dev/null || exit 1
export ACCOUNT_ID

export SOURCE_BUCKET="${PREFIX}-source-${ACCOUNT_ID}"
export MANIFEST_BUCKET="${PREFIX}-manifests-${ACCOUNT_ID}"
export VECTOR_BUCKET="${PREFIX}-vectors"
export INDEX_NAME="policies-v1"
export INDEX_ARN="arn:aws:s3vectors:${AWS_REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}/index/${INDEX_NAME}"

# Generation model (answers the canary questions) and judge model (checks assertions, triages).
export GEN_MODEL="${GEN_MODEL:-anthropic.claude-haiku-5-5}"
export JUDGE_MODEL="${JUDGE_MODEL:-anthropic.claude-sonnet-5-5}"
export GEN_MODEL_ARN="arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:inference-profile/global.${GEN_MODEL}"
export JUDGE_MODEL_ID="global.${JUDGE_MODEL}"

# Reserved for emergency recovery: the only principal that can delete object versions in the
# source bucket. The role doesn't have to exist.
export BREAKGLASS_ROLE_ARN="${BREAKGLASS_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-breakglass-role}"

# Every resource that supports tags gets this tag.
export TAG_KEY="project"
export TAG_VALUE="${PREFIX}-guarded-sync"

# IDs of resources created in later steps (empty until they exist)
_none() { [ "$1" = "None" ] && echo "" || echo "$1"; }
KB_ID="$(_none "$(aws bedrock-agent list-knowledge-bases \
  --query "knowledgeBaseSummaries[?name=='${PREFIX}-kb'].knowledgeBaseId | [0]" --output text)")"
DS_ID=""
if [ -n "$KB_ID" ]; then
  DS_ID="$(_none "$(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" \
    --query "dataSourceSummaries[?name=='policy-docs'].dataSourceId | [0]" --output text)")"
fi
INSPECT_FN_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${PREFIX}-inspect"
ROLLBACK_FN_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${PREFIX}-rollback"
TOPIC_ARN="arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:${PREFIX}-kb-integrity-alerts"
SM_ARN="arn:aws:states:${AWS_REGION}:${ACCOUNT_ID}:stateMachine:${PREFIX}-guarded-sync"
export KB_ID DS_ID INSPECT_FN_ARN ROLLBACK_FN_ARN TOPIC_ARN SM_ARN

# Fill ${VAR} placeholders in a template and print the path of the rendered copy. The explicit
# variable list leaves JSONPath expressions such as $.sync.jobId in the state machine untouched.
RENDER_VARS='${AWS_REGION} ${ACCOUNT_ID} ${PREFIX} ${SOURCE_BUCKET} ${MANIFEST_BUCKET} ${VECTOR_BUCKET} ${KB_ID} ${DS_ID} ${GEN_MODEL} ${JUDGE_MODEL} ${INSPECT_FN_ARN} ${ROLLBACK_FN_ARN} ${TOPIC_ARN} ${BREAKGLASS_ROLE_ARN}'
render() {
  mkdir -p /tmp/rendered
  envsubst "$RENDER_VARS" < "$1" > "/tmp/rendered/$(basename "$1")"
  echo "/tmp/rendered/$(basename "$1")"
}
