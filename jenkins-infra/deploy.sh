#!/usr/bin/env bash
set -euo pipefail

# Bind variables
RESOURCE_GROUP="rg-jenkins-infra-dev"
LOCATION="eastus2"
TEMPLATE_FILE="$(dirname "$0")/arm-template/azuredeploy.json"

# Bind inputs passed from pipeline arguments matrix
SSH_PUBLIC_KEY="${1:-}"
VM_SIZE="${2:-Standard_B2ats_v2}" # Falls back to v2 trial SKU if blank

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
  --parameters vmName="jenkins-vm" vmSize="$VM_SIZE" sshPublicKey="$SSH_PUBLIC_KEY"
