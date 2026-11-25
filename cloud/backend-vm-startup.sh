# Installing Docker
sudo apt update
sudo apt install docker.io -y
sudo systemctl enable --now docker

# Configuring Authentication for pulling images from Artifact Registry
sudo -H gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
sudo docker pull us-central1-docker.pkg.dev/building-servers/my-repo/app:v2

# Configuring Docker apps
sudo docker network create \
    --driver bridge \
    --subnet 172.18.0.0/16 \
    app-network

sudo docker run -d \
    --name postgres \
    --network app-network \
    --ip 172.18.0.8 \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=taskdb \
    --health-cmd="pg_isready -U postgres -d taskdb" \
    --health-interval=5s \
    --health-timeout=3s \
    --health-retries=10 \
    postgres:16

until [ "$(sudo docker inspect -f '{{.State.Health.Status}}' postgres)" = "healthy" ]; do
    echo "Waiting for PostgreSQL..."
    sleep 2
done

sudo docker run -d \
    --name app \
    --network app-network \
    --ip 172.18.0.4 \
    -p 8081:8080 \
    us-central1-docker.pkg.dev/building-servers/my-repo/app:v2

# Configuring firewalls using iptables to restrict only the allowed containers can access the postgres' container
APP_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' app)
DB_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' postgres)


sudo iptables -A DOCKER-USER \
    -s "$APP_IP" -d "$DB_IP" \
    -p tcp --dport 5432 -j ACCEPT

sudo iptables -A DOCKER-USER \
    -d "$DB_IP" \
    -p tcp --dport 5432 -j DROP

sudo modprobe br_netfilter

# Saving these run-time firewall rules permanently
echo br_netfilter | sudo tee /etc/modules-load.d/br_netfilter.conf

echo 'net.bridge.bridge-nf-call-iptables = 1' | sudo tee /etc/sysctl.d/99-br-netfilter.conf
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-ip-forward.conf

sudo sysctl --system

sudo DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
sudo netfilter-persistent save

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

// Read log files and forward them to Loki
loki.source.file "vm_logs" {
  targets    = local.file_match.vm_logs.targets
  forward_to = [loki.write.loki.receiver]
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

sudo usermod -aG docker alloy
sudo systemctl restart alloy

sudo alloy validate /etc/alloy/config.alloy
sudo systemctl start alloy