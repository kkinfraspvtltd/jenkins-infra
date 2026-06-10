# Run this on the VM AFTER the ARM template deploys Jenkins
# Usage: bash jenkins-setup.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}========================================${NC}"; }

# 1. System Update 
header "Step 1: System Update"
sudo apt-get update -y
sudo apt-get upgrade -y
log "System updated."

# 2. Install Java 17 
header "Step 2: Java 17"
if java -version 2>&1 | grep -q "17"; then
  log "Java 17 already installed."
else
  sudo apt-get install -y openjdk-17-jdk
fi
java -version
log "Java installed: $(java -version 2>&1 | head -1)"

# 3. Install Jenkins 
header "Step 3: Jenkins"
if systemctl is-active --quiet jenkins; then
  log "Jenkins already running."
else
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
    https://pkg.jenkins.io/debian-stable binary/" \
    | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y jenkins
  sudo systemctl enable jenkins
  sudo systemctl start jenkins
  log "Jenkins installed and started."
fi

# 4. Install Git, Maven, Docker 
header "Step 4: Dev Tools (Git, Maven, Docker)"

# Git
sudo apt-get install -y git
log "Git: $(git --version)"

# Maven
sudo apt-get install -y maven
log "Maven: $(mvn -version | head -1)"

# Docker
if ! command -v docker &> /dev/null; then
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
  sudo systemctl enable docker
  sudo systemctl start docker
  sudo usermod -aG docker jenkins
  sudo usermod -aG docker azureuser
  log "Docker installed."
else
  log "Docker already installed: $(docker --version)"
fi

# 5. Install Azure CLI
header "Step 5: Azure CLI"
if ! command -v az &> /dev/null; then
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  log "Azure CLI installed: $(az version --query '\"azure-cli\"' -o tsv)"
else
  log "Azure CLI already installed: $(az version --query '\"azure-cli\"' -o tsv)"
fi

# 6. Install Node.js (for pipeline tools)
header "Step 6: Node.js 18 LTS"
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
  sudo apt-get install -y nodejs
  log "Node.js: $(node --version)"
else
  log "Node.js already installed: $(node --version)"
fi

# 7. Firewall Rules
header "Step 7: Firewall (UFW)"
sudo ufw --force enable
sudo ufw allow 22/tcp    comment 'SSH'
sudo ufw allow 8080/tcp  comment 'Jenkins UI'
sudo ufw allow 50000/tcp comment 'Jenkins Agent'
sudo ufw status verbose
log "Firewall rules applied."

# 8. Jenkins CLI Setup
header "Step 8: Jenkins CLI"
log "Waiting for Jenkins to fully start..."
sleep 30

JENKINS_URL="http://localhost:8080"
for i in {1..20}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" $JENKINS_URL || true)
  if [ "$STATUS" = "200" ] || [ "$STATUS" = "403" ]; then
    log "Jenkins is UP (HTTP $STATUS)"
    break
  fi
  echo "  Waiting... attempt $i/20"
  sleep 10
done

# Download Jenkins CLI jar
wget -q $JENKINS_URL/jnlpJars/jenkins-cli.jar -O /home/azureuser/jenkins-cli.jar 2>/dev/null || \
  log "Jenkins CLI will be available once Jenkins is fully configured."

# 9. Summary
header "✅ Setup Complete"

VM_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
INIT_PASSWORD=$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "Run: sudo cat /var/lib/jenkins/secrets/initialAdminPassword")

echo ""
echo "=============================================="
echo "  Jenkins Server Setup Summary"
echo "=============================================="
echo "  VM IP Address  : $VM_IP"
echo "  Jenkins URL    : http://$VM_IP:8080"
echo "  SSH Access     : ssh azureuser@$VM_IP"
echo ""
echo "  Initial Admin Password:"
echo "  $INIT_PASSWORD"
echo ""
echo "  Java Version   : $(java -version 2>&1 | head -1)"
echo "  Git Version    : $(git --version)"
echo "  Maven Version  : $(mvn -version 2>&1 | head -1)"
echo "  Docker Version : $(docker --version)"
echo "  Azure CLI      : $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null)"
echo "=============================================="
echo ""
echo "📌 Next Steps:"
echo "  1. Open http://$VM_IP:8080 in your browser"
echo "  2. Enter the Initial Admin Password above"
echo "  3. Install Suggested Plugins"
echo "  4. Create your Admin User"
echo "  5. Install extra plugins (see SETUP-GUIDE.md)"
echo "=============================================="