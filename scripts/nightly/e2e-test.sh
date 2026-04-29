#!/bin/bash
set -euo pipefail

# Script: Run Playwright E2E Tests Against a Deployed Nightly Stack
# Description: Installs Playwright browsers, resolves the frontend CloudFront
#              URL, and runs the full E2E suite using the CI-specific Playwright
#              config.
#
# Required environment variables:
#   CDK_PROJECT_PREFIX    — CDK project prefix (e.g. nightly-develop)
#   CDK_AWS_REGION        — AWS region for CloudFormation lookups
#   ADMIN_USERNAME        — Cognito admin test account username
#   ADMIN_PASSWORD        — Cognito admin test account password
#   USER_USERNAME         — Cognito regular user test account username
#   USER_PASSWORD         — Cognito regular user test account password
#
# The script resolves the frontend URL from:
#   1. SSM parameter /${CDK_PROJECT_PREFIX}/frontend/url (set by FrontendStack)
#   2. CloudFormation WebsiteUrl output from FrontendStack
#   3. CloudFormation DistributionDomainName output from FrontendStack

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FRONTEND_DIR="${PROJECT_ROOT}/frontend/ai.client"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# ---------------------------------------------------------------------------
# Resolve the frontend URL of the deployed stack (CloudFront / S3)
# ---------------------------------------------------------------------------
get_base_url() {
    # Try SSM parameter first (set by FrontendStack)
    local ssm_key="/${CDK_PROJECT_PREFIX}/frontend/url"
    local frontend_url
    frontend_url=$(aws ssm get-parameter \
        --name "${ssm_key}" \
        --query "Parameter.Value" \
        --output text \
        --region "${CDK_AWS_REGION}" 2>/dev/null || true)

    if [ -n "${frontend_url}" ] && [ "${frontend_url}" != "None" ]; then
        # SSM value may already include https:// or may be a bare domain
        if [[ "${frontend_url}" == https://* ]]; then
            echo "${frontend_url}"
        else
            echo "https://${frontend_url}"
        fi
        return 0
    fi

    # Fallback: query CloudFormation WebsiteUrl output from FrontendStack
    local stack_name="${CDK_PROJECT_PREFIX}-FrontendStack"
    frontend_url=$(aws cloudformation describe-stacks \
        --stack-name "${stack_name}" \
        --query "Stacks[0].Outputs[?OutputKey=='WebsiteUrl'].OutputValue" \
        --output text \
        --region "${CDK_AWS_REGION}" 2>/dev/null || true)

    if [ -n "${frontend_url}" ] && [ "${frontend_url}" != "None" ]; then
        if [[ "${frontend_url}" == https://* ]]; then
            echo "${frontend_url}"
        else
            echo "https://${frontend_url}"
        fi
        return 0
    fi

    # Last resort: query CloudFront distribution domain from FrontendStack
    local cf_domain
    cf_domain=$(aws cloudformation describe-stacks \
        --stack-name "${stack_name}" \
        --query "Stacks[0].Outputs[?OutputKey=='DistributionDomainName'].OutputValue" \
        --output text \
        --region "${CDK_AWS_REGION}" 2>/dev/null || true)

    if [ -n "${cf_domain}" ] && [ "${cf_domain}" != "None" ]; then
        echo "https://${cf_domain}"
        return 0
    fi

    log_error "Could not resolve frontend URL from SSM (${ssm_key}) or FrontendStack outputs"
    return 1
}

# ---------------------------------------------------------------------------
# Patch Cognito App Client callback URLs to include the dynamic CloudFront URL
# ---------------------------------------------------------------------------
# The nightly stack has no custom domain, so the CloudFront distribution URL
# changes every run. Cognito rejects OAuth redirects to URLs not in its
# allowlist, so we must add the CloudFront URL before running auth tests.
# ---------------------------------------------------------------------------
patch_cognito_callback_urls() {
    local frontend_url="$1"
    local callback_url="${frontend_url}/auth/callback"
    local logout_url="${frontend_url}"

    # Fetch Cognito resource IDs from SSM
    local user_pool_id
    user_pool_id=$(aws ssm get-parameter \
        --name "/${CDK_PROJECT_PREFIX}/auth/cognito/user-pool-id" \
        --query "Parameter.Value" --output text \
        --region "${CDK_AWS_REGION}")

    local client_id
    client_id=$(aws ssm get-parameter \
        --name "/${CDK_PROJECT_PREFIX}/auth/cognito/app-client-id" \
        --query "Parameter.Value" --output text \
        --region "${CDK_AWS_REGION}")

    log_info "  User Pool ID: ${user_pool_id}"
    log_info "  Client ID:    ${client_id}"

    # Read current app client settings
    local current_config
    current_config=$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "${user_pool_id}" \
        --client-id "${client_id}" \
        --region "${CDK_AWS_REGION}" \
        --output json)

    # Extract existing callback and logout URLs
    local existing_callbacks
    existing_callbacks=$(echo "${current_config}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
urls = data['UserPoolClient'].get('CallbackURLs', [])
print('\n'.join(urls))
")

    local existing_logouts
    existing_logouts=$(echo "${current_config}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
urls = data['UserPoolClient'].get('LogoutURLs', [])
print('\n'.join(urls))
")

    # Check if the CloudFront callback URL is already present
    if echo "${existing_callbacks}" | grep -qF "${callback_url}"; then
        log_info "  Callback URL already present — skipping patch"
        return 0
    fi

    # Build updated URL lists using python3 for reliable JSON construction
    local callbacks_json
    callbacks_json=$(echo "${current_config}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
urls = data['UserPoolClient'].get('CallbackURLs', [])
urls.append('${callback_url}')
print(json.dumps(urls))
")

    local logouts_json
    logouts_json=$(echo "${current_config}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
urls = data['UserPoolClient'].get('LogoutURLs', [])
new_url = '${logout_url}'
if new_url not in urls:
    urls.append(new_url)
print(json.dumps(urls))
")

    log_info "  Adding callback URL: ${callback_url}"
    log_info "  Adding logout URL:   ${logout_url}"

    # Extract current OAuth settings to preserve them
    local allowed_flows
    allowed_flows=$(echo "${current_config}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
flows = data['UserPoolClient'].get('AllowedOAuthFlows', [])
print(' '.join(flows))
")

    local allowed_scopes
    allowed_scopes=$(echo "${current_config}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
scopes = data['UserPoolClient'].get('AllowedOAuthScopes', [])
print(' '.join(scopes))
")

    # Update the app client with the new callback/logout URLs
    aws cognito-idp update-user-pool-client \
        --user-pool-id "${user_pool_id}" \
        --client-id "${client_id}" \
        --callback-urls "${callbacks_json}" \
        --logout-urls "${logouts_json}" \
        --allowed-o-auth-flows ${allowed_flows} \
        --allowed-o-auth-scopes ${allowed_scopes} \
        --allowed-o-auth-flows-user-pool-client \
        --supported-identity-providers COGNITO \
        --region "${CDK_AWS_REGION}" \
        --no-cli-pager > /dev/null

    log_success "  Cognito app client patched successfully"
}

# ---------------------------------------------------------------------------
# Patch App API ECS service CORS_ORIGINS to include the CloudFront URL
# ---------------------------------------------------------------------------
# The nightly stack has no custom domain, so the frontend is served from a
# dynamic CloudFront URL that isn't known at CDK deploy time. The App API's
# CORS_ORIGINS env var therefore doesn't include it, causing all cross-origin
# API requests to fail. This function:
#   1. Reads the current ECS task definition
#   2. Appends the CloudFront origin to CORS_ORIGINS
#   3. Registers a new task definition revision
#   4. Updates the ECS service to use it
#   5. Waits for the service to stabilize
# ---------------------------------------------------------------------------
patch_app_api_cors() {
    local frontend_url="$1"

    # Resolve ECS cluster and service names from SSM
    local cluster_name
    cluster_name=$(aws ssm get-parameter \
        --name "/${CDK_PROJECT_PREFIX}/network/ecs-cluster-name" \
        --query "Parameter.Value" --output text \
        --region "${CDK_AWS_REGION}")

    local service_name="${CDK_PROJECT_PREFIX}-app-api-service"

    log_info "  Cluster: ${cluster_name}"
    log_info "  Service: ${service_name}"

    # Get the current task definition ARN from the service
    local task_def_arn
    task_def_arn=$(aws ecs describe-services \
        --cluster "${cluster_name}" \
        --services "${service_name}" \
        --query "services[0].taskDefinition" \
        --output text \
        --region "${CDK_AWS_REGION}")

    log_info "  Current task definition: ${task_def_arn}"

    # Get the full task definition
    local task_def_json
    task_def_json=$(aws ecs describe-task-definition \
        --task-definition "${task_def_arn}" \
        --query "taskDefinition" \
        --output json \
        --region "${CDK_AWS_REGION}")

    # Check current CORS_ORIGINS value
    local current_cors
    current_cors=$(echo "${task_def_json}" | python3 -c "
import sys, json
td = json.load(sys.stdin)
for container in td.get('containerDefinitions', []):
    for env in container.get('environment', []):
        if env['name'] == 'CORS_ORIGINS':
            print(env['value'])
            sys.exit(0)
print('')
")

    log_info "  Current CORS_ORIGINS: ${current_cors:-<empty>}"

    # Check if the frontend URL is already in CORS_ORIGINS
    if echo "${current_cors}" | grep -qF "${frontend_url}"; then
        log_info "  CloudFront origin already in CORS_ORIGINS — skipping patch"
        return 0
    fi

    # Build new CORS_ORIGINS value
    local new_cors
    if [ -n "${current_cors}" ]; then
        new_cors="${current_cors},${frontend_url}"
    else
        new_cors="${frontend_url}"
    fi

    log_info "  New CORS_ORIGINS: ${new_cors}"

    # Register a new task definition revision with updated CORS_ORIGINS
    # We need to extract the relevant fields and update the environment variable
    local new_task_def
    new_task_def=$(echo "${task_def_json}" | NEW_CORS="${new_cors}" python3 -c "
import sys, json, os

td = json.load(sys.stdin)
new_cors_value = os.environ['NEW_CORS']

# Update CORS_ORIGINS in container environment
for container in td.get('containerDefinitions', []):
    found = False
    for env in container.get('environment', []):
        if env['name'] == 'CORS_ORIGINS':
            env['value'] = new_cors_value
            found = True
            break
    if not found:
        container.setdefault('environment', []).append({
            'name': 'CORS_ORIGINS',
            'value': new_cors_value
        })

# Build the register-task-definition input (only allowed fields)
register_input = {
    'family': td['family'],
    'containerDefinitions': td['containerDefinitions'],
    'taskRoleArn': td.get('taskRoleArn', ''),
    'executionRoleArn': td.get('executionRoleArn', ''),
    'networkMode': td.get('networkMode', 'awsvpc'),
    'requiresCompatibilities': td.get('requiresCompatibilities', ['FARGATE']),
    'cpu': td.get('cpu', ''),
    'memory': td.get('memory', ''),
}

# Include runtimePlatform only if present (not all task defs have it)
if 'runtimePlatform' in td and td['runtimePlatform']:
    register_input['runtimePlatform'] = td['runtimePlatform']

# Remove empty optional fields
register_input = {k: v for k, v in register_input.items() if v}

print(json.dumps(register_input))
")

    # Write to a temp file — aws cli's file:///dev/stdin is unreliable across environments
    local tmp_file
    tmp_file=$(mktemp /tmp/task-def-XXXXXX.json)
    echo "${new_task_def}" > "${tmp_file}"

    local new_task_def_arn
    new_task_def_arn=$(aws ecs register-task-definition \
        --cli-input-json "file://${tmp_file}" \
        --query "taskDefinition.taskDefinitionArn" \
        --output text \
        --region "${CDK_AWS_REGION}")

    rm -f "${tmp_file}"

    log_info "  Registered new task definition: ${new_task_def_arn}"

    # Update the ECS service to use the new task definition
    aws ecs update-service \
        --cluster "${cluster_name}" \
        --service "${service_name}" \
        --task-definition "${new_task_def_arn}" \
        --force-new-deployment \
        --region "${CDK_AWS_REGION}" \
        --no-cli-pager > /dev/null

    log_info "  ECS service update initiated — waiting for stabilization..."

    # Wait for the service to stabilize (new tasks running with updated CORS)
    aws ecs wait services-stable \
        --cluster "${cluster_name}" \
        --services "${service_name}" \
        --region "${CDK_AWS_REGION}" 2>/dev/null || true

    # Verify the service is healthy by hitting the health endpoint
    local alb_url
    alb_url=$(aws ssm get-parameter \
        --name "/${CDK_PROJECT_PREFIX}/network/alb-url" \
        --query "Parameter.Value" --output text \
        --region "${CDK_AWS_REGION}" 2>/dev/null || true)

    if [ -n "${alb_url}" ] && [ "${alb_url}" != "None" ]; then
        log_info "  Verifying App API health after CORS patch..."
        local retries=0
        local max_retries=20
        while [ ${retries} -lt ${max_retries} ]; do
            local status_code
            status_code=$(curl -s -o /dev/null -w "%{http_code}" "${alb_url}/health" --max-time 10 || echo "000")
            if [ "${status_code}" = "200" ]; then
                log_success "  App API healthy after CORS patch (HTTP 200)"
                return 0
            fi
            retries=$((retries + 1))
            if [ ${retries} -lt ${max_retries} ]; then
                log_info "  Health check returned HTTP ${status_code}, retrying in 15s... (${retries}/${max_retries})"
                sleep 15
            fi
        done
        log_warn "  App API health check did not return 200 after ${max_retries} attempts — proceeding anyway"
    fi

    log_success "  App API CORS patched successfully"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_info "Starting Playwright E2E tests against deployed nightly stack..."

    # --- Validate required env vars ---
    local missing=()
    [ -z "${CDK_PROJECT_PREFIX:-}" ]  && missing+=("CDK_PROJECT_PREFIX")
    [ -z "${CDK_AWS_REGION:-}" ]      && missing+=("CDK_AWS_REGION")
    [ -z "${ADMIN_USERNAME:-}" ]      && missing+=("ADMIN_USERNAME")
    [ -z "${ADMIN_PASSWORD:-}" ]      && missing+=("ADMIN_PASSWORD")
    [ -z "${USER_USERNAME:-}" ]       && missing+=("USER_USERNAME")
    [ -z "${USER_PASSWORD:-}" ]       && missing+=("USER_PASSWORD")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required environment variables: ${missing[*]}"
        exit 1
    fi

    # --- Resolve base URL ---
    log_info "Resolving deployed stack URL..."
    local base_url
    base_url=$(get_base_url)
    log_info "Base URL: ${base_url}"

    # --- Verify frontend is reachable ---
    log_info "Verifying frontend is reachable..."
    local response_code
    response_code=$(curl -s -o /dev/null -w "%{http_code}" "${base_url}" --max-time 30 || echo "000")
    if [ "${response_code}" = "000" ]; then
        log_error "Frontend is not reachable at ${base_url} (connection failed)"
        exit 1
    fi
    log_info "Frontend responded with HTTP ${response_code}"

    # --- Patch App API CORS to allow requests from the CloudFront origin ---
    log_info "Patching App API CORS origins to include CloudFront URL..."
    patch_app_api_cors "${base_url}"

    # --- Ensure Cognito allows the dynamic CloudFront callback URL ---
    log_info "Patching Cognito app client with CloudFront callback URL..."
    patch_cognito_callback_urls "${base_url}"

    # --- Seed E2E test users in Cognito ---
    log_info "Seeding E2E test users in Cognito User Pool..."
    bash "${SCRIPT_DIR}/seed-e2e-users.sh"

    # --- Seed bootstrap data (models, tools, roles, quotas) ---
    # The nightly stack deploys fresh empty DynamoDB tables. The e2e tests
    # expect models, tools, and RBAC roles to exist. The bootstrap seed
    # script is idempotent and resolves table names from SSM.
    log_info "Seeding bootstrap data (models, tools, roles, quotas)..."
    pip install boto3 --quiet 2>/dev/null || pip3 install boto3 --quiet 2>/dev/null || true
    bash "${PROJECT_ROOT}/scripts/stack-bootstrap/seed.sh"

    # --- Change to frontend directory ---
    cd "${FRONTEND_DIR}"

    # --- Check node_modules ---
    if [ ! -d "node_modules" ]; then
        log_error "node_modules not found. Frontend dependencies must be installed first."
        exit 1
    fi

    # --- Install Playwright browsers ---
    log_info "Installing Playwright browsers (chromium only)..."
    npx playwright install --with-deps chromium

    # --- Run E2E tests ---
    log_info "Running Playwright E2E tests..."
    log_info "  Config: playwright.ci.config.ts"
    log_info "  Base URL: ${base_url}"

    export E2E_BASE_URL="${base_url}"
    export CI=true

    # Run tests — allow failure so we can still upload artifacts
    local exit_code=0
    npx playwright test --config=playwright.ci.config.ts || exit_code=$?

    if [ ${exit_code} -eq 0 ]; then
        log_success "All E2E tests passed!"
    else
        log_error "E2E tests failed with exit code: ${exit_code}"
    fi

    # Report location is always relative to the config file
    if [ -d "playwright-report" ]; then
        log_info "HTML report generated: playwright-report/index.html"
    fi

    return ${exit_code}
}

main "$@"
