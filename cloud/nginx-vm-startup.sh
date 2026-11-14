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

sudo tee /etc/nginx/sites-available/my-site