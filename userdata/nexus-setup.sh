#!/bin/bash
set -e

NEXUS_VERSION="3.90.1-01"
NEXUS_DIR="nexus-$NEXUS_VERSION"
DOWNLOAD_URL="https://download.sonatype.com/nexus/3/nexus-$NEXUS_VERSION-linux-x86_64.tar.gz"

# -------------------------------
# Install Java 17
# -------------------------------
sudo yum update -y
sudo yum install -y java-17-amazon-corretto-devel wget

# -------------------------------
# Download Nexus
# -------------------------------
cd /tmp
wget -O nexus.tar.gz $DOWNLOAD_URL

# -------------------------------
# Clean old install (safe reset)
# -------------------------------
sudo rm -rf /opt/nexus*
sudo rm -rf /opt/sonatype-work

# -------------------------------
# Extract properly
# -------------------------------
sudo tar -xzf nexus.tar.gz -C /opt
sudo mv /opt/$NEXUS_DIR /opt/nexus

# -------------------------------
# Create nexus user
# -------------------------------
if ! id "nexus" &>/dev/null; then
  sudo useradd -r -m -d /opt/sonatype-work -s /bin/bash nexus
fi

# -------------------------------
# Setup directories
# -------------------------------
sudo mkdir -p /opt/sonatype-work/nexus3
sudo chown -R nexus:nexus /opt/nexus /opt/sonatype-work

# -------------------------------
# Configure Nexus
# -------------------------------
echo 'run_as_user="nexus"' | sudo tee /opt/nexus/bin/nexus.rc

echo "nexus-work=/opt/sonatype-work/nexus3" | sudo tee /opt/nexus/etc/nexus-default.properties

# -------------------------------
# 🔥 Memory Fix (CRITICAL)
# -------------------------------
sudo sed -i 's/^-Xms.*/-Xms512m/' /opt/nexus/bin/nexus.vmoptions
sudo sed -i 's/^-Xmx.*/-Xmx512m/' /opt/nexus/bin/nexus.vmoptions
sudo sed -i 's/^-XX:MaxDirectMemorySize=.*/-XX:MaxDirectMemorySize=512m/' /opt/nexus/bin/nexus.vmoptions

# -------------------------------
# Systemd service
# -------------------------------
sudo tee /etc/systemd/system/nexus.service <<EOT
[Unit]
Description=Nexus Repository Manager
After=network.target

[Service]
Type=forking
User=nexus
Group=nexus
LimitNOFILE=65536
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
Restart=on-failure
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOT

# -------------------------------
# Start Nexus
# -------------------------------
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable nexus
sudo systemctl start nexus

# -------------------------------
# Output
# -------------------------------
echo "✅ Nexus $NEXUS_VERSION installed!"
echo "UI: http://$(curl -s ifconfig.me):8081"
echo "Password: sudo cat /opt/sonatype-work/nexus3/admin.password"
