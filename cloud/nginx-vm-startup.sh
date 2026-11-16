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
