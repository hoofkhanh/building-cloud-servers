# Installing Docker
sudo apt update
sudo apt install docker.io -y
sudo systemctl enable --now docker

# Configuring Authentication for pulling images from Artifact Registry
sudo -H gcloud auth configure-docker us-central1-docker.pkg.dev -y
sudo docker pull us-central1-docker.pkg.dev/building-servers/my-repo/app:v1

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
    us-central1-docker.pkg.dev/building-servers/my-repo/app:v1

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

sudo sysctl --system

sudo apt install -y iptables-persistent
sudo netfilter-persistent save
