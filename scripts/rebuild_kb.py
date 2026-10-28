"""Rebuild a knowledge base from a recovery point manifest (Tier 2 and Tier 3 recovery).

Creates a new vector index, knowledge base, and data source from the configuration recorded in
the latest GOOD recovery point, runs a full ingestion, and (with --verify) runs the integrity
canary against the new knowledge base.

  source scripts/env.sh
  python3 scripts/rebuild_kb.py --name ragrestore-kb-rebuilt --verify                 # Tier 2
  python3 scripts/rebuild_kb.py --name ragrestore-kb-tier3 \\
      --source-bucket ragrestore-restored-111122223333 --verify                        # Tier 3

Before it creates anything, it checks the source documents against the manifest: by version ID
for the original bucket, and by ETag for a bucket restored from AWS Backup (restored objects get
new version IDs). It stops if anything doesn't match.

Requires the environment from scripts/env.sh and boto3 from lambda/requirements.txt.
"""
import argparse
import json
import os
import sys
import time

import boto3

REGION = os.environ["AWS_REGION"]
MANIFEST_BUCKET = os.environ["MANIFEST_BUCKET"]
SOURCE_BUCKET = os.environ["SOURCE_BUCKET"]
KB_ID = os.environ["KB_ID"]
TAGS = {os.environ["TAG_KEY"]: os.environ["TAG_VALUE"]}

s3 = boto3.client("s3", region_name=REGION)
agent = boto3.client("bedrock-agent", region_name=REGION)
s3vectors = boto3.client("s3vectors", region_name=REGION)
START = time.monotonic()


def log(message):
    print(f"[{time.monotonic() - START:6.1f}s] {message}", flush=True)


def latest_good_manifest():
    prefix = f"recovery-points/{KB_ID}/"
    keys = [o["Key"] for page in s3.get_paginator("list_objects_v2").paginate(Bucket=MANIFEST_BUCKET, Prefix=prefix)
            for o in page.get("Contents", []) if o["Key"].endswith("_GOOD.json")]
    if not keys:
        sys.exit("No GOOD recovery point found")
    key = sorted(keys)[-1]
    return key, json.loads(s3.get_object(Bucket=MANIFEST_BUCKET, Key=key)["Body"].read())


def check_source(manifest, bucket):
    """Return a list of differences between the bucket's current objects and the manifest."""
    current = {}
    for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket):
        for v in page.get("Versions", []):
            if v["IsLatest"]:
                current[v["Key"]] = {"versionId": v["VersionId"], "etag": v["ETag"].strip('"')}
    field = "versionId" if bucket == SOURCE_BUCKET else "etag"
    expected = {o["key"]: o[field] for o in manifest["sourceObjects"]}
    problems = [f"{k}: mismatch" for k in expected if k in current and current[k][field] != expected[k]]
    problems += [f"{k}: missing" for k in expected if k not in current]
    problems += [f"{k}: not in manifest" for k in current if k not in expected]
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--name", required=True, help="name of the new knowledge base")
    parser.add_argument("--index-name", help="name of the new vector index (default: <name>-index)")
    parser.add_argument("--source-bucket", default=SOURCE_BUCKET, help="bucket with the documents to ingest")
    parser.add_argument("--verify", action="store_true", help="run the canary against the new knowledge base")
    args = parser.parse_args()
    index_name = args.index_name or f"{args.name}-index"

    key, m = latest_good_manifest()
    log(f"Recovery point: {key}")
    problems = check_source(m, args.source_bucket)
    if problems:
        sys.exit(f"{len(problems)} objects in {args.source_bucket} don't match the recovery point, "
                 f"for example: {problems[:5]}. Restore them first (README Tier 1).")
    log(f"{len(m['sourceObjects'])} objects in {args.source_bucket} match the recovery point")

    # 1. Vector index, with the settings recorded in the manifest (they can't be changed later)
    vector_bucket_arn = m["storageConfiguration"]["s3VectorsConfiguration"]["indexArn"].split("/index/")[0]
    s3vectors.create_index(vectorBucketArn=vector_bucket_arn, indexName=index_name, tags=TAGS,
                           **m["vectorIndexConfiguration"])
    log(f"Index {index_name} created")

    # 2. Knowledge base and data source
    kb = agent.create_knowledge_base(
        name=args.name, roleArn=m["roleArn"], tags=TAGS,
        knowledgeBaseConfiguration=m["knowledgeBaseConfiguration"],
        storageConfiguration={"type": "S3_VECTORS", "s3VectorsConfiguration": {
            "indexArn": f"{vector_bucket_arn}/index/{index_name}"}})["knowledgeBase"]
    kb_id = kb["knowledgeBaseId"]
    while agent.get_knowledge_base(knowledgeBaseId=kb_id)["knowledgeBase"]["status"] == "CREATING":
        time.sleep(2)
    data_source_config = m["dataSourceConfiguration"]
    data_source_config["s3Configuration"]["bucketArn"] = f"arn:aws:s3:::{args.source_bucket}"
    ds_id = agent.create_data_source(
        knowledgeBaseId=kb_id, name="policy-docs", dataDeletionPolicy=m["dataDeletionPolicy"],
        dataSourceConfiguration=data_source_config,
        vectorIngestionConfiguration=m["vectorIngestionConfiguration"])["dataSource"]["dataSourceId"]
    log(f"Knowledge base {kb_id} and data source {ds_id} ready")

    # 3. Full ingestion
    job_id = agent.start_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id,
                                       description=f"rebuild from {key}")["ingestionJob"]["ingestionJobId"]
    while True:
        job = agent.get_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id, ingestionJobId=job_id)["ingestionJob"]
        if job["status"] in ("COMPLETE", "FAILED", "STOPPED"):
            break
        time.sleep(5)
    stats = job["statistics"]
    log(f"Ingestion {job['status']}: {stats['numberOfNewDocumentsIndexed']} indexed, "
        f"{stats['numberOfDocumentsFailed']} failed")
    if job["status"] != "COMPLETE":
        sys.exit(1)

    # 4. Integrity canary against the new knowledge base (same code as the inspect function)
    if args.verify:
        os.environ.update(KB_ID=kb_id, DS_ID=ds_id)
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))
        import guard
        result = guard.canary({})
        log(f"Canary: {result['passed']}/{result['total']} passed")
        if result["passed"] != result["total"]:
            print(json.dumps(result["failedCases"], indent=1))
            sys.exit(1)
    print(json.dumps({"knowledgeBaseId": kb_id, "dataSourceId": ds_id, "indexName": index_name}))


if __name__ == "__main__":
    main()
