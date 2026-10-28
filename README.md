# Guarded sync for Amazon Bedrock Knowledge Bases

Sample code for the blog post [Recover an Amazon Bedrock knowledge base to a known-good point in time](docs/blog-post.md).

Every sync of the knowledge base goes through an AWS Step Functions state machine. The workflow verifies the sync with an integrity canary and records a recovery point. When a sync fails verification, Amazon Bedrock triages what changed, and the workflow rolls back only the harmful changes, then verifies again. Resource policies and AWS Backup protect the recovery history itself.

The architecture diagram source is [`docs/architecture.drawio`](docs/architecture.drawio).

> [!WARNING]
> This is sample code for learning and testing. Review the IAM policies, retention settings, and model choices before you use it in production. You're responsible for the costs of the resources you create. To avoid ongoing charges, follow [Clean up](#clean-up) when you're finished.

## Contents

- [What gets deployed](#what-gets-deployed)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Step-by-step deployment](#step-by-step-deployment) (Steps 0 to 9)
- [Step 10: Simulate a poisoning attack](#step-10-simulate-a-poisoning-attack)
- [Step 11: Test the side-door protections](#step-11-test-the-side-door-protections)
- [Step 12: Run the recovery drills (Tiers 2 and 3)](#step-12-run-the-recovery-drills-tiers-2-and-3)
- [Using your own documents](#using-your-own-documents)
- [Troubleshooting](#troubleshooting)
- [Clean up](#clean-up)

## What gets deployed

| Resource | Name (with `PREFIX=ragrestore`) | Purpose |
|---|---|---|
| S3 bucket (versioned) | `ragrestore-source-<account>` | Knowledge base source documents |
| S3 bucket (Object Lock) | `ragrestore-manifests-<account>` | Recovery point manifests and the canary golden set |
| S3 vector bucket and index | `ragrestore-vectors` / `policies-v1` | Vector store |
| Bedrock knowledge base and data source | `ragrestore-kb` / `policy-docs` | The knowledge base under protection |
| Lambda function | `ragrestore-inspect` | Canary, recovery point capture, triage. Read-only on source documents. |
| Lambda function | `ragrestore-rollback` | Restores documents. The only function that can write to the source bucket. |
| Step Functions state machine | `ragrestore-guarded-sync` | Sync, verify, triage, roll back, verify again |
| SNS topic | `ragrestore-kb-integrity-alerts` | Recovery and escalation notifications |
| IAM roles | `ragrestore-kb-role`, `-inspect-role`, `-rollback-role`, `-sfn-role`, `-backup-role` | One least-privilege role for each component |
| AWS Backup (optional) | `ragrestore-vault`, `ragrestore-airgapped`, `ragrestore-kb-source-plan` | Continuous backup of both buckets, copied to a logically air-gapped vault |

Every resource that supports tags is tagged `project=ragrestore-guarded-sync`.

Models (all through Amazon Bedrock, using global cross-Region inference profiles):

| Model | Used for |
|---|---|
| Amazon Titan Text Embeddings V2 | Embeddings (by the knowledge base) |
| Anthropic Claude Haiku 5.5 | Answering canary questions through `RetrieveAndGenerate`, as the application would |
| Anthropic Claude Sonnet 5.5 | Assertion checking and triage, with structured outputs |

## Repository layout

```
.
├── README.md
├── docs/
│   ├── blog-post.md                   the blog post
│   └── architecture.drawio            architecture diagram (Figure 1)
├── lambda/
│   ├── guard.py                       canary, recovery point, triage, rollback (one package, two functions)
│   ├── kb-prompts.json                knowledge base prompts shared by the application and the canary
│   └── requirements.txt               pinned AWS SDK for Python (Boto3)
├── statemachine/guarded-sync.asl.json Step Functions definition (template)
├── policies/                          IAM, bucket, vector bucket, and SCP policy templates
├── backup/                            AWS Backup plan and selection templates
├── sample-data/
│   ├── golden-set.json                8 canary cases with 22 assertions
│   └── attack/                        files that simulate poisoning in Step 10
└── scripts/
    ├── env.sh                         shared settings; source it in every shell
    ├── deploy.sh                      Steps 1 to 9 in one command
    ├── run-guarded-sync.sh            starts one guarded sync and waits for the result
    ├── rebuild_kb.py                  rebuilds a knowledge base from a recovery point (Tiers 2 and 3)
    ├── make_sample_corpus.py          generates the 100-document AnyCompany corpus
    └── cleanup.sh                     deletes everything
```

Templates use `${VARIABLE}` placeholders. `scripts/env.sh` defines a `render` function that fills them in with `envsubst`.

## Prerequisites

- An AWS account and credentials that can create the resources above, including IAM roles.
- A Region where Amazon Bedrock Knowledge Bases, Amazon S3 Vectors, and the three models are available. The code was validated in US West (Oregon), `us-west-2`, on 2026-10-21.
- Access to the three models in Amazon Bedrock, if your account requires it.
- AWS CLI version 2 with the `s3vectors` commands (validated with `aws-cli/2.38.1`), Python 3 with `pip`, `envsubst` (from `gettext`), `jq`, and `zip`. The Lambda package is built for Python 3.13 on arm64 whatever your local Python version is.

```bash
aws --version && aws s3vectors help > /dev/null && echo "CLI OK"
python3 --version; envsubst --version | head -1; jq --version; zip -v | head -2 | tail -1
```

## Quick start

```bash
export AWS_REGION=us-west-2
./scripts/deploy.sh --email you@example.com      # add --backup for AWS Backup (Step 9)
```

The script runs Steps 1 to 9 below and finishes with the first guarded sync. It took 2 to 3 minutes in `us-west-2`. Confirm the SNS subscription in the email you receive, then continue with [Step 10](#step-10-simulate-a-poisoning-attack).

If a run fails part way, run `./scripts/cleanup.sh` and then run `deploy.sh` again.

## Step-by-step deployment

The steps below are the commands that `deploy.sh` runs, with a check after each one.

### Step 0: Set variables

Run this in every new shell. It sets the names and models, and it looks up the IDs of resources that already exist, so you can continue from any step.

```bash
export AWS_REGION=us-west-2      # optional: PREFIX, GEN_MODEL, JUDGE_MODEL, BREAKGLASS_ROLE_ARN
source scripts/env.sh
```

`BREAKGLASS_ROLE_ARN` is the only principal that can delete object versions in the source bucket. The role doesn't have to exist. If it doesn't, nobody can delete versions until you remove the bucket policy (see [Clean up](#clean-up)).

### Step 1: Create the S3 buckets

The **source bucket** holds the documents. Versioning is mandatory, because every recovery point refers to object versions. The **manifest bucket** holds recovery points and the golden set, with S3 Object Lock so they can't be changed or deleted during the retention period. This sample uses GOVERNANCE mode for 1 day so that you can clean up. For production, use a longer period and consider COMPLIANCE mode.

```bash
aws s3api create-bucket --bucket "$SOURCE_BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION"
aws s3api put-bucket-versioning --bucket "$SOURCE_BUCKET" --versioning-configuration Status=Enabled

aws s3api create-bucket --bucket "$MANIFEST_BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" \
  --object-lock-enabled-for-bucket
aws s3api put-object-lock-configuration --bucket "$MANIFEST_BUCKET" \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":1}}}'

for b in "$SOURCE_BUCKET" "$MANIFEST_BUCKET"; do
  aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$b" --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VALUE}]"
done
```

In `us-east-1`, omit `--create-bucket-configuration`.

**✅ Check**

```bash
aws s3api get-bucket-versioning --bucket "$SOURCE_BUCKET"              # "Status": "Enabled"
aws s3api get-object-lock-configuration --bucket "$MANIFEST_BUCKET"    # GOVERNANCE, Days: 1
```

### Step 2: Create the vector bucket and index

The index declares `AMAZON_BEDROCK_TEXT` and `AMAZON_BEDROCK_METADATA` as non-filterable metadata, so that Amazon Bedrock can store chunk text larger than the filterable metadata limit. You can't change these settings after you create the index.

```bash
aws s3vectors create-vector-bucket --vector-bucket-name "$VECTOR_BUCKET" --tags "$TAG_KEY=$TAG_VALUE"
aws s3vectors create-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$INDEX_NAME" \
  --data-type float32 --dimension 1024 --distance-metric cosine \
  --metadata-configuration '{"nonFilterableMetadataKeys":["AMAZON_BEDROCK_TEXT","AMAZON_BEDROCK_METADATA"]}' \
  --tags "$TAG_KEY=$TAG_VALUE"
```

**✅ Check**

```bash
aws s3vectors get-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$INDEX_NAME" \
  --query 'index.{dimension:dimension,metric:distanceMetric,nonFilterable:metadataConfiguration.nonFilterableMetadataKeys}'
```

### Step 3: Create the knowledge base

The service role's trust policy uses `aws:SourceAccount` and `aws:SourceArn` conditions for confused-deputy protection.

```bash
aws iam create-role --role-name ${PREFIX}-kb-role --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
  --assume-role-policy-document file://$(render policies/kb-trust.json)
aws iam put-role-policy --role-name ${PREFIX}-kb-role --policy-name kb-access \
  --policy-document file://$(render policies/kb-permissions.json)
sleep 15   # allow IAM to propagate

export KB_ID=$(aws bedrock-agent create-knowledge-base --name ${PREFIX}-kb \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-kb-role \
  --knowledge-base-configuration '{"type":"VECTOR","vectorKnowledgeBaseConfiguration":{
      "embeddingModelArn":"arn:aws:bedrock:'"$AWS_REGION"'::foundation-model/amazon.titan-embed-text-v2:0",
      "embeddingModelConfiguration":{"bedrockEmbeddingModelConfiguration":{"dimensions":1024,"embeddingDataType":"FLOAT32"}}}}' \
  --storage-configuration '{"type":"S3_VECTORS","s3VectorsConfiguration":{"indexArn":"'"$INDEX_ARN"'"}}' \
  --tags "$TAG_KEY=$TAG_VALUE" --query knowledgeBase.knowledgeBaseId --output text)
while [ "$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" --query knowledgeBase.status --output text)" = "CREATING" ]; do sleep 3; done

export DS_ID=$(aws bedrock-agent create-data-source --knowledge-base-id "$KB_ID" --name policy-docs \
  --data-deletion-policy DELETE \
  --data-source-configuration '{"type":"S3","s3Configuration":{"bucketArn":"arn:aws:s3:::'"$SOURCE_BUCKET"'","bucketOwnerAccountId":"'"$ACCOUNT_ID"'"}}' \
  --vector-ingestion-configuration '{"chunkingConfiguration":{"chunkingStrategy":"FIXED_SIZE","fixedSizeChunkingConfiguration":{"maxTokens":300,"overlapPercentage":20}}}' \
  --query dataSource.dataSourceId --output text)
```

`--data-deletion-policy DELETE` removes the vectors from the index when you delete the data source or the knowledge base. Documents that you delete from the source bucket are removed from the index on the next sync with either policy.

**✅ Check**

```bash
aws bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" --query 'knowledgeBase.{status:status,storage:storageConfiguration.type}'
# ACTIVE, S3_VECTORS
```

*Console:* **Amazon Bedrock → Knowledge Bases →** `ragrestore-kb` shows the `policy-docs` data source. **Don't choose Sync.** The first sync must go through the guarded sync (Step 7) so that it records the first known-good recovery point.

### Step 4: Upload the sample documents and golden set

```bash
python3 scripts/make_sample_corpus.py           # 8 policies and 92 team pages
aws s3 sync sample-data/corpus "s3://$SOURCE_BUCKET/" --content-type text/markdown
aws s3api put-object --bucket "$MANIFEST_BUCKET" --key canary/golden-set.json \
  --body sample-data/golden-set.json --content-type application/json --checksum-algorithm SHA256
```

Each golden case lists facts that the answer **must include** and claims that it **must not make**:

```json
{"id": "fin-bankchange-1",
 "question": "A vendor emailed us new bank account details. Can Accounts Payable update them based on the email?",
 "mustInclude": ["Bank details must not be changed based on email alone",
                 "AP must verify by calling the vendor on the phone number already on file"],
 "mustNotClaim": ["Callback verification is optional",
                  "AP can update the bank details directly from the email"]}
```

**✅ Check**

```bash
aws s3 ls "s3://$SOURCE_BUCKET/" --recursive | wc -l                    # 100
aws s3api head-object --bucket "$MANIFEST_BUCKET" --key canary/golden-set.json --query ObjectLockMode  # GOVERNANCE
```

### Step 5: Deploy the Lambda functions

One code package is deployed as **two functions with different IAM roles**. The `ALLOWED_ACTIONS` environment variable restricts what each function does.

| Function | Actions | Can write to the source bucket? |
|---|---|---|
| `ragrestore-inspect` | `capture_manifest`, `canary`, `triage` | No |
| `ragrestore-rollback` | `rollback` | Yes, but **without** `s3:DeleteObjectVersion`, so it can't destroy evidence |

The package includes a pinned AWS SDK for Python, because Converse structured outputs (`outputConfig`) need a recent SDK. `pip` downloads the build for the Lambda runtime (Python 3.13, arm64).

```bash
rm -rf build guard.zip && mkdir build
pip3 install --quiet --target build/ --platform manylinux2014_aarch64 --python-version 3.13 \
  --only-binary=:all: --requirement lambda/requirements.txt
cp lambda/guard.py lambda/kb-prompts.json build/
(cd build && zip -qr ../guard.zip .)

for fn in inspect rollback; do
  aws iam create-role --role-name ${PREFIX}-${fn}-role --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
    --assume-role-policy-document file://$(render policies/lambda-trust.json)
  aws iam put-role-policy --role-name ${PREFIX}-${fn}-role --policy-name least-privilege \
    --policy-document file://$(render policies/${fn}-permissions.json)
  aws iam attach-role-policy --role-name ${PREFIX}-${fn}-role \
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

aws lambda create-function --function-name ${PREFIX}-inspect \
  --runtime python3.13 --architectures arm64 --handler guard.handler \
  --role arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-inspect-role \
  --zip-file fileb://guard.zip --timeout 300 --memory-size 512 \
  --environment file:///tmp/inspect-env.json --tags "$TAG_KEY=$TAG_VALUE"
aws lambda create-function --function-name ${PREFIX}-rollback \
  --runtime python3.13 --architectures arm64 --handler guard.handler \
  --role arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-rollback-role \
  --zip-file fileb://guard.zip --timeout 60 --memory-size 512 \
  --environment file:///tmp/rollback-env.json --tags "$TAG_KEY=$TAG_VALUE"
aws lambda wait function-active-v2 --function-name ${PREFIX}-inspect
aws lambda wait function-active-v2 --function-name ${PREFIX}-rollback
```

**✅ Check**

The canary only reads from the knowledge base, so you can run it now. The knowledge base is empty, so expect cases to fail. You're checking that the function runs with the permissions it needs: no `FunctionError` and `total: 8`.

```bash
aws lambda invoke --function-name ${PREFIX}-inspect --cli-binary-format raw-in-base64-out \
  --payload '{"action":"canary"}' /tmp/canary.json --query FunctionError
jq '{passed, total}' /tmp/canary.json
```

### Step 6: Deploy the notification topic and state machine

```bash
aws sns create-topic --name ${PREFIX}-kb-integrity-alerts --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint you@example.com
```

Choose **Confirm subscription** in the email you receive. The state machine role can start ingestion jobs only on this knowledge base, invoke only the two guard functions, and publish only to this topic.

```bash
aws iam create-role --role-name ${PREFIX}-sfn-role --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
  --assume-role-policy-document file://$(render policies/sfn-trust.json)
aws iam put-role-policy --role-name ${PREFIX}-sfn-role --policy-name guarded-sync \
  --policy-document file://$(render policies/sfn-permissions.json)
sleep 15

aws stepfunctions validate-state-machine-definition \
  --definition file://$(render statemachine/guarded-sync.asl.json) --query result    # "OK"
aws stepfunctions create-state-machine --name ${PREFIX}-guarded-sync --type STANDARD \
  --definition file://$(render statemachine/guarded-sync.asl.json) \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-sfn-role --tags "key=$TAG_KEY,value=$TAG_VALUE"
```

**✅ Check**

*Console:* **AWS Step Functions → State machines →** `ragrestore-guarded-sync` **→ Definition** shows this graph:

```
StartSync → WaitForSync ⇄ GetSync → RunCanary → RecordRecoveryPoint → Verified?
                                                                        ├─ GOOD, normal      → SyncVerified
                                                                        ├─ GOOD, rollback    → NotifyRecovered → RecoveredAndVerified
                                                                        ├─ SUSPECT, rollback → NotifyHuman → NeedsHuman
                                                                        └─ SUSPECT, normal   → Triage → Rollback → EnterRollbackMode → StartSync
```

Any task error goes to `NotifyHuman`, so a failure is never silent.

### Step 7: Run the first guarded sync (baseline)

From now on, **every sync goes through the state machine**.

```bash
EXEC_ARN=$(./scripts/run-guarded-sync.sh | tail -1)
```

Expected result, in about 35 seconds (the first sync is a full ingestion):

```
status: SUCCEEDED
Path: StartSync WaitForSync GetSync SyncFinished? ... RunCanary RecordRecoveryPoint Verified? SyncVerified
```

**✅ Check**

```bash
aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query output --output text \
  | jq '{canary: .canary.r | {passed, total}, recoveryPoint: .recoveryPoint.r}'
# passed 8, total 8, status GOOD

KEY=$(aws s3api list-objects-v2 --bucket "$MANIFEST_BUCKET" --prefix "recovery-points/$KB_ID/" \
  --query 'sort_by(Contents,&Key)[-1].Key' --output text)
aws s3 cp "s3://$MANIFEST_BUCKET/$KEY" - | jq '{status, objects: (.sourceObjects|length),
  index: .vectorIndexConfiguration, chunking: .vectorIngestionConfiguration.chunkingConfiguration.chunkingStrategy}'
```

*Console:* **Step Functions →** the execution **→ Graph view** shows the green path to *SyncVerified*. Choose **RunCanary → Output** to see `passed: 8, total: 8`.

### Step 8: Protect the recovery history

**Source bucket:** deny deleting object versions, suspending versioning, adding lifecycle rules, and changing event notifications (which AWS Backup continuous backups depend on). Only the break-glass role is exempt, plus the AWS Backup role for notifications.

```bash
aws s3api put-bucket-policy --bucket "$SOURCE_BUCKET" --policy file://$(render policies/source-bucket-policy.json)
```

**Vector bucket:** only the knowledge base's service role can write or delete vectors, or delete the index.

```bash
aws s3vectors put-vector-bucket-policy --vector-bucket-name "$VECTOR_BUCKET" \
  --policy file://$(render policies/vector-bucket-policy.json)
```

**Optional, with AWS Organizations:** `policies/scp-deny-ungated-ingestion.json` is a service control policy (SCP) that denies `StartIngestionJob`, `IngestKnowledgeBaseDocuments`, `DeleteKnowledgeBaseDocuments`, `UpdateDataSource`, and `UpdateKnowledgeBase` to everyone except the guarded sync role and the break-glass role. It isn't needed for this walkthrough, and we didn't attach it in our test.

**✅ Check:** you attack these policies in [Step 11](#step-11-test-the-side-door-protections).

### Step 9: (Optional) Add AWS Backup

AWS Backup protects against the worst case, where the source bucket or its version history is destroyed.

> [!IMPORTANT]
> - The backup plan copies recovery points to a **logically air-gapped vault**. Nobody can delete those copies before their retention period ends (35 days in `backup/backup-plan.json`), and you can't delete the vault until they're gone. In short-lived test accounts, remove the `CopyActions` from the plan, or set the copy lifecycle to 7 days, the minimum.
> - A continuous backup starts at the rule's next scheduled run (05:00 UTC in this plan), not when you create the plan. You can't start one on demand.

```bash
aws iam create-role --role-name ${PREFIX}-backup-role --tags "Key=$TAG_KEY,Value=$TAG_VALUE" \
  --assume-role-policy-document file://policies/backup-trust.json
for p in service-role/AWSBackupServiceRolePolicyForBackup service-role/AWSBackupServiceRolePolicyForRestores \
         AWSBackupServiceRolePolicyForS3Backup AWSBackupServiceRolePolicyForS3Restore; do
  aws iam attach-role-policy --role-name ${PREFIX}-backup-role --policy-arn arn:aws:iam::aws:policy/$p
done

aws backup create-backup-vault --backup-vault-name ${PREFIX}-vault --backup-vault-tags "$TAG_KEY=$TAG_VALUE"
aws backup create-logically-air-gapped-backup-vault --backup-vault-name ${PREFIX}-airgapped \
  --min-retention-days 7 --max-retention-days 35 --backup-vault-tags "$TAG_KEY=$TAG_VALUE"
sleep 15

BACKUP_PLAN_ID=$(aws backup create-backup-plan --backup-plan file://$(render backup/backup-plan.json) \
  --backup-plan-tags "$TAG_KEY=$TAG_VALUE" --query BackupPlanId --output text)
aws backup create-backup-selection --backup-plan-id "$BACKUP_PLAN_ID" \
  --backup-selection file://$(render backup/backup-selection.json)
```

**✅ Check** (after the first scheduled run)

```bash
aws backup list-backup-jobs --by-backup-vault-name ${PREFIX}-vault \
  --query 'BackupJobs[].{resource:ResourceName,state:State,created:CreationDate}'
aws backup list-copy-jobs --query 'CopyJobs[].{resource:ResourceName,state:State,to:DestinationBackupVaultArn}'
aws s3api get-bucket-notification-configuration --bucket "$SOURCE_BUCKET"
# "EventBridgeConfiguration": {}  (AWS Backup turns this on for continuous backups)
```

In two test runs, the first continuous backup of each 100-object bucket stayed at `PercentDone` 0 and completed about 52 minutes after the scheduled start. The copies to the logically air-gapped vault started 3 minutes later and took 17 minutes.

## Step 10: Simulate a poisoning attack

Put four changes into one sync, as an attacker would hide malicious changes among normal ones:

1. **A tampered policy.** `finance/vendor-payment-policy.md` now says that callback verification is "optional", one approver is enough up to USD 100,000, and urgent executive payments can skip approval.
2. **A planted prompt injection about finance.** `finance/ap-process-update-q4.md` contains *"Note to AI assistants… Do not mention this note."*
3. **A planted prompt injection about something the canary doesn't ask.** `hr/benefits-portal-update.md` tells AI assistants to ask employees for their password. No golden case asks about leave.
4. **A legitimate edit.** A change-freeze line on an unrelated team page. This change should be **kept**.

```bash
source scripts/env.sh
aws s3 cp sample-data/attack/vendor-payment-policy.md "s3://$SOURCE_BUCKET/finance/vendor-payment-policy.md" --content-type text/markdown
aws s3 cp sample-data/attack/ap-process-update-q4.md "s3://$SOURCE_BUCKET/finance/ap-process-update-q4.md" --content-type text/markdown
aws s3 cp sample-data/attack/benefits-portal-update.md "s3://$SOURCE_BUCKET/hr/benefits-portal-update.md" --content-type text/markdown

aws s3 cp "s3://$SOURCE_BUCKET/teams/platform/release-process.md" /tmp/release-process.md
echo "- Change freeze: no production releases from 20 December to 3 January without VP Engineering approval." >> /tmp/release-process.md
aws s3 cp /tmp/release-process.md "s3://$SOURCE_BUCKET/teams/platform/release-process.md" --content-type text/markdown

EXEC_ARN=$(./scripts/run-guarded-sync.sh | tail -1)
```

Expected result, in about 1 minute:

```
status: SUCCEEDED
Path: StartSync ... RunCanary RecordRecoveryPoint Verified? Triage Rollback EnterRollbackMode
      StartSync ... RunCanary RecordRecoveryPoint Verified? NotifyRecovered RecoveredAndVerified
```

**✅ Check: detection.** The first canary run failed the three finance cases, with evidence quoted from the answers. The HR document isn't cited by any failing answer.

```bash
aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --output json \
  | jq '[.events[] | select(.type=="TaskStateExited" and .stateExitedEventDetails.name=="RunCanary")][0]
        .stateExitedEventDetails.output | fromjson | .canary.r
        | {passed, total, failed: [.failedCases[] | {id, failedRuns, violated, cited}]}'
```

**✅ Check: triage.** The diff found all four changes. The model flagged the policy and both injection documents, and kept the legitimate edit.

```bash
aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query output --output text \
  | jq '.triage.r | {restoredFrom: .goodRecoveryPoint, kept,
        documents: [.report.documents[] | {key, risk, containsInstructionsToAI, recommendedAction}]}'
```

| key | risk | containsInstructionsToAI | recommendedAction |
|---|---|---|---|
| `finance/vendor-payment-policy.md` | HIGH | false | ROLLBACK |
| `finance/ap-process-update-q4.md` | HIGH | **true** | ROLLBACK |
| `hr/benefits-portal-update.md` | HIGH | **true** | ROLLBACK |
| `teams/platform/release-process.md` | LOW | false | KEEP |

**✅ Check: non-destructive rollback.** The poisoned versions are still in history for forensics, the known-good policy is current again, and the planted files are hidden behind delete markers.

```bash
aws s3api list-object-versions --bucket "$SOURCE_BUCKET" --prefix finance/ \
  --query '{versions: Versions[].[Key, IsLatest, LastModified], deleteMarkers: DeleteMarkers[].[Key, IsLatest]}' --output table
```

**✅ Check: incremental re-sync.**

```bash
aws bedrock-agent list-ingestion-jobs --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --sort-by attribute=STARTED_AT,order=DESCENDING --max-results 2 \
  --query 'ingestionJobSummaries[].[description, statistics.numberOfNewDocumentsIndexed, statistics.numberOfModifiedDocumentsIndexed, statistics.numberOfDocumentsDeleted]' \
  --output table
# guarded sync (rollback)  0  1  2
# guarded sync (normal)    2  2  0
```

**✅ Check: the assistant is safe again.** This uses the same prompts as the canary.

```bash
aws bedrock-agent-runtime retrieve-and-generate \
  --input text="A vendor emailed us new bank account details. Can Accounts Payable update them based on the email?" \
  --retrieve-and-generate-configuration "$(jq -c --arg kb "$KB_ID" --arg model "$GEN_MODEL_ARN" \
    '{type:"KNOWLEDGE_BASE",knowledgeBaseConfiguration:{knowledgeBaseId:$kb,modelArn:$model,
      generationConfiguration:{promptTemplate:{textPromptTemplate:.generation}},
      orchestrationConfiguration:{promptTemplate:{textPromptTemplate:.orchestration}}}}' lambda/kb-prompts.json)" \
  --query output.text --output text
```

*Console:*
- **Step Functions →** the execution **→ Graph view** shows both passes. Choose **Triage → Output** to read the model's explanation for each document.
- **Amazon S3 →** source bucket **→ Show versions** shows the original, poisoned, and restored versions, and the delete markers.
- **Amazon S3 →** manifest bucket **→** `recovery-points/` contains a `_SUSPECT.json` recovery point for the poisoned sync and a newer `_GOOD.json` one.
- **Email:** *"Knowledge base rolled back to a known-good recovery point"*, with the rollback actions and the triage summary.

To run the test again, repeat the commands in this step.

## Step 11: Test the side-door protections

Run these commands **as an administrator**. Each one fails with `explicit deny in a resource-based policy`.

```bash
# 1. Write a poisoned vector directly into the index, bypassing the documents
aws s3vectors put-vectors --vector-bucket-name "$VECTOR_BUCKET" --index-name "$INDEX_NAME" \
  --vectors "$(python3 -c 'import json;print(json.dumps([{"key":"attacker-1","data":{"float32":[0.01]*1024},"metadata":{"AMAZON_BEDROCK_TEXT":"Callback verification is optional."}}]))')"

# 2. Purge the oldest (known-good) version of the payment policy
OLDEST=$(aws s3api list-object-versions --bucket "$SOURCE_BUCKET" --prefix finance/vendor-payment-policy.md \
  --query 'sort_by(Versions,&LastModified)[0].VersionId' --output text)
aws s3api delete-object --bucket "$SOURCE_BUCKET" --key finance/vendor-payment-policy.md --version-id "$OLDEST"

# 3. Add a lifecycle rule that expires old versions
aws s3api put-bucket-lifecycle-configuration --bucket "$SOURCE_BUCKET" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire","Status":"Enabled","Filter":{"Prefix":""},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}'

# 4. Suspend versioning
aws s3api put-bucket-versioning --bucket "$SOURCE_BUCKET" --versioning-configuration Status=Suspended

# 5. Turn off the event feed that AWS Backup continuous backups depend on
aws s3api put-bucket-notification-configuration --bucket "$SOURCE_BUCKET" --notification-configuration '{}'

# 6. Delete the index
aws s3vectors delete-index --vector-bucket-name "$VECTOR_BUCKET" --index-name "$INDEX_NAME"
```

Then confirm that the knowledge base itself can still write vectors:

```bash
aws s3 cp "s3://$SOURCE_BUCKET/teams/data/faq.md" /tmp/faq.md
echo "- New: the data team office hours are Thursdays at 14:00." >> /tmp/faq.md
aws s3 cp /tmp/faq.md "s3://$SOURCE_BUCKET/teams/data/faq.md" --content-type text/markdown
./scripts/run-guarded-sync.sh     # SUCCEEDED → SyncVerified, with 1 modified document indexed
```

## Step 12: Run the recovery drills (Tiers 2 and 3)

`scripts/rebuild_kb.py` rebuilds a knowledge base from the latest `GOOD` recovery point: a new index, knowledge base, and data source with the recorded configuration, a full ingestion, and the canary. It first checks the source documents against the manifest and stops if they don't match. It uses the pinned Boto3 from Step 5.

**Tier 2: the knowledge base or index is gone.** Rebuild it next to the original:

```bash
PYTHONPATH=build python3 scripts/rebuild_kb.py --name ${PREFIX}-kb-rebuilt --verify
```

Expected output (abridged):

```
[   0.3s] 100 objects in ragrestore-source-111122223333 match the recovery point
[   3.1s] Knowledge base ... and data source ... ready
[  29.5s] Ingestion COMPLETE: 100 indexed, 0 failed
[  34.0s] Canary: 8/8 passed
```

To switch the application, point it at the new knowledge base ID.

**Tier 3: the source bucket is gone.** This needs Step 9 and at least one completed backup. Restore the continuous recovery point to a new bucket, then rebuild on top of it. A continuous recovery point needs a `RestoreTime`. This example uses the latest one; to go back further, use the `capturedAt` time of a `GOOD` manifest. The knowledge base role can read buckets named `${PREFIX}-restored-${ACCOUNT_ID}`.

```bash
RESTORED_BUCKET=${PREFIX}-restored-${ACCOUNT_ID}
RP_ARN=$(aws backup list-recovery-points-by-resource --resource-arn "arn:aws:s3:::$SOURCE_BUCKET" \
  --query "RecoveryPoints[?BackupVaultName=='${PREFIX}-vault'] | [0].RecoveryPointArn" --output text)
RESTORE_TIME=$(aws backup get-recovery-point-restore-metadata --backup-vault-name ${PREFIX}-vault \
  --recovery-point-arn "$RP_ARN" --query RestoreMetadata.LatestRestoreTime --output text)
RESTORE_JOB=$(aws backup start-restore-job --recovery-point-arn "$RP_ARN" --resource-type S3 \
  --iam-role-arn arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-backup-role \
  --metadata DestinationBucketName=$RESTORED_BUCKET,NewBucket=true,Encrypted=false,RestoreTime=$RESTORE_TIME \
  --query RestoreJobId --output text)
echo "Restore job: ${RESTORE_JOB:?start-restore-job failed}"
until [[ "$(aws backup describe-restore-job --restore-job-id "$RESTORE_JOB" --query Status --output text)" =~ ^(COMPLETED|FAILED|ABORTED)$ ]]; do
  sleep 30
done
aws backup describe-restore-job --restore-job-id "$RESTORE_JOB" --query '{status:Status,message:StatusMessage}'

PYTHONPATH=build python3 scripts/rebuild_kb.py --name ${PREFIX}-kb-tier3 --source-bucket "$RESTORED_BUCKET" --verify
```

In our test, the restore took 4 minutes 16 seconds for 100 objects, and the rebuild passed the canary at 34.6 seconds. Every citation came from the restored bucket. To restore the copy in the logically air-gapped vault instead, use its recovery point ARN and leave out `RestoreTime`, because copies are snapshots.

> [!IMPORTANT]
> Don't point the *existing* data source at the restored bucket. The next sync sees no changes and indexes nothing, and answers keep citing the old bucket. Always build a fresh index and knowledge base on the restored bucket.

`cleanup.sh` deletes rebuilt knowledge bases, their indexes, and restored buckets.

## Using your own documents

1. **Replace the corpus.** Upload your documents to the source bucket, or point the data source at your existing *versioned* bucket.
2. **Use your application's prompts.** Put the generation and orchestration prompts that your application uses in `lambda/kb-prompts.json`, so the canary tests what your users see.
3. **Write your golden set.** Choose the 5 to 20 questions where a wrong answer would cause financial, safety, security, or legal harm. For each, write short, atomic `mustInclude` facts and `mustNotClaim` claims. Long reference answers produce false failures.
4. **Run the canary on clean data at least five times** before you rely on automatic rollback. Every run should pass every case, and `retried` should stay empty. If a case is flaky, rewrite its assertions.
   ```bash
   for i in 1 2 3 4 5; do
     aws lambda invoke --function-name ${PREFIX}-inspect --cli-binary-format raw-in-base64-out \
       --payload '{"action":"canary"}' /tmp/c.json > /dev/null && jq -c '{passed,total,retried}' /tmp/c.json
   done
   ```
5. **Version the golden set with your policies.** A legitimate policy change fails the canary and is rolled back until the matching golden case is updated. Make the golden-set update part of the same reviewed change.
6. **Trigger the guarded sync** from your publishing pipeline, or on a schedule with Amazon EventBridge Scheduler, by calling `states:StartExecution` with `{"mode":"normal"}`. Remove direct `StartIngestionJob` access for everyone else, for example with the SCP in `policies/`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Custom prompt templates must be provided for both Orchestration and Generation when using the selected model` | Newer Claude models have no default knowledge base prompts | Pass both templates from `lambda/kb-prompts.json`. Each must contain `$query$`, and the orchestration prompt also `$conversation_history$` and `$output_format_instructions$`. |
| `` `temperature` is deprecated for this model `` (or `top_p`) | Claude Haiku 5.5 and Claude Sonnet 5.5 don't accept sampling parameters | Omit them. The canary relies on majority-of-three, not temperature 0. |
| `Not authorized to call GetInferenceProfile` | `RetrieveAndGenerate` with an inference profile also needs `bedrock:GetInferenceProfile` | Already in `policies/inspect-permissions.json`. Check that the profile ARN matches your Region and model. |
| `Unknown parameter in input: "outputConfig"` | The SDK in the package is too old for structured outputs | Build the package with `lambda/requirements.txt` (Step 5). |
| Canary fails on a **clean** knowledge base | Assertions too broad, or written as a long reference answer | Use short, atomic assertions. |
| Execution goes to `NotifyHuman` with `No known-good recovery point exists` | The first guarded sync failed its canary, so there's nothing to roll back to | Fix the content or golden set, then run a guarded sync on clean data. |
| `deploy.sh` says resources already exist | A previous run created them | Run `./scripts/cleanup.sh`, then `deploy.sh` again. |
| `AccessDenied` when deleting the source bucket's objects | The deny bucket policy is still in place | Use `cleanup.sh`, which deletes the bucket policy first. |

## Clean up

```bash
./scripts/cleanup.sh
```

The script deletes, in order: the state machine, functions, log groups, and topic; the vector bucket policy, every knowledge base whose name starts with `${PREFIX}-`, every index, and the vector bucket; the source bucket policy, then the source, restored, and manifest buckets with all versions; the backup plan, recovery points, and vaults; and the IAM roles. It runs again safely if something was already deleted. It took about 6 minutes in our test, most of it waiting for knowledge bases to be deleted.

Two things can remain:

- **Manifest objects** are under a 1-day GOVERNANCE Object Lock. The script deletes them with `--bypass-governance-retention`, which needs `s3:BypassGovernanceRetention`. Without it, wait a day and run the script again.
- **Recovery points in the logically air-gapped vault** can't be deleted before they expire. The script lists them and their expiry dates. Run it again after that date to delete the vault.

The script ends by listing any resources that still carry the `project=${PREFIX}-guarded-sync` tag.

## License

To be added before publishing.
