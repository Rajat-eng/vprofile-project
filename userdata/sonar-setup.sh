#!/bin/bash
set -e

# -------------------------------
# System tuning (Elasticsearch)
# -------------------------------
sudo sysctl -w vm.max_map_count=524288
echo "vm.max_map_count=524288" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=65536" | sudo tee -a /etc/sysctl.conf

# -------------------------------
# Limits
# -------------------------------
cat <<EOT | sudo tee -a /etc/security/limits.conf
sonar soft nofile 65536
sonar hard nofile 65536
sonar soft nproc 4096
sonar hard nproc 4096
EOT

# -------------------------------
# Install dependencies
# -------------------------------
sudo apt update -y
sudo apt install -y openjdk-21-jdk wget curl unzip gnupg nginx

java -version

# -------------------------------
# Install PostgreSQL
# -------------------------------
sudo apt install -y postgresql postgresql-contrib
sudo systemctl enable postgresql
sudo systemctl start postgresql

# -------------------------------
# Setup DB
# -------------------------------
sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS sonarqube;
DROP USER IF EXISTS sonar;
CREATE USER sonar WITH ENCRYPTED PASSWORD 'admin123';
CREATE DATABASE sonarqube OWNER sonar;
GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonar;
EOF

# -------------------------------
# Download SonarQube (FIXED URL)
# -------------------------------
cd /tmp

wget --header="User-Agent: Mozilla/5.0" \
https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-26.3.0.120487.zip \
-O sonarqube.zip

# -------------------------------
# Extract properly
# -------------------------------
sudo unzip -o sonarqube.zip -d /opt/
SONAR_DIR=$(ls /opt | grep sonarqube-26 | head -n 1)

sudo mv /opt/$SONAR_DIR /opt/sonarqube

# -------------------------------
# Create user
# -------------------------------
if ! id "sonar" &>/dev/null; then
  sudo groupadd sonar
  sudo useradd -c "SonarQube User" -d /opt/sonarqube -g sonar sonar
fi

sudo chown -R sonar:sonar /opt/sonarqube

# -------------------------------
# Configure SonarQube
# -------------------------------
cat <<EOT | sudo tee /opt/sonarqube/conf/sonar.properties
sonar.jdbc.username=sonar
sonar.jdbc.password=admin123
sonar.jdbc.url=jdbc:postgresql://localhost:5432/sonarqube

sonar.web.host=0.0.0.0
sonar.web.port=9000

# Balanced memory for 4GB EC2
sonar.search.javaOpts=-Xms512m -Xmx512m
sonar.web.javaOpts=-Xms512m -Xmx512m

sonar.log.level=INFO
EOT

# -------------------------------
# Systemd service
# -------------------------------
cat <<EOT | sudo tee /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=network.target postgresql.service

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonar
Group=sonar
Restart=always
RestartSec=10

LimitNOFILE=65536
LimitNPROC=4096
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOT

# -------------------------------
# Clean ES old state
# -------------------------------
sudo rm -rf /opt/sonarqube/data
sudo mkdir -p /opt/sonarqube/data
sudo chown -R sonar:sonar /opt/sonarqube

# -------------------------------
# Enable & start services
# -------------------------------
sudo systemctl daemon-reload
sudo systemctl enable sonarqube postgresql nginx

sudo systemctl start sonarqube
sudo systemctl start nginx

# -------------------------------
# Configure Nginx
# -------------------------------
sudo rm -f /etc/nginx/sites-enabled/default

cat <<EOT | sudo tee /etc/nginx/sites-available/sonarqube
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT

sudo ln -sf /etc/nginx/sites-available/sonarqube /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# -------------------------------
# Final output
# -------------------------------
echo "==================================="
echo "✅ SonarQube Setup Complete"
echo "Wait ~2 minutes for startup"
echo "URL: http://<your-ec2-ip>"
echo "Login: admin / admin"
echo "==================================="
