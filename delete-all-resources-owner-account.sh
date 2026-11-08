
#!/bin/bash
set -Eeuo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION="us-central1"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "No GCP project selected."
    exit 1
fi

echo "Deleting billable resources in: $PROJECT_ID"

read -r -p "Type DELETE to continue: " CONFIRM
[[ "$CONFIRM" == "DELETE" ]] || exit 1

# Delete Compute Engine VMs
for ITEM in \
    "bastion-server:us-central1-a" \
    "proxy-server:us-central1-a" \
    "backend-1-server:us-central1-b" \
    "backend-2-server:us-central1-a"
do
    VM="${ITEM%%:*}"
    ZONE="${ITEM##*:}"

    gcloud compute instances delete "$VM" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --quiet || true
done

# Delete Cloud NAT
gcloud compute routers nats delete nat-config \
    --router=nat-router \
    --router-region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet || true

gcloud compute routers delete nat-router \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet || true

# Delete Artifact Registry
gcloud artifacts repositories delete my-repo \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --quiet || true

# Delete Cloud Storage bucket and contents
gcloud storage rm --recursive \
    "gs://${PROJECT_ID}-build-source" \
    --quiet || true

echo "Cleanup completed."
