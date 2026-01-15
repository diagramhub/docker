#!/usr/bin/env bash

# Setup Entra ID Application Registration for diagramHub Self-Hosted
#
# Creates (or patches) an application registration in Azure Entra ID and configures it
# per README.md:
# - Accounts in this organizational directory only (AzureADMyOrg)
# - Platform: Single-page application
# - Redirect URI: <APP_SCHEME>://<APP_FQDN>
# - Expose an API: Application ID URI = api://<CLIENT_ID>
# - Add scope: user_impersonation

set -euo pipefail

# Default values (can also be overridden by env vars)
APP_NAME="${APP_NAME:-diagramHub Self-Hosted}"
APP_FQDN="${APP_FQDN:-localhost}"
APP_SCHEME="${APP_SCHEME:-http}"
SCOPE_NAME="user_impersonation"
SCOPE_DESCRIPTION="${SCOPE_DESCRIPTION:-Allows the application to access diagramHub on behalf of the user}"

# Microsoft Graph (well-known IDs)
MS_GRAPH_RESOURCE_APP_ID="00000003-0000-0000-c000-000000000000"
# Delegated permission scope id for Microsoft Graph: User.Read
MS_GRAPH_USER_READ_SCOPE_ID="e1fe6dd8-ba31-4d61-89e7-88639da4683d"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options (or set equivalent env vars):
  --app-name NAME            (env: APP_NAME)   Default: "diagramHub Self-Hosted"
  --app-fqdn FQDN            (env: APP_FQDN)   Default: "localhost"
  --app-scheme SCHEME        (env: APP_SCHEME) Default: "http"
  --scope-description TEXT   (env: SCOPE_DESCRIPTION)
  -h, --help                 Show help

Examples:
  APP_FQDN=app.example.com APP_SCHEME=https $0
  $0 --app-name "diagramHub Self-Hosted" --app-fqdn localhost --app-scheme http
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      APP_NAME="$2"; shift 2;;
    --app-fqdn)
      APP_FQDN="$2"; shift 2;;
    --app-scheme)
      APP_SCHEME="$2"; shift 2;;
    --scope-description)
      SCOPE_DESCRIPTION="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"; usage; exit 1;;
  esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}diagramHub Entra ID Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI is not installed. Please install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is not installed. Please install it (e.g. 'apt-get install -y jq')."
  exit 1
fi

# Check if user is logged in
if ! az account show &> /dev/null; then
    echo "You are not logged in to Azure. Please run 'az login' first."
    exit 1
fi

REDIRECT_URI="${APP_SCHEME}://${APP_FQDN}"

# Display current settings
echo -e "${YELLOW}Configuration:${NC}"
echo "  Application Name: $APP_NAME"
echo "  App FQDN: $APP_FQDN"
echo "  App Scheme: $APP_SCHEME"
echo "  Redirect URI: $REDIRECT_URI"
echo ""

# Step 1: Create or reuse the application
echo -e "${BLUE}Step 1: Creating (or reusing) application registration...${NC}"

EXISTING_APPS_JSON=$(az ad app list --display-name "$APP_NAME" --output json)
EXISTING_COUNT=$(echo "$EXISTING_APPS_JSON" | jq 'length')

if [[ "$EXISTING_COUNT" -gt 0 ]]; then
  if [[ "$EXISTING_COUNT" -gt 1 ]]; then
    echo -e "${YELLOW}WARNING: Found multiple app registrations named '$APP_NAME'. Using the first match.${NC}"
  else
    echo -e "${YELLOW}WARNING: Found an existing application instance. We will patch it.${NC}"
  fi

  APP_ID=$(echo "$EXISTING_APPS_JSON" | jq -r '.[0].appId')
  APP_OBJ_ID=$(echo "$EXISTING_APPS_JSON" | jq -r '.[0].id')
else
  APP_OUTPUT=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience AzureADMyOrg)

  APP_ID=$(echo "$APP_OUTPUT" | jq -r '.appId')
  APP_OBJ_ID=$(echo "$APP_OUTPUT" | jq -r '.id')
fi

echo -e "${GREEN}✓ Application ready${NC}"
echo "  Client ID: $APP_ID"
echo "  Object ID: $APP_OBJ_ID"
echo ""

# Step 2: Configure as Single-Page Application (SPA)
echo -e "${BLUE}Step 2: Configuring as Single-Page Application...${NC}"

CURRENT_APP_JSON=$(az ad app show --id "$APP_ID" --output json)
CURRENT_REDIRECT_URIS=$(echo "$CURRENT_APP_JSON" | jq -c '.spa.redirectUris // []')
UPDATED_REDIRECT_URIS=$(echo "$CURRENT_REDIRECT_URIS" | jq -c --arg uri "$REDIRECT_URI" 'if index($uri) then . else . + [$uri] end')

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJ_ID}" \
  --headers "Content-Type=application/json" \
  --body "$(jq -cn --argjson redirectUris "$UPDATED_REDIRECT_URIS" '{spa:{redirectUris:$redirectUris}}')" \
  > /dev/null

