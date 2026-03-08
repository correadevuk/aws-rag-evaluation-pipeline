#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="${1:-clbp-rag-stack}"
REGION="${REGION:-${2:-eu-west-2}}"
PROJECT_NAME="${PROJECT_NAME:-${3:-clbp-rag}}"

log() {
  echo "$1"
}

warn() {
  echo "WARNING: $1" >&2
}

print_delete_failures() {
  log "      Recent DELETE_FAILED events:"
  aws cloudformation describe-stack-events \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]" \
    --output table || true
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

stack_exists() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" >/dev/null 2>&1
}

get_stack_output() {
  local output_key="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey==\`${output_key}\`].OutputValue" \
    --output text 2>/dev/null || true
}

get_stack_status() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || true
}

get_physical_id() {
  local logical_id="$1"
  aws cloudformation describe-stack-resource \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --logical-resource-id "${logical_id}" \
    --query 'StackResourceDetail.PhysicalResourceId' \
    --output text 2>/dev/null || true
}

exists_s3_bucket() {
  local bucket_name="$1"
  [[ -n "${bucket_name}" ]] || return 1
  aws s3api head-bucket --bucket "${bucket_name}" --region "${REGION}" >/dev/null 2>&1
}

role_exists() {
  local role_name="$1"
  [[ -n "${role_name}" ]] || return 1
  aws iam get-role --role-name "${role_name}" >/dev/null 2>&1
}

knowledge_base_exists() {
  local knowledge_base_id="$1"
  [[ -n "${knowledge_base_id}" ]] || return 1
  aws bedrock-agent get-knowledge-base \
    --knowledge-base-id "${knowledge_base_id}" \
    --region "${REGION}" >/dev/null 2>&1
}

data_source_exists() {
  local knowledge_base_id="$1"
  local data_source_id="$2"
  [[ -n "${knowledge_base_id}" && -n "${data_source_id}" ]] || return 1
  aws bedrock-agent get-data-source \
    --knowledge-base-id "${knowledge_base_id}" \
    --data-source-id "${data_source_id}" \
    --region "${REGION}" >/dev/null 2>&1
}

vector_bucket_exists() {
  local vector_bucket_name="$1"
  [[ -n "${vector_bucket_name}" ]] || return 1
  aws s3vectors get-vector-bucket \
    --vector-bucket-name "${vector_bucket_name}" \
    --region "${REGION}" >/dev/null 2>&1
}

index_exists() {
  local vector_bucket_name="$1"
  local index_name="$2"
  [[ -n "${vector_bucket_name}" && -n "${index_name}" ]] || return 1
  aws s3vectors get-index \
    --vector-bucket-name "${vector_bucket_name}" \
    --index-name "${index_name}" \
    --region "${REGION}" >/dev/null 2>&1
}

parse_resource_name() {
  local value="$1"
  if [[ -z "${value}" || "${value}" == "None" ]]; then
    echo ""
    return
  fi

  value="${value##*/}"
  value="${value##*:}"
  echo "${value}"
}

parse_data_source_id() {
  local value="$1"

  if [[ -z "${value}" || "${value}" == "None" ]]; then
    echo ""
    return
  fi

  if [[ "${value}" == *"|"* ]]; then
    value="${value##*|}"
  fi

  echo "${value}"
}

empty_s3_bucket() {
  local bucket_name="$1"

  if ! exists_s3_bucket "${bucket_name}"; then
    log "      S3 bucket not found or already deleted"
    return
  fi

  log "      Emptying s3://${bucket_name}"
  aws s3 rm "s3://${bucket_name}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
}

try_delete_s3_bucket() {
  local bucket_name="$1"

  if ! exists_s3_bucket "${bucket_name}"; then
    log "      S3 bucket not found or already deleted"
    return
  fi

  empty_s3_bucket "${bucket_name}"

  log "      Deleting S3 bucket ${bucket_name}"
  aws s3api delete-bucket --bucket "${bucket_name}" --region "${REGION}"
}

wait_for_data_source_deletion() {
  local knowledge_base_id="$1"
  local data_source_id="$2"
  local attempts=3
  local status=""

  for ((i=1; i<=attempts; i++)); do
    status="$(aws bedrock-agent get-data-source \
      --knowledge-base-id "${knowledge_base_id}" \
      --data-source-id "${data_source_id}" \
      --region "${REGION}" \
      --query 'dataSource.status' \
      --output text 2>/dev/null)"
    rc=$?

    if [[ ${rc} -ne 0 ]]; then
      log "      Data source deleted"
      return 0
    fi

    if [[ "${status}" == "DELETE_UNSUCCESSFUL" ]]; then
      warn "Data source deletion became DELETE_UNSUCCESSFUL"
      aws bedrock-agent get-data-source \
        --knowledge-base-id "${knowledge_base_id}" \
        --data-source-id "${data_source_id}" \
        --region "${REGION}" \
        --query 'dataSource.failureReasons' \
        --output json 2>/dev/null || true
      return 1
    fi

    log "      Waiting for data source deletion (${i}/${attempts}) - status: ${status}"
    sleep 10
  done

  warn "Timed out waiting for data source deletion"
  return 1
}

