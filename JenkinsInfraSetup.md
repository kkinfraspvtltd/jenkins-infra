# Jenkins Infrastructure — Azure Setup Guide

Repo reference: [jenkins-infra](https://github.com/kkinfraspvtltd/jenkins-infra/tree/actual-folder-structure/jenkins-infra)

```
jenkins-infra/
├── Jenkins/
│   └── azuredeploy.parameters.json   # Input values fed into the ARM template
├── arm-template/
│   └── azuredeploy.json              # Defines the Azure resources (VNet, NSG, IP, VM)
└── azure-pipeline.yml                # Azure DevOps pipeline: validates + deploys the ARM template
```

1. [Prerequisites](#1-prerequisites)
2. [Infrastructure files explained](#2-infrastructure-files-explained)
3. [Run the pipeline (provisions the VM only)](#3-run-the-pipeline-provisions-the-vm-only)
4. [Manual Server Configuration — Step-by-Step](#4-manual-server-configuration--step-by-step)
5. [Security Hardening (do this immediately after first login)](#5-security-hardening-do-this-immediately-after-first-login)
6. [Cost Optimization — Auto-Shutdown](#6-cost-optimization--auto-shutdown)
7. [Future Scale Ideas](#8-future-scale-ideas)

---

## 1. Prerequisites

### 1.1 Azure subscription access
You need an **Azure subscription** with permissions to create Resource Groups and Virtual Machines (`Contributor` role is sufficient).

### 1.2 Create the Azure DevOps Service Connection

The pipeline authenticates to Azure using a **Service Connection** named `azure-service-connection`. If it doesn't exist yet in your Azure DevOps project, create it first — the pipeline will fail immediately without it.

1. In Azure DevOps, go to **Project Settings → Service connections → New service connection**.
2. Choose **Azure Resource Manager**.
3. Choose **Service principal (automatic)** — this is the simplest option; Azure DevOps creates and manages the credentials for you.
4. Select your **Subscription**, leave **Resource Group** blank (we want subscription-wide access since the pipeline creates the resource group itself).
5. Set the **Service connection name** to exactly: `azure-service-connection` (must match the `azureServiceConnection` variable in `azure-pipeline.yml`).
6. Under **Security**, grant access permission to all pipelines (or restrict to this one specifically — your call, but "all pipelines" is simplest for a small team).
7. Click **Save**.

### 1.3 Generate an SSH key pair

This key pair lets you log into the VM without a password. Generate it **locally** (on your laptop, not on Azure) — never generate or store private keys in the repo or pipeline.

```bash
ssh-keygen -t rsa -b 4096 -C "jenkins-azure-vm" -f ~/.ssh/jenkins_azure_vm
```
- `-t rsa -b 4096` → RSA key, 4096-bit (matches what the ARM template expects: `ssh-rsa` format).
- `-C "..."` → a comment to help you identify the key later.
- `-f ~/.ssh/jenkins_azure_vm` → custom filename so it doesn't overwrite your default `id_rsa`.

This creates two files:
- `~/.ssh/jenkins_azure_vm` — **private key**. Keep this on your machine only. Never commit it, never paste it into Azure DevOps.
- `~/.ssh/jenkins_azure_vm.pub` — **public key**. This is safe to share/commit — it's what goes into the parameters file and the pipeline variable.

View the public key to copy it:
```bash
cat ~/.ssh/jenkins_azure_vm.pub
```

You'll use this same public key string in **two places**:
1. Pasted into `Jenkins/azuredeploy.parameters.json` (the `sshPublicKey` value) — used when running `az deployment group validate/what-if` locally or as a fallback default.
2. Added as a **secret pipeline variable** called `SSH_PUBLIC_KEY` in Azure DevOps (see next step) — this is what the pipeline actually uses at deploy time, overriding the parameters file value via `--parameters sshPublicKey="$SSH_KEY"`.

### 1.4 Add the `SSH_PUBLIC_KEY` pipeline variable

1. Azure DevOps → Pipelines → select the `jenkins-infra` pipeline → **Edit**.
2. Click **Variables** → **New variable**.
3. Name: `SSH_PUBLIC_KEY`
4. Value: paste the contents of `jenkins_azure_vm.pub`
5. Check **Keep this value secret** (encrypts it; it won't show in logs).
6. Click **OK**, then **Save**.

> Without this variable set, Stage 1 (`Validate`) will fail fast with an explicit error message — see the `if [ -z "${SSH_KEY:-}" ]` check in the pipeline (explained below).

---

## 2. Infrastructure files explained

### 2.1 `Jenkins/azuredeploy.parameters.json`

Supplies the actual values the ARM template needs at deploy time.

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  // Standard ARM parameters-file schema/version — don't change unless the template version changes.
  "contentVersion": "1.0.0.0",

  "parameters": {
    "vmName": { "value": "jenkins-vm" },
    // Name of the VM as it will appear in the Azure Portal.

    "adminUsername": { "value": "azureuser" },
    // Linux login user created on the VM. Password auth is disabled — SSH key only.

    "sshPublicKey": { "value": "ssh-rsa AAAA...your-key... jenkins-azure-vm" },
    // Default/fallback public key. The pipeline overrides this at deploy time with the
    // SSH_PUBLIC_KEY pipeline variable, so this value mainly matters for local/manual
    // `az deployment` testing. Public keys are safe to commit.

    "location": { "value": "eastus2" },
    // Azure region. Must match a region where your chosen vmSize is available.

    "vmSize": { "value": "Standard_B2s" },
    // 2 vCPU / 4 GB RAM. The pipeline auto-detects and overrides this with whichever SKU
    // is actually available in your subscription (see azure-pipeline.yml Stage 1).

    "environment": { "value": "dev" }
    // Tag used in resource naming/tags. Allowed values per the template: dev | staging | prod.
  }
}
```
---

### 2.2 `arm-template/azuredeploy.json`

The Azure Resource Manager (ARM) template — the literal blueprint of what gets created. ARM templates are declarative JSON: you describe the *end state* you want, and Azure figures out how to get there (create/update/skip as needed).

**High-level structure:**

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  // Tells Azure which ARM template schema version to validate against.
  "contentVersion": "1.0.0.0",
  // Free-text version tag for your own tracking — Azure doesn't enforce semantics on it.

  "parameters": { ... },   // Inputs — see below
  "variables": { ... },    // Computed/derived values built from parameters
  "resources": [ ... ],    // The actual Azure resources to create
  "outputs": { ... }       // Values to surface after deployment completes
}
```

#### `parameters` block

```json
"parameters": {
  "vmName":        { "type": "string", "defaultValue": "jenkins-vm" },
  "adminUsername": { "type": "string", "defaultValue": "azureuser" },
  "sshPublicKey":  { "type": "securestring" },
  // securestring = Azure won't echo this value back in deployment logs or the portal —
  // appropriate even though a public key isn't truly secret, just good hygiene.
  "location":      { "type": "string", "defaultValue": "[resourceGroup().location]" },
  // [resourceGroup().location] is an ARM template *function* — if no location is passed in,
  // default to whatever region the target resource group itself lives in.
  "vmSize":        { "type": "string", "defaultValue": "Standard_B2s" },
  "environment":   { "type": "string", "defaultValue": "dev", "allowedValues": ["dev","staging","prod"] }
  // allowedValues acts as input validation — deployment fails fast if someone passes "qa" or a typo.
}
```
These map 1:1 to what you saw in `azuredeploy.parameters.json` (§2.1) and to the `--parameters` flags the pipeline passes on the command line — command-line/file parameters always win over `defaultValue`.

#### `variables` block

```json
"variables": {
  "vnetName":     "[concat(parameters('vmName'), '-vnet')]",
  // concat() = string concatenation function. Result: "jenkins-vm-vnet".
  "subnetName":   "jenkins-subnet",
  "nsgName":      "[concat(parameters('vmName'), '-nsg')]",
  "publicIpName": "[concat(parameters('vmName'), '-pip')]",
  "nicName":      "[concat(parameters('vmName'), '-nic')]",
  "osDiskName":   "[concat(parameters('vmName'), '-osdisk')]",
  // All resource names are derived from vmName so everything stays consistently named and
  // grouped if you ever rename the VM in the parameters file.
  "addressPrefix": "10.0.0.0/16",
  // The VNet's overall private IP range (~65k addresses).
  "subnetPrefix":  "10.0.0.0/24"
  // The subnet carved out of that range (256 addresses) — where the VM's NIC actually lives.
}
```

#### `resources` block — created in this logical order

**1. Network Security Group (NSG)** — the cloud-level firewall:
```json
{
  "type": "Microsoft.Network/networkSecurityGroups",
  "name": "[variables('nsgName')]",
  "properties": {
    "securityRules": [
      { "name": "Allow-SSH",           "properties": { "priority": 100, "protocol": "Tcp", "access": "Allow", "direction": "Inbound", "destinationPortRange": "22" } },
      { "name": "Allow-Jenkins-UI",    "properties": { "priority": 110, "protocol": "Tcp", "access": "Allow", "direction": "Inbound", "destinationPortRange": "8080" } },
      { "name": "Allow-Jenkins-Agent", "properties": { "priority": 120, "protocol": "Tcp", "access": "Allow", "direction": "Inbound", "destinationPortRange": "50000" } }
    ]
  }
}
```
- `priority` — lower numbers are evaluated first (100–4096 range); each rule needs a unique priority.
- `sourceAddressPrefix: "*"` (on all three rules, not shown above for brevity) — currently allows traffic from **any IP on the internet**. This is the setting to tighten before `staging`/`prod` (see §2.2 note below and §5 hardening).
- This resource has **no `dependsOn`** — it's created first since nothing else needs to exist before it.

**2. Virtual Network + Subnet:**
```json
{
  "type": "Microsoft.Network/virtualNetworks",
  "name": "[variables('vnetName')]",
  "dependsOn": ["[resourceId('Microsoft.Network/networkSecurityGroups', variables('nsgName'))]"],
  // Must wait for the NSG to exist, because the subnet below attaches to it.
  "properties": {
    "addressSpace": { "addressPrefixes": ["[variables('addressPrefix')]"] },
    "subnets": [{
      "name": "[variables('subnetName')]",
      "properties": {
        "addressPrefix": "[variables('subnetPrefix')]",
        "networkSecurityGroup": { "id": "[resourceId('Microsoft.Network/networkSecurityGroups', variables('nsgName'))]" }
        // Binds the NSG's firewall rules to this specific subnet.
      }
    }]
  }
}
```

**3. Public IP Address:**
```json
{
  "type": "Microsoft.Network/publicIPAddresses",
  "name": "[variables('publicIpName')]",
  "sku": { "name": "Standard" },
  // Standard SKU = required for Static allocation method (Basic SKU only supports Dynamic).
  "properties": {
    "publicIPAllocationMethod": "Static",
    // Static = the IP never changes across VM restarts/deallocations. Important — without
    // this, every reboot could give you a different IP and break bookmarks/DNS.
    "dnsSettings": { "domainNameLabel": "[toLower(concat(parameters('vmName'), '-', parameters('environment')))]" }
    // Gives you a friendly FQDN like jenkins-vm-dev.eastus2.cloudapp.azure.com in addition
    // to the raw IP — toLower() because Azure DNS labels must be lowercase.
  }
}
```

**4. Network Interface (NIC):**
```json
{
  "type": "Microsoft.Network/networkInterfaces",
  "name": "[variables('nicName')]",
  "dependsOn": [
    "[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]",
    "[resourceId('Microsoft.Network/publicIPAddresses', variables('publicIpName'))]"
  ],
  // Needs both the subnet (to attach into) and the public IP (to bind) to already exist.
  "properties": {
    "ipConfigurations": [{
      "name": "ipconfig1",
      "properties": {
        "subnet": { "id": "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('vnetName'), variables('subnetName'))]" },
        "privateIPAllocationMethod": "Dynamic",
        // The private (internal 10.0.0.x) address can float — only the public IP is pinned static.
        "publicIPAddress": { "id": "[resourceId('Microsoft.Network/publicIPAddresses', variables('publicIpName'))]" }
      }
    }]
  }
}
```
This is the resource that actually glues networking to compute — the VM below references *this* NIC, not the VNet or public IP directly.

**5. Virtual Machine:**
```json
{
  "type": "Microsoft.Compute/virtualMachines",
  "name": "[parameters('vmName')]",
  "dependsOn": ["[resourceId('Microsoft.Network/networkInterfaces', variables('nicName'))]"],
  "tags": { "environment": "[parameters('environment')]", "purpose": "jenkins-server" },
  // Tags show up in the Azure Portal and cost-reporting — handy for filtering "all dev-tagged
  // resources" or "all jenkins-server resources" across a subscription.
  "properties": {
    "hardwareProfile": { "vmSize": "[parameters('vmSize')]" },
    "storageProfile": {
      "osDisk": { "name": "[variables('osDiskName')]", "createOption": "FromImage", "managedDisk": { "storageAccountType": "Premium_LRS" }, "diskSizeGB": 64 },
      // Premium_LRS = SSD-backed managed disk, locally redundant (3 copies within the datacenter).
      "imageReference": { "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy", "sku": "22_04-lts-gen2", "version": "latest" }
      // "Jammy" = Ubuntu 22.04's codename. Gen2 = newer VM generation (UEFI boot, larger disk/memory support).
    },
    "osProfile": {
      "computerName": "[parameters('vmName')]",
      "adminUsername": "[parameters('adminUsername')]",
      "linuxConfiguration": {
        "disablePasswordAuthentication": true,
        // SSH key only — no password login is possible at all. Don't remove this.
        "ssh": { "publicKeys": [{ "path": "[concat('/home/', parameters('adminUsername'), '/.ssh/authorized_keys')]", "keyData": "[parameters('sshPublicKey')]" }] }
        // Injects your public key straight into authorized_keys at first boot — this is how
        // `ssh azureuser@<ip>` works with zero manual key-copying.
      }
    },
    "networkProfile": { "networkInterfaces": [{ "id": "[resourceId('Microsoft.Network/networkInterfaces', variables('nicName'))]" }] }
  }
}
```

#### `outputs` block

```json
"outputs": {
  "vmPublicIP": { "type": "string", "value": "[reference(resourceId('Microsoft.Network/publicIPAddresses', variables('publicIpName'))).ipAddress]" },
  "vmFQDN":     { "type": "string", "value": "[...].dnsSettings.fqdn]" },
  "jenkinsURL": { "type": "string", "value": "[concat('http://', ...ipAddress, ':8080')]" },
  "sshCommand": { "type": "string", "value": "[concat('ssh ', parameters('adminUsername'), '@', ...ipAddress)]" }
}
```
- `reference(...)` is an ARM function that reads a *deployed* resource's runtime properties (here, the public IP's actual assigned address) — only resolvable after the resource exists.
- These four outputs are exactly what `az deployment group create` returns to the pipeline, and what Stage 2's "Output Connection Details" step reads back via `az vm show` to print the SSH command (§2.3).

- `dependsOn` chains: NSG → VNet/Subnet → (Public IP, in parallel) → NIC → VM. If you add a resource, get this ordering right or deployments will fail/race.
- `sourceAddressPrefix: "*"` on the SSH/Jenkins NSG rules is open to the whole internet — fine for `dev`, but should be scoped down before `staging`/`prod` (§5).
- Everything here is **idempotent** — re-running `az deployment group create` with the same parameters won't duplicate resources, it'll just confirm "no changes" (which is what makes the pipeline safe to re-trigger).

---

### 2.3 `azure-pipeline.yml`

**This file is the entry point for everything — the whole deployment is driven by it.** It only provisions infrastructure (the VM + networking); it does **not** install Jenkins, Docker, or anything else on the box. That part is manual (§5).

A few core concepts before the line-by-line, since these matter for anyone editing the file later:

- **Stages → Jobs → Steps** is the hierarchy. Stages run sequentially by default (unless explicitly parallelized); each stage spins up a fresh, clean VM (`vmImage: 'ubuntu-latest'`) to run its jobs on — nothing persists between stages except explicitly-passed variables and the checked-out repo.
- **`task: AzureCLI@2`** is a built-in Azure DevOps task that authenticates the Azure CLI (`az`) using the Service Connection you point it at, then runs your inline bash script already logged in — you never handle credentials yourself in the script.
- **Pipeline variables vs. output variables**: `$(variableName)` reads a normal variable (defined in the `variables:` block, or set as a secret in the UI per §1.4). `##vso[task.setvariable variable=x;isOutput=true]value` is special Azure DevOps log syntax — when a script prints a line in that exact format, the agent parses it and *publishes* a new variable that other stages/jobs can later read. That's how Stage 2 learns which VM SKU Stage 1 picked.

```yaml
trigger:
  branches:
    include: [main]
  paths:
    include: [jenkins-infra/**]
# Pipeline auto-runs only when something inside jenkins-infra/ changes on main.

pr:
  branches:
    include: [main]
# Also runs (Validate stage only is meaningful here) automatically on PRs targeting main,
# so you see the what-if preview before merging.

variables:
  azureServiceConnection: 'azure-service-connection'
  # Must match the Service Connection name you created in §1.2 exactly.
  resourceGroupName: 'rg-jenkins-infra-dev'
  # Resource group the pipeline will create (if missing) and deploy into.
  location: 'eastus2'
  vmName: 'jenkins-vm'
  adminUsername: 'azureuser'
  templateFile:   '$(System.DefaultWorkingDirectory)/jenkins-infra/arm-template/azuredeploy.json'
  parametersFile: '$(System.DefaultWorkingDirectory)/jenkins-infra/Jenkins/azuredeploy.parameters.json'
  # Paths to the two files explained in §2.1 and §2.2, resolved relative to the checked-out repo.
  deploymentName: 'jenkins-vm-deploy-$(Build.BuildId)'
  # Unique deployment name per run, using the built-in Build.BuildId so re-runs don't collide.
```

**Stage 1 — `Validate`**

```yaml
stages:
- stage: Validate
  displayName: '[1/2] Validate'
  # displayName is just the friendly label shown in the Azure DevOps UI — the logical name
  # used for variable references elsewhere is the `stage:` value (Validate).
  jobs:
  - job: ValidateTemplate
    pool:
      vmImage: 'ubuntu-latest'
      # Microsoft-hosted Linux agent — has az CLI preinstalled, billed per pipeline minute.
    steps:
    - checkout: self
      # Clones this repo onto the agent. Without this step, $(System.DefaultWorkingDirectory)
      # would be empty and templateFile/parametersFile paths would resolve to nothing.
    - task: AzureCLI@2
      displayName: 'Validate ARM template'
      env:
        SSH_KEY: $(SSH_PUBLIC_KEY)
        # Pulls in the secret pipeline variable from §1.4 and exposes it to the inline script
        # as a plain shell env var named SSH_KEY (scoped to this task only).
      inputs:
        azureSubscription: '$(azureServiceConnection)'
        # This is the field that actually triggers Azure login — it must match a real Service
        # Connection name (§1.2), not just any string.
        scriptType: 'bash'
        scriptLocation: 'inlineScript'
        failOnStandardError: true
        # If the script writes anything to stderr, the task is marked failed — strict but
        # catches `az` warnings you might otherwise miss in a wall of logs.
        inlineScript: |
          set -euo pipefail
          # -e: exit immediately on any non-zero exit code.
          # -u: treat unset variables as an error instead of silently expanding to "".
          # -o pipefail: a pipeline (cmd1 | cmd2) fails if ANY command in it fails, not just the last.
          # Together: fail loudly and immediately rather than silently continuing on errors.

          if [ -z "${SSH_KEY:-}" ]; then
            echo "##[error] SSH_PUBLIC_KEY pipeline variable is not set or is empty."
            echo "##[error] Go to: Pipeline → Edit → Variables → add SSH_PUBLIC_KEY (secret)."
            exit 1
          fi
          # ${SSH_KEY:-} = "use SSH_KEY if set, otherwise substitute empty string" — this guards
          # against the `set -u` failure above triggering an unhelpful "unbound variable" error,
          # and instead gives a clear, actionable message if you skipped §1.4.
          # "##[error] ..." is Azure DevOps log-formatting syntax — makes the line render red
          # and surface in the pipeline summary, not just buried in plain text output.

          EXISTS=$(az group exists --name $(resourceGroupName))
          if [ "$EXISTS" = "true" ]; then
            echo "[INFO] Resource group '$(resourceGroupName)' already exists — skipping create."
          else
            echo "[INFO] Creating resource group '$(resourceGroupName)' in $(location)..."
            az group create --name $(resourceGroupName) --location $(location) --output none
            echo "[INFO] Resource group created."
          fi
          # az group exists returns the literal string "true"/"false" — this makes the whole
          # pipeline idempotent: first run creates the RG, every run after just confirms it.

          echo "[INFO] Finding available VM SKU in $(location)..."
          SELECTED_SKU=""
          for SKU in Standard_B2s Standard_B2ms Standard_D2s_v3 Standard_D2s_v4 Standard_D2s_v5; do
            AVAIL=$(az vm list-skus \
              --location $(location) \
              --size "$SKU" \
              --query "length([?restrictions[?reasonCode=='NotAvailableForSubscription']] | length(@) == \`0\` && length(@) > \`0\` && @[])" \
              --output tsv 2>/dev/null || echo "0")
            # This --query is a JMESPath expression: it filters az vm list-skus' output down to
            # entries that have NO "NotAvailableForSubscription" restriction, and counts them.
            # A result > 0 means this SKU can actually be provisioned in your subscription/region;
            # `2>/dev/null || echo "0"` swallows any query/API error and treats it as "unavailable"
            # rather than crashing the whole loop.
            if [ "$AVAIL" != "0" ] && [ "$AVAIL" != "" ]; then
              SELECTED_SKU="$SKU"
              echo "[INFO] SKU available: $SKU"
              break
              # Stop at the FIRST available SKU — the list is ordered cheapest/smallest first,
              # so this naturally prefers the cheapest option that's actually in stock.
            else
              echo "[INFO] SKU not available or restricted: $SKU — trying next..."
            fi
          done

          if [ -z "$SELECTED_SKU" ]; then
            echo "[WARN] Could not auto-detect SKU — defaulting to Standard_D2s_v3."
            SELECTED_SKU="Standard_D2s_v3"
          fi
          # Safety net if every SKU in the list came back restricted/quota-blocked — better to
          # attempt a reasonable default and fail at actual deployment time (with a clear Azure
          # error) than to abort the pipeline here.

          echo "[INFO] Selected SKU: $SELECTED_SKU"
          echo "##vso[task.setvariable variable=resolvedVmSize;isOutput=true]$SELECTED_SKU"
          # Publishes resolvedVmSize as an OUTPUT variable of this step. Note isOutput=true —
          # without it, the variable would only be visible within this same job, not to Stage 2.

          echo "[INFO] Running ARM preflight validation..."
          az deployment group validate \
            --resource-group $(resourceGroupName) \
            --template-file $(templateFile) \
            --parameters @$(parametersFile) \
            --parameters sshPublicKey="$SSH_KEY" vmSize="$SELECTED_SKU" \
            --output none
          # `--parameters @file` loads the JSON parameters file; the SECOND --parameters flag
          # passes individual key=value overrides — Azure CLI merges these, with the later/explicit
          # flags winning. This is exactly how SSH_KEY (from the pipeline secret) and the
          # auto-detected SKU override whatever defaults sit in azuredeploy.parameters.json.
          # validate = pure schema/logic check against Azure's API — nothing is created.

          # ── What-if ───────────────────────────────────────────────
          echo "[INFO] Running what-if to preview changes..."
          az deployment group what-if \
            --resource-group $(resourceGroupName) \
            --template-file $(templateFile) \
            --parameters @$(parametersFile) \
            --parameters sshPublicKey="$SSH_KEY" vmSize="$SELECTED_SKU" \
            --output table
          # what-if simulates the deployment against the CURRENT state of the resource group and
          # prints a diff (Create / Modify / Delete / NoChange) in a readable table — this is your
          # last chance to catch unintended changes before Stage 2 actually applies them. Review
          # this output in the PR's pipeline run before merging.
      name: ValidateStep
      # Naming this step "ValidateStep" is what lets Stage 2 reference its output variable via
      # stageDependencies.Validate.ValidateTemplate.outputs['ValidateStep.resolvedVmSize'].
```

**Stage 2 — `Deploy`**

```yaml
- stage: Deploy
  displayName: '[2/2] Deploy'
  dependsOn: Validate
  # Explicit stage dependency — without this, Azure DevOps would run stages in parallel by
  # default once you have more than one, which would be wrong here.
  condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
  # Two-part gate: (1) Validate must have succeeded, AND (2) this run must be on main.
  # This is WHY a PR run only ever exercises Stage 1 — PR branches never satisfy condition (2),
  # so Deploy is skipped entirely (shown as "skipped", not "failed", in the UI).
  variables:
    resolvedVmSize: $[ stageDependencies.Validate.ValidateTemplate.outputs['ValidateStep.resolvedVmSize'] ]
    # Reads the output variable Stage 1 published. The path is:
    # stageDependencies.<stage name>.<job name>.outputs['<step name>.<variable name>']
    # — every link in that chain (Validate / ValidateTemplate / ValidateStep / resolvedVmSize)
    # must match the names used in Stage 1 exactly, or this silently resolves to empty.
  jobs:
  - deployment: DeployVM
    displayName: 'Deploy Infrastructure Only'
    pool:
      vmImage: 'ubuntu-latest'
    environment: 'jenkins-dev'
    # `deployment:` jobs (vs. plain `job:`) are Azure DevOps' construct for tracking deployment
    # history against a named Environment. This gives you a visual deployment timeline per
    # environment and is also where you'd later attach manual-approval checks (e.g. "require
    # sign-off before deploying to jenkins-prod") without touching this YAML.
    strategy:
      runOnce:
        deploy:
          # runOnce is the simplest deployment strategy — just execute the steps once, no
          # canary/rolling logic needed for a single VM.
          steps:
          - checkout: self

          - task: AzureCLI@2
            displayName: 'Provision Azure Resources'
            env:
              SSH_KEY: $(SSH_PUBLIC_KEY)
            inputs:
              azureSubscription: '$(azureServiceConnection)'
              scriptType: 'bash'
              scriptLocation: 'inlineScript'
              failOnStandardError: true
              inlineScript: |
                set -euo pipefail

                VM_SKU="${resolvedVmSize:-Standard_D2s_v3}"
                # Falls back to Standard_D2s_v3 if, for any reason, the Stage 1 output variable
                # didn't come through (e.g. a typo in the stageDependencies path above) — belt
                # and braces so Deploy doesn't crash on an empty SKU string.
                echo "[INFO] Deploying with SKU: $VM_SKU"

                az deployment group create \
                  --name $(deploymentName) \
                  --resource-group $(resourceGroupName) \
                  --template-file $(templateFile) \
                  --parameters @$(parametersFile) \
                  --parameters sshPublicKey="$SSH_KEY" vmSize="$VM_SKU" \
                  --output none
                # The one command in this whole pipeline that actually creates/updates real
                # Azure resources — everything in Stage 1 was read-only. `--name` uses
                # $(deploymentName), which embeds $(Build.BuildId), so every pipeline run leaves
                # its own distinctly-named deployment record in the resource group's Deployments
                # blade (handy for audit/history, and avoids name collisions on re-runs).

                echo "[INFO] ARM deployment complete."

          - task: AzureCLI@2
            displayName: 'Output Connection Details'
            inputs:
              azureSubscription: '$(azureServiceConnection)'
              scriptType: 'bash'
              scriptLocation: 'inlineScript'
              inlineScript: |
                VM_IP=$(az vm show \
                  --resource-group $(resourceGroupName) \
                  --name $(vmName) --show-details \
                  --query publicIps --output tsv)
                # az vm show --show-details makes an extra API call to enrich the response with
                # live network info (public/private IPs, power state) that a bare `az vm show`
                # doesn't include. --query publicIps --output tsv extracts just the IP string,
                # with no JSON quoting/brackets, so it's directly usable in the ssh command below.

                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  Jenkins VM — Deployment Summary"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  Resource Group : $(resourceGroupName)"
                echo "  VM Name        : $(vmName)"
                echo "  Public IP      : $VM_IP"
                echo "  Next Step Command:"
                echo "  ssh $(adminUsername)@$VM_IP"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                # This block exists purely for human readability in the logs — it's what you
                # screenshot/copy from in §3 to get your VM's IP and SSH command. It's a separate
                # task (rather than folded into "Provision Azure Resources") so it still runs and
                # reports the IP even if you re-run just this step, and to keep "did it deploy"
                # and "what's the result" as cleanly separated, individually-retriable steps.
```

> **What the pipeline does *not* do:** install Java, Jenkins, Docker, Git, Maven, configure UFW, or unlock Jenkins. All of that is the manual phase below. The old `jenkins-setup.sh` script automated some of this, but we now run these commands by hand for visibility — keep that file purely as a reference/checklist, not something you execute directly.

---

## 3. Run the pipeline (provisions the VM only)

1. Push/merge your changes to `main`, or open a PR to trigger **Validate** only and review the what-if output.
2. Watch the run in Azure DevOps → Pipelines → `jenkins-infra`.
3. Once **Stage 2: Deploy** finishes, open the **Output Connection Details** step and copy the **Public IP** / SSH command.

At this point you have: a resource group, VNet/subnet, NSG with ports 22/8080/50000 open, a static public IP, and a bare Ubuntu 22.04 VM reachable over SSH. **Nothing Jenkins-related exists yet.** Everything from here is manual.

---

## 4. Manual Server Configuration — Step-by-Step

Once your Azure DevOps pipeline completes successfully, copy the output Public IP from your logs and execute these terminal commands sequentially.

### Step 1: Establish Connection and Update Package Indexes

Open your local computer terminal and open an SSH shell session to enter the VM:

```bash
ssh azureuser@<YOUR_VM_PUBLIC_IP>
```

Once inside the Ubuntu command line, pull down index logs for package definitions and patch security items:

```bash
sudo apt-get update -y && sudo apt-get upgrade -y
```

> You may see a **"Daemons using outdated libraries — which services should be restarted?"** prompt — accept the defaults with `<Ok>` to continue.

### Step 2: Install Java Development Kit 21

Jenkins requires Java to run. Modern versions of Jenkins require Java 21 or Java 25:

```bash
sudo apt-get install -y openjdk-21-jdk
```

Verify the active configuration:

```bash
java -version
```

### Step 3: Register the Stable Jenkins Repositories

Import the modern cryptographically signed public verification key and register the Debian stable download repository route:

```bash
# Clean out stale legacy references if any exist
sudo rm -f /etc/apt/sources.list.d/jenkins.list /usr/share/keyrings/jenkins-keyring.asc

# Import up-to-date signing key entries
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

# Re-add repository definitions securely
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
```

Refresh your local system indexes and deploy the core service application engines:

```bash
sudo apt-get update -y
sudo apt-get install -y jenkins
```

Instruct the operating system to start Jenkins and preserve its execution whenever the underlying server reboots:

```bash
sudo systemctl enable jenkins
sudo systemctl start jenkins
```

### Step 4: Add Build Engine Prerequisites (Git, Maven, and Docker)

Install the essential DevOps dependencies for cloning code, compiling packages, and building containers:

```bash
# Deploy core utility items
sudo apt-get install -y git maven apt-transport-https ca-certificates curl software-properties-common

# Set up the secure Docker package repository keys
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install the Docker runtime engine
sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable docker && sudo systemctl start docker
```

### Step 5: Configure Permissions and Install Command Line Interfaces (CLIs)

Add both the standard user and Jenkins execution processes to the Docker security group so they can run containers without using `sudo`:

```bash
sudo usermod -aG docker jenkins
sudo usermod -aG docker azureuser
```

> Log out and back in (or reboot) after this so the group membership actually takes effect.

Deploy the Azure CLI and the Node.js runtime environments:

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - && sudo apt-get install -y nodejs
```

### Step 6: Configure the Local Firewall (UFW)

Enforce access restrictions on the server's internal firewall:

```bash
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 8080/tcp comment 'Jenkins UI'
sudo ufw allow 50000/tcp comment 'Jenkins Agent'
sudo ufw --force enable
```

### Step 7: Retrieve Unlock Credentials

Print out the temporary initialization password created during setup:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Copy that string, open a web browser to `http://<YOUR_VM_PUBLIC_IP>:8080`, paste the password, select **Install Suggested Plugins**, and create your customized primary master administrator account credentials.

---

## 5. Security Hardening (do this immediately after first login)

1. **Manage Jenkins → Security**
2. Under **Authorization**, select **Matrix-based security**.
3. Find the **Anonymous** row → uncheck everything (blocks unauthenticated access to jobs/builds).
4. **Add user** → your own username → check **Administer** (auto-grants every other permission in that row).
5. **Add user** → each teammate → grant only what they need, e.g. `Overall: Read`, `Job: Build/Cancel/Read`, `View: Read`.
6. **Save**.

### Recommended next-level hardening (flag as follow-up)
- Restrict NSG/UFW source IPs for ports 22 and 8080 to your office/VPN range instead of `*`.
- Move off the built-in Jenkins user database → Azure AD / Entra ID SSO with MFA.
- Enable HTTPS (reverse proxy with Nginx + Let's Encrypt, or Azure Application Gateway) instead of plain `http://` on 8080.

---

## 6. Cost Optimization — Auto-Shutdown

1. Azure Portal → your VM → **Auto-shutdown**.
2. Set **Enabled** to **On**.
3. Scheduled shutdown time: `18:00:00`, Time zone: `(UTC+05:30) India Standard Time`.
4. Turn on notification emails so the team can delay/skip shutdown when working late.

---

## 8. Future Scale Ideas

- **Distributed agents:** offload builds to ephemeral Azure Container Instances (ACI) or secondary agent VMs instead of building on the controller.
- **SSO via Azure AD/Entra ID:** replace manual Jenkins accounts with company identity + MFA.
- **Automated backups:** cron job to snapshot `/var/lib/jenkins/` into an encrypted Azure Storage blob container.

---

- Jenkins official install docs: https://www.jenkins.io/doc/book/installing/linux/
- Jenkins security — Matrix Authorization Strategy: https://www.jenkins.io/doc/book/security/managing-security/
- Azure DevOps service connections: https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints
- Azure ARM template reference: https://learn.microsoft.com/en-us/azure/templates/
- Azure DevOps YAML pipeline schema reference: https://learn.microsoft.com/en-us/azure/devops/pipelines/yaml-schema/
- Azure VM auto-shutdown docs: https://learn.microsoft.com/en-us/azure/virtual-machines/auto-shutdown-vm

---

*Last reviewed: June 2026.*