echo -e "${GREEN}✓ SPA configuration applied${NC}"
echo ""

# Step 3: Expose an API and create scope
echo -e "${BLUE}Step 3: Exposing API and creating scope...${NC}"

# First, add the API exposure
az ad app update \
  --id "$APP_ID" \
  --set identifierUris="[\"api://${APP_ID}\"]"

echo -e "${GREEN}✓ API exposed with URI: api://${APP_ID}${NC}"
echo ""

# Step 4: Add the user_impersonation scope
echo -e "${BLUE}Step 4: Adding scope...${NC}"

SCOPE_UUID=""
if command -v uuidgen &> /dev/null; then
  SCOPE_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
elif command -v python3 &> /dev/null; then
  SCOPE_UUID=$(python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
)
else
  echo "Error: uuidgen or python3 is required to generate a scope id.";
  exit 1
fi

CURRENT_APP_JSON=$(az ad app show --id "$APP_ID" --output json)
CURRENT_SCOPES=$(echo "$CURRENT_APP_JSON" | jq -c '.api.oauth2PermissionScopes // []')

SCOPE_EXISTS=$(echo "$CURRENT_SCOPES" | jq -r --arg v "$SCOPE_NAME" 'map(select(.value == $v)) | length')
if [[ "$SCOPE_EXISTS" -gt 0 ]]; then
  echo -e "${GREEN}✓ Scope '${SCOPE_NAME}' already exists${NC}"
else
  NEW_SCOPE=$(jq -cn \
    --arg name "$SCOPE_NAME" \
    --arg desc "$SCOPE_DESCRIPTION" \
    --arg id "$SCOPE_UUID" \
    '{adminConsentDescription:$desc,adminConsentDisplayName:$name,id:$id,isEnabled:true,type:"User",userConsentDescription:$desc,userConsentDisplayName:$name,value:$name}')

  UPDATED_SCOPES=$(echo "$CURRENT_SCOPES" | jq -c --argjson s "$NEW_SCOPE" '. + [$s]')

  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJ_ID}" \
    --headers "Content-Type=application/json" \
    --body "$(jq -cn --argjson scopes "$UPDATED_SCOPES" '{api:{oauth2PermissionScopes:$scopes}}')" \
    > /dev/null

  echo -e "${GREEN}✓ Scope '${SCOPE_NAME}' added${NC}"
fi
echo ""

  # Step 5: Add default Microsoft Graph delegated permission User.Read
  echo -e "${BLUE}Step 5: Adding default Microsoft Graph permission (User.Read)...${NC}"

  CURRENT_APP_JSON=$(az ad app show --id "$APP_ID" --output json)
  GRAPH_ACCESS=$(echo "$CURRENT_APP_JSON" | jq -c --arg appId "$MS_GRAPH_RESOURCE_APP_ID" '(.requiredResourceAccess // []) | map(select(.resourceAppId == $appId)) | .[0].resourceAccess // []')
  USER_READ_EXISTS=$(echo "$GRAPH_ACCESS" | jq -r --arg id "$MS_GRAPH_USER_READ_SCOPE_ID" 'map(select(.id == $id and (.type == "Scope"))) | length')

  if [[ "$USER_READ_EXISTS" -gt 0 ]]; then
    echo -e "${GREEN}✓ Microsoft Graph delegated permission 'User.Read' already present${NC}"
  else
    az ad app permission add \
      --id "$APP_ID" \
      --api "$MS_GRAPH_RESOURCE_APP_ID" \
      --api-permissions "${MS_GRAPH_USER_READ_SCOPE_ID}=Scope" \
      > /dev/null

    echo -e "${GREEN}✓ Microsoft Graph delegated permission 'User.Read' added${NC}"
    echo -e "${YELLOW}Note:${NC} Depending on your tenant policies, you may need to grant consent for this permission in the Entra portal."
  fi
  echo ""

  # Step 6: Get tenant information
  echo -e "${BLUE}Step 6: Retrieving tenant information...${NC}"
TENANT_ID=$(az account show --query tenantId --output tsv)

echo -e "${GREEN}✓ Tenant ID: $TENANT_ID${NC}"
echo ""

# Step 7: Display summary
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Add the following to your .env file:"
echo ""
echo "ENTRA_TENANT_ID=$TENANT_ID"
echo "ENTRA_CLIENT_ID=$APP_ID"
echo ""
echo "Additional Configuration:"
echo "  - Application Name: $APP_NAME"
echo "  - Redirect URI: ${APP_SCHEME}://${APP_FQDN}"
echo ""


