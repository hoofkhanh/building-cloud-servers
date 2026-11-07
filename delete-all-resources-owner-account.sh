#!/bin/bash
set -e

PROJECT_ID="building-servers"
REGION="us-central1"

echo "=================================="
echo "Cleaning up billable resources"
echo "=================================="

# 1. Delete Cloud NAT
echo "Deleting Cloud NAT..."

gcloud compute routers nats delete nat-config \
    --router=nat-router \
    --router-region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet || true

# 2. Delete Cloud Router
echo "Deleting Cloud Router..."

gcloud compute routers delete nat-router \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet || true

# 3. Delete Bastion VM and attached disks
echo "Deleting Bastion VM..."

gcloud compute instances delete bastion-server \
    --zone=us-central1-a \
    --project="$PROJECT_ID" \
    --delete-disks=all \
    --quiet || true

# 4. Delete Proxy VM and attached disks
echo "Deleting Proxy VM..."

gcloud compute instances delete proxy-server \
    --zone=us-central1-a \
    --project="$PROJECT_ID" \
    --delete-disks=all \
    --quiet || true

# 5. Delete Backend VM (if it exists)
echo "Deleting Backend VM..."

gcloud compute instances delete backend-1-server \
    --zone=us-central1-b \
    --project="$PROJECT_ID" \
    --delete-disks=all \
    --quiet || true

# 6. Delete Artifact Registry repository
echo "Deleting Artifact Registry..."

gcloud artifacts repositories delete my-repo \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --quiet || true

# 7. Delete Cloud Build source bucket
echo "Deleting Cloud Storage bucket..."

gcloud storage rm --recursive \
    "gs://${PROJECT_ID}-build-source" || true

echo "=================================="
echo "Cleanup commands completed!"
echo "=================================="