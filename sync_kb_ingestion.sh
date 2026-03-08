#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="${1:-clbp-rag-stack}"
REGION="${REGION:-${2:-eu-west-2}}"
DOCS_DIR="${3:-dataset}"
S3_PREFIX="${4:-clbp}"

echo "[1/7] Starting Bedrock KB sync helper"
echo "      Stack:  ${STACK_NAME}"
echo "      Region: ${REGION}"
echo "      Docs:   ${DOCS_DIR}"
echo "      Prefix: ${S3_PREFIX}"

echo "[2/7] Checking prerequisites"
if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found in PATH"
  exit 1
fi

if [[ ! -d "${DOCS_DIR}" ]]; then
  echo "ERROR: docs directory not found: ${DOCS_DIR}"
  echo "       Tip: pass a custom directory as argument 3"
  exit 1
fi

echo "[3/7] Reading CloudFormation outputs"
KB_ID="$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`KnowledgeBaseId`].OutputValue' \
  --output text)"

BUCKET="$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`DataSourceBucketName`].OutputValue' \
  --output text)"

DS_ID_RAW="$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`DataSourceId`].OutputValue' \
  --output text)"

DS_ID="${DS_ID_RAW}"
if [[ "${DS_ID_RAW}" == *"|"* ]]; then
  DS_ID="${DS_ID_RAW##*|}"
fi

if [[ -z "${KB_ID}" || "${KB_ID}" == "None" ]]; then
  echo "ERROR: KnowledgeBaseId output not found in stack ${STACK_NAME}"
  exit 1
fi
if [[ -z "${BUCKET}" || "${BUCKET}" == "None" ]]; then
  echo "ERROR: DataSourceBucketName output not found in stack ${STACK_NAME}"
  exit 1
fi
if [[ -z "${DS_ID_RAW}" || "${DS_ID_RAW}" == "None" ]]; then
  echo "ERROR: DataSourceId output not found in stack ${STACK_NAME}"
  exit 1
fi
if [[ ! "${DS_ID}" =~ ^[0-9a-zA-Z]{10}$ ]]; then
  echo "ERROR: Could not derive a valid 10-char DataSourceId from stack output: ${DS_ID_RAW}"
  exit 1
fi

echo "      KnowledgeBaseId: ${KB_ID}"
echo "      DataSourceId:    ${DS_ID}"
if [[ "${DS_ID_RAW}" != "${DS_ID}" ]]; then
  echo "      DataSourceRaw:   ${DS_ID_RAW}"
fi
echo "      Bucket:          s3://${BUCKET}/${S3_PREFIX}/"

echo "[4/7] Uploading documents to S3"
aws s3 sync "${DOCS_DIR}/" "s3://${BUCKET}/${S3_PREFIX}/" --region "${REGION}"

echo "[5/7] Starting Bedrock ingestion job"
INGESTION_JOB_ID="$(aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "${KB_ID}" \
  --data-source-id "${DS_ID}" \
  --region "${REGION}" \
  --query 'ingestionJob.ingestionJobId' \
  --output text)"

echo "[6/7] Ingestion triggered successfully"
echo "      IngestionJobId: ${INGESTION_JOB_ID}"

echo "[7/7] Done"
echo "      Knowledge Base ID: ${KB_ID}"
echo "      Next: monitor job status with:"
echo "      aws bedrock-agent get-ingestion-job --knowledge-base-id ${KB_ID} --data-source-id ${DS_ID} --ingestion-job-id ${INGESTION_JOB_ID} --region ${REGION}"
