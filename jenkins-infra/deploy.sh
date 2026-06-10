#!/usr/bin/env bash
set -euo pipefail

# Bind variables
RESOURCE_GROUP="rg-jenkins-infra-dev"
LOCATION="eastus"
TEMPLATE_FILE="$(dirname "$0")/azuredeploy.json"
SSH_PUBLIC_KEY="${1:-}"

# Check for required SSH Key input parameter
if [ -z "$SSH_PUBLIC_KEY" ]; then
    echo "ERROR: SSH Public Key argument is missing." >&2
    exit 1
fi

echo "========================================="
echo "  Creating Resource Group if not exists  "
echo "========================================="
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

echo "========================================="
echo "  Executing Deployment What-If Validation "
echo "========================================="
az deployment group what-if \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_FILE" \
  --parameters vmName="jenkins-vm" sshPublicKey="$SSH_PUBLIC_KEY"