wait_for_knowledge_base_deletion() {
  local knowledge_base_id="$1"
  local attempts=3
  local status=""

  for ((i=1; i<=attempts; i++)); do
    status="$(aws bedrock-agent get-knowledge-base \
      --knowledge-base-id "${knowledge_base_id}" \
      --region "${REGION}" \
      --query 'knowledgeBase.status' \
      --output text 2>/dev/null)"
    rc=$?

    if [[ ${rc} -ne 0 ]]; then
      log "      Knowledge base deleted"
      return 0
    fi

    if [[ "${status}" == "DELETE_UNSUCCESSFUL" || "${status}" == "FAILED" ]]; then
      warn "Knowledge base deletion ended in status ${status}"
      aws bedrock-agent get-knowledge-base \
        --knowledge-base-id "${knowledge_base_id}" \
        --region "${REGION}" \
        --output json 2>/dev/null || true
      return 1
    fi

    log "      Waiting for knowledge base deletion (${i}/${attempts}) - status: ${status}"
    sleep 10
  done

  warn "Timed out waiting for knowledge base deletion"
  return 1
}

try_delete_data_source() {
  local knowledge_base_id="$1"
  local data_source_id="$2"

  if ! data_source_exists "${knowledge_base_id}" "${data_source_id}"; then
    log "      Data source not found or already deleted"
    return
  fi

  log "      Deleting data source ${data_source_id} from knowledge base ${knowledge_base_id}"
  aws bedrock-agent delete-data-source \
    --knowledge-base-id "${knowledge_base_id}" \
    --data-source-id "${data_source_id}" \
    --region "${REGION}" >/dev/null

  wait_for_data_source_deletion "${knowledge_base_id}" "${data_source_id}"
}

try_delete_knowledge_base() {
  local knowledge_base_id="$1"

  if ! knowledge_base_exists "${knowledge_base_id}"; then
    log "      Knowledge base not found or already deleted"
    return
  fi

  log "      Deleting knowledge base ${knowledge_base_id}"
  aws bedrock-agent delete-knowledge-base \
    --knowledge-base-id "${knowledge_base_id}" \
    --region "${REGION}" >/dev/null

  wait_for_knowledge_base_deletion "${knowledge_base_id}"
}

delete_stack_last() {
  if ! stack_exists; then
    log "      Stack not found, skipping stack deletion"
    return
  fi

  aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${REGION}"

  if aws cloudformation wait stack-delete-complete \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}"; then
    log "      Stack deleted"
    return
  fi

  warn "CloudFormation stack deletion failed on the first attempt"
  print_delete_failures

  if [[ "$(get_stack_status)" == "DELETE_FAILED" ]]; then
    log "      Retrying stack deletion in FORCE_DELETE_STACK mode"
    aws cloudformation delete-stack \
      --stack-name "${STACK_NAME}" \
      --region "${REGION}" \
      --deletion-mode FORCE_DELETE_STACK \
      --retain-resources DataSourceBucket VectorBucket VectorIndex BedrockKBRole KnowledgeBase KBDataSource
    aws cloudformation wait stack-delete-complete \
      --stack-name "${STACK_NAME}" \
      --region "${REGION}"
    log "      Stack deleted on retry"
    return
  fi

  warn "Stack deletion did not complete, but the stack is not in DELETE_FAILED"
}

try_delete_index() {
  local vector_bucket_name="$1"
  local index_name="$2"

  if ! index_exists "${vector_bucket_name}" "${index_name}"; then
    log "      Vector index not found or already deleted"
    return
  fi

  log "      Deleting vector index ${index_name}"
  aws s3vectors delete-index \
    --vector-bucket-name "${vector_bucket_name}" \
    --index-name "${index_name}" \
    --region "${REGION}"
}

try_delete_vector_bucket() {
  local vector_bucket_name="$1"

  if ! vector_bucket_exists "${vector_bucket_name}"; then
    log "      Vector bucket not found or already deleted"
    return
  fi

  log "      Deleting vector bucket ${vector_bucket_name}"
  aws s3vectors delete-vector-bucket \
    --vector-bucket-name "${vector_bucket_name}" \
    --region "${REGION}"
}

try_delete_role() {
  local role_name="$1"

  if ! role_exists "${role_name}"; then
    log "      IAM role not found or already deleted"
    return
  fi

  log "      Deleting inline policy from role ${role_name}"
  aws iam delete-role-policy \
    --role-name "${role_name}" \
    --policy-name BedrockKBPolicy >/dev/null 2>&1 || true

  log "      Deleting IAM role ${role_name}"
  aws iam delete-role --role-name "${role_name}"
}

require_cmd aws

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
DEFAULT_BUCKET="${PROJECT_NAME}-datasource-${ACCOUNT_ID}"
DEFAULT_VECTOR_BUCKET="${PROJECT_NAME}-vectors-${ACCOUNT_ID}"
DEFAULT_INDEX="${PROJECT_NAME}-index"
DEFAULT_ROLE="${PROJECT_NAME}-bedrock-kb-role"
KB_ID=""
DS_ID=""
DS_ID_RAW=""

