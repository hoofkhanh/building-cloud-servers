# Installing Nginx proxy
sudo apt update
sudo apt install nginx -y
sudo systemctl enable --now nginx

# Create root page for Nginx app
sudo mkdir -p /var/www/my-site

VM_NAME=$(curl -s -H "Metadata-Flavor: Google" \
http://metadata.google.internal/computeMetadata/v1/instance/name)

sudo tee /var/www/my-site/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Hello VM</title>
</head>
<body>
    <h1>Hello, Khanh!</h1>
    <p>VM NAME: $VM_NAME</p>
</body>
</html>
EOF

sudo chown -R www-data:www-data /var/www/my-site/index.html

sudo tee /etc/nginx/sites-available/my-site <<'EOF'
upstream backend_servers {
    server 10.0.1.100:8081;
}
server {
    listen 80;
    listen [::]:80;

    server_name _;

    # Serve static pages
    root /var/www/my-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    # Forward API requests to Backend 1
    location /api/ {
        proxy_pass http://backend_servers/;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
   
        add_header X-Backend-Server $upstream_addr always;
    }
}
EOF

sudo rm /etc/nginx/sites-enabled/default >/dev/null 2>&1

sudo ln -s /etc/nginx/sites-available/my-site /etc/nginx/sites-enabled/my-site

sudo nginx -t
sudo systemctl reload nginx

# Configuring Prometheus metrics and Loki logs
# Create a dedicated user for node exporter metric
sudo useradd \
  --no-create-home \
  --shell /usr/sbin/nologin \
  node_exporter

# Download and Configure Node Exporter
cd /tmp
VERSION="1.9.1"
wget https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz
tar xvf node_exporter-${VERSION}.linux-amd64.tar.gz
sudo cp node_exporter-${VERSION}.linux-amd64/node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter

# Configuring Grafana Alloy
sudo mkdir -p /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
sudo chmod 644 /etc/apt/keyrings/grafana.asc
echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update
sudo apt-get install alloy

until OBSERVABILITY_INTERNAL_IP=$(gcloud compute instances describe observability-server \
  --zone=us-central1-a \
  --format="get(networkInterfaces[0].networkIP)" 2>/dev/null) && [[ -n "$OBSERVABILITY_INTERNAL_IP" ]]; do
    echo "Waiting for observability-server internal IP..."
    sleep 5
done

echo "Observability internal IP: $OBSERVABILITY_INTERNAL_IP"

sudo tee /etc/alloy/config.alloy > /dev/null <<EOF
// Discover Linux log files
local.file_match "vm_logs" {
  path_targets = [
    {
      "__path__" = "/var/log/syslog",
      "job"      = "linux",
      "host"     = constants.hostname,
      "log_type" = "syslog",
    },
    {
      "__path__" = "/var/log/auth.log",
      "job"      = "linux",
      "host"     = constants.hostname,
      "log_type" = "auth",
    },
  ]
}

local.file_match "nginx_logs" {
  path_targets = [
    {
      "__path__" = "/var/log/nginx/access.log",
      "job"      = "nginx",
      "log_type" = "access",
      "host"     = constants.hostname,
    },
    {
      "__path__" = "/var/log/nginx/error.log",
      "job"      = "nginx",
      "log_type" = "error",
      "host"     = constants.hostname,
    },
  ]
}

// Read log files and forward them to Loki
loki.source.file "vm_logs" {
  targets    = local.file_match.vm_logs.targets
  forward_to = [loki.write.loki.receiver]
}

loki.source.file "nginx_logs" {
  targets    = local.file_match.nginx_logs.targets
  forward_to = [loki.write.loki.receiver]
}

loki.source.journal "nginx_logs" {
  forward_to = [loki.write.loki.receiver]

  labels = {
    job      = "nginx",
    log_type = "journal",
    host     = constants.hostname,
  }
}

loki.write "loki" {
  endpoint {
    url = "http://${OBSERVABILITY_INTERNAL_IP}:3100/loki/api/v1/push"
  }
}
EOF


sudo alloy validate /etc/alloy/config.alloy
sudo systemctl start alloy

# Configuring Nginx Prometheus Exporter
sudo tee /etc/nginx/conf.d/monitoring.conf > /dev/null <<EOF
server {
    listen 127.0.0.1:8080;
    server_name localhost;

    location /stub_status {
        stub_status;
    }
}
EOF

sudo systemctl reload nginx

sudo useradd \
  --no-create-home \
  --shell /usr/sbin/nologin \
  nginx-exporter

cd /tmp
wget https://github.com/nginx/nginx-prometheus-exporter/releases/download/v1.5.3/nginx-prometheus-exporter_1.5.3_linux_amd64.tar.gz
tar -xvf nginx-prometheus-exporter_1.5.3_linux_amd64.tar.gz
sudo mv nginx-prometheus-exporter /usr/local/bin/
sudo chown nginx-exporter:nginx-exporter /usr/local/bin/nginx-prometheus-exporter

sudo tee /etc/systemd/system/nginx-exporter.service > /dev/null <<EOF
[Unit]
Description=NGINX Prometheus Exporter
After=network.target nginx.service

[Service]
User=nginx-exporter
Group=nginx-exporter

ExecStart=/usr/local/bin/nginx-prometheus-exporter \
    --nginx.scrape-uri=http://127.0.0.1:8080/stub_status \
    --web.listen-address=0.0.0.0:9113

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl start nginx-exporter