#!/usr/bin/env bash
set -euo pipefail

# ── Variables (kept in sync with azure-pipeline.yml) ──────────────────
RESOURCE_GROUP="rg-jenkins-infra-dev"
LOCATION="eastus2"

# Paths are relative to the repo root (jenkins-infra/), resolved from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/arm-template/azuredeploy.json"
PARAMETERS_FILE="${SCRIPT_DIR}/Jenkins/azuredeploy.parameters.json"

SSH_PUBLIC_KEY="${1:-}"

# ── Guard: SSH key must be provided ───────────────────────────────────
if [ -z "$SSH_PUBLIC_KEY" ]; then
    echo "ERROR: SSH Public Key argument is missing." >&2
    echo "Usage: bash deploy.sh '<ssh-public-key>'" >&2
    exit 1
fi

# ── Guard: template file must exist ───────────────────────────────────
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERROR: ARM template not found at: $TEMPLATE_FILE" >&2
    echo "Current working directory: $(pwd)" >&2
    echo "Script directory: $SCRIPT_DIR" >&2
    exit 1
fi

echo "========================================="
echo "  Creating Resource Group if not exists  "
echo "========================================="
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output table

echo ""
echo "========================================="
echo "  Running ARM Template Validation        "
echo "========================================="
az deployment group validate \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_FILE" \
  --parameters "@${PARAMETERS_FILE}" \
  --parameters sshPublicKey="$SSH_PUBLIC_KEY" \
  --output table

echo ""
echo "========================================="
echo "  Executing Deployment What-If           "
echo "========================================="
az deployment group what-if \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_FILE" \
  --parameters "@${PARAMETERS_FILE}" \
  --parameters sshPublicKey="$SSH_PUBLIC_KEY" \
  --output table

echo ""
echo "========================================="
echo "  Validate stage PASSED                  "
echo "========================================="