log "[1/8] Resolving resource names"
log "      Stack:        ${STACK_NAME}"
log "      Region:       ${REGION}"
log "      ProjectName:  ${PROJECT_NAME}"
log "      AccountId:    ${ACCOUNT_ID}"

STACK_PRESENT=false
if stack_exists; then
  STACK_PRESENT=true
fi

if [[ "${STACK_PRESENT}" == true ]]; then
  S3_BUCKET="$(get_stack_output DataSourceBucketName)"
  KB_ID="$(get_stack_output KnowledgeBaseId)"
  DS_ID_RAW="$(get_stack_output DataSourceId)"
  VECTOR_BUCKET_RAW="$(get_physical_id VectorBucket)"
  INDEX_RAW="$(get_physical_id VectorIndex)"
  ROLE_NAME="$(get_physical_id BedrockKBRole)"
else
  S3_BUCKET="${DEFAULT_BUCKET}"
  VECTOR_BUCKET_RAW="${DEFAULT_VECTOR_BUCKET}"
  INDEX_RAW="${DEFAULT_INDEX}"
  ROLE_NAME="${DEFAULT_ROLE}"
fi

VECTOR_BUCKET_NAME="$(parse_resource_name "${VECTOR_BUCKET_RAW}")"
INDEX_NAME="$(parse_resource_name "${INDEX_RAW}")"
DS_ID="$(parse_data_source_id "${DS_ID_RAW}")"
ROLE_NAME="${ROLE_NAME:-${DEFAULT_ROLE}}"

[[ -n "${S3_BUCKET}" && "${S3_BUCKET}" != "None" ]] || S3_BUCKET="${DEFAULT_BUCKET}"
[[ -n "${VECTOR_BUCKET_NAME}" && "${VECTOR_BUCKET_NAME}" != "None" ]] || VECTOR_BUCKET_NAME="${DEFAULT_VECTOR_BUCKET}"
[[ -n "${INDEX_NAME}" && "${INDEX_NAME}" != "None" ]] || INDEX_NAME="${DEFAULT_INDEX}"
[[ -n "${ROLE_NAME}" && "${ROLE_NAME}" != "None" ]] || ROLE_NAME="${DEFAULT_ROLE}"

log "      S3 bucket:    ${S3_BUCKET}"
log "      Vector bucket:${VECTOR_BUCKET_NAME}"
log "      Vector index: ${INDEX_NAME}"
log "      KnowledgeBase:${KB_ID:-<none>}"
log "      Data source:  ${DS_ID:-<none>}"
log "      IAM role:     ${ROLE_NAME}"

log "[2/8] Deleting Bedrock data source"
set +e
try_delete_data_source "${KB_ID}" "${DS_ID}"
DATA_SOURCE_DELETE_RC=$?
set -e

if [[ ${DATA_SOURCE_DELETE_RC} -ne 0 ]]; then
  warn "Data source cleanup returned a non-zero exit code"
fi

log "[3/8] Deleting Bedrock knowledge base"
set +e
try_delete_knowledge_base "${KB_ID}"
KNOWLEDGE_BASE_DELETE_RC=$?
set -e

if [[ ${KNOWLEDGE_BASE_DELETE_RC} -ne 0 ]]; then
  warn "Knowledge base cleanup returned a non-zero exit code"
fi

log "[4/8] Deleting vector index"
set +e
try_delete_index "${VECTOR_BUCKET_NAME}" "${INDEX_NAME}"
INDEX_DELETE_RC=$?
set -e

if [[ ${INDEX_DELETE_RC} -ne 0 ]]; then
  warn "Vector index cleanup returned a non-zero exit code"
fi

log "[5/8] Deleting vector bucket"
set +e
try_delete_vector_bucket "${VECTOR_BUCKET_NAME}"
VECTOR_BUCKET_DELETE_RC=$?
set -e

if [[ ${VECTOR_BUCKET_DELETE_RC} -ne 0 ]]; then
  warn "Vector bucket cleanup returned a non-zero exit code"
fi

log "[6/8] Emptying and deleting S3 data source bucket"
set +e
try_delete_s3_bucket "${S3_BUCKET}"
S3_BUCKET_DELETE_RC=$?
set -e

if [[ ${S3_BUCKET_DELETE_RC} -ne 0 ]]; then
  warn "S3 bucket cleanup returned a non-zero exit code"
fi

log "[7/8] Best-effort cleanup of IAM role"
set +e
try_delete_role "${ROLE_NAME}"
ROLE_DELETE_RC=$?
set -e

if [[ ${ROLE_DELETE_RC} -ne 0 ]]; then
  warn "IAM role cleanup returned a non-zero exit code"
fi

log "[8/8] Deleting CloudFormation stack record"
set +e
delete_stack_last
STACK_DELETE_RC=$?
set -e

if [[ ${STACK_DELETE_RC} -ne 0 ]]; then
  warn "CloudFormation stack cleanup returned a non-zero exit code"
fi

log "Cleanup finished"
log "If any best-effort step warned, inspect the remaining resources in AWS console or CLI."
