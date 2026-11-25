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

// Discover Docker containers
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

// Collect Docker container logs through Docker API
loki.source.docker "docker_logs" {
  host    = "unix:///var/run/docker.sock"
  targets = discovery.docker.containers.targets

  labels = {
    job      = "docker",
    host     = constants.hostname,
    log_type = "container",
  }

  forward_to = [loki.write.loki.receiver]
}


loki.write "loki" {
  endpoint {
    url = "http://${OBSERVABILITY_INTERNAL_IP}:3100/loki/api/v1/push"
  }
}
EOF

sudo usermod -aG alloydocker 
sudo systemctl restart alloy

sudo alloy validate /etc/alloy/config.alloy
sudo systemctl start alloy