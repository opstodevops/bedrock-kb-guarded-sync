#!/usr/bin/env bash
# Starts one guarded sync, waits for it to finish, and prints the result and the path it took.
#
#   ./scripts/run-guarded-sync.sh
#
# Prints the execution ARN on the last line, so you can capture it:
#   EXEC_ARN=$(./scripts/run-guarded-sync.sh | tail -1)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/env.sh

EXEC_ARN=$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" \
  --input '{"mode":"normal"}' --query executionArn --output text)
echo "Execution: $EXEC_ARN" >&2
while [ "$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query status --output text)" = "RUNNING" ]; do
  sleep 5
done
aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" \
  --query '{status:status,started:startDate,stopped:stopDate}' --output table >&2
echo "Path:" >&2
aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --max-items 1000 \
  --query 'events[?stateEnteredEventDetails].stateEnteredEventDetails.name' --output text >&2
echo "$EXEC_ARN"
