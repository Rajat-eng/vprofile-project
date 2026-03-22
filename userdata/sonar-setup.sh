#!/bin/bash
set -e

# -------------------------------
# System tuning (REQUIRED for ES)
# -------------------------------
sudo cp /etc/sysctl.conf /root/sysctl.conf_backup || true

echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=65536" | sudo tee -a /etc/sysctl.conf

# Apply immediately
sudo sysctl -w vm.max_map_count=262144
sudo sysctl -p

# -------------------------------
# Limits (for sonar user)
# -------------------------------
sudo cp /etc/security/limits.conf /root/sec_limit.conf_backup || true

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
sudo apt install -y openjdk-17-jdk wget curl unzip gnupg

java -version

# -------------------------------
# Install PostgreSQL
# -------------------------------
sudo install -d /usr/share/postgresql-common/pgdg

wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
  gpg --dearmor | sudo tee /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg > /dev/null

echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | \
  sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update
sudo apt install -y postgresql postgresql-contrib

sudo systemctl enable postgresql
sudo systemctl start postgresql

# -------------------------------
# Setup database
# -------------------------------
sudo -u postgres psql <<EOF
CREATE USER sonar WITH ENCRYPTED PASSWORD 'admin123';
CREATE DATABASE sonarqube OWNER sonar;
GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonar;
EOF

# -------------------------------
# Install SonarQube
# -------------------------------
cd /tmp
wget https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-9.9.8.100196.zip

sudo unzip -o sonarqube-9.9.8.100196.zip -d /opt/
sudo mv /opt/sonarqube-9.9.8.100196 /opt/sonarqube

# -------------------------------
# Create sonar user
# -------------------------------
if ! id "sonar" &>/dev/null; then
  sudo groupadd sonar
  sudo useradd -c "SonarQube User" -d /opt/sonarqube -g sonar sonar
fi

sudo chown -R sonar:sonar /opt/sonarqube

# -------------------------------
# Configure SonarQube (LOW RAM SAFE)
# -------------------------------
cat <<EOT | sudo tee /opt/sonarqube/conf/sonar.properties
sonar.jdbc.username=sonar
sonar.jdbc.password=admin123
sonar.jdbc.url=jdbc:postgresql://localhost:5432/sonarqube

sonar.web.host=0.0.0.0
sonar.web.port=9000

# 🔥 VERY LOW MEMORY (ES SAFE)
sonar.search.javaOpts=-Xms128m -Xmx128m -XX:+HeapDumpOnOutOfMemoryError
sonar.web.javaOpts=-Xms128m -Xmx128m

sonar.log.level=INFO
EOT

# -------------------------------
# Systemd service (ES optimized)
# -------------------------------
cat <<EOT | sudo tee /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=network.target

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonar
Group=sonar
Restart=always

LimitNOFILE=65536
LimitNPROC=4096
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOT

# -------------------------------
# Clean old Elasticsearch data
# -------------------------------
sudo rm -rf /opt/sonarqube/data/es7

# -------------------------------
# Reload + start
# -------------------------------
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable sonarqube
sudo systemctl start sonarqube

# -------------------------------
# Install Nginx
# -------------------------------
sudo apt install -y nginx

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
sudo systemctl enable nginx
sudo systemctl restart nginx

# -------------------------------
# Final output
# -------------------------------
echo "✅ SonarQube setup complete"
echo "Wait ~1–2 minutes before opening UI"
echo "URL: http://<your-ec2-ip>"
echo "Login: admin / admin"
