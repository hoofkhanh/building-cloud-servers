# Installing Docker
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo systemctl enable --now docker

# Configuring a Docker compose file including Prometheus, Grafana, Loki
sudo mkdir -p /opt/observability/prometheus
cd /opt/observability/prometheus

# Prometheus configuration
sudo tee prometheus.yml > /dev/null <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090
  - job_name: 'proxy-mig'
    gce_sd_configs:
      - project: building-servers
        zone: us-central1-a
        port: 9100

      - project: building-servers
        zone: us-central1-b
        port: 9100

    relabel_configs:
      - source_labels: [__meta_gce_metadata_created_by]
        regex: '.*/instanceGroupManagers/proxy-mig'
        action: keep

      - source_labels: [__meta_gce_instance_name]
        target_label: instance

  - job_name: 'app-mig'
    gce_sd_configs:
      - project: building-servers
        zone: us-central1-a
        port: 9100

      - project: building-servers
        zone: us-central1-b
        port: 9100

    relabel_configs:
      - source_labels: [__meta_gce_metadata_created_by]
        regex: '.*/instanceGroupManagers/app-mig'
        action: keep

      - source_labels: [__meta_gce_instance_name]
        target_label: instance

  - job_name: 'nginx-exporter'
    gce_sd_configs:
      - project: building-servers
        zone: us-central1-a
        port: 9113

      - project: building-servers
        zone: us-central1-b
        port: 9113

    relabel_configs:
      - source_labels: [__meta_gce_metadata_created_by]
        regex: '.*/instanceGroupManagers/proxy-mig'
        action: keep

      - source_labels: [__meta_gce_instance_name]
        target_label: instance
    
  - job_name: 'container-metrics'
    gce_sd_configs:
      - project: building-servers
        zone: us-central1-a
        port: 8080

      - project: building-servers
        zone: us-central1-b
        port: 8080

    relabel_configs:
      - source_labels: [__meta_gce_metadata_created_by]
        regex: '.*/instanceGroupManagers/app-mig'
        action: keep

      - source_labels: [__meta_gce_instance_name]
        target_label: instance
EOF

# Docker compose configuration
cd ..

sudo tee compose.yml > /dev/null <<'EOF'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
    depends_on:
      - prometheus
    restart: unless-stopped

  loki:
    image: grafana/loki:3.7.0
    container_name: loki
    user: "0:0"
    ports:
      - "3100:3100"
    volumes:
      - ./loki/loki-config.yaml:/etc/loki/loki-config.yaml:ro
      - loki-data:/tmp/loki
    command:
      - '-config.file=/etc/loki/loki-config.yaml'
    restart: unless-stopped

volumes:
  prometheus-data:
  grafana-data:
  loki-data:
EOF

# Loki configuration
sudo mkdir -p /opt/observability/loki
cd /opt/observability/loki

sudo tee loki-config.yaml > /dev/null <<'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info
  grpc_server_max_concurrent_streams: 1000

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules

schema_config:
  configs:
    - from: "2024-01-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  filesystem:
    directory: /loki/chunks

  tsdb_shipper:
    active_index_directory: /loki/tsdb-index
    cache_location: /loki/tsdb-cache

limits_config:
  retention_period: 168h
  allow_structured_metadata: true

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem

analytics:
  reporting_enabled: false
EOF

cd .. && sudo docker compose up -d