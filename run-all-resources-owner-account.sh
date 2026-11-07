#!/bin/bash
set -Eeuo pipefail

PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
BASTION_VM_ZONE="us-central1-a"
PROXY_VM_ZONE="us-central1-a"
GROUP_NAME="hoofkhanh-devops-engineers@googlegroups.com"

NETWORK_NAME="my-vpc"
SUBNET_NAME="my-subnet"

BASTION_FW_NAME="allow-iap-ssh"
BASTION_VM_TAG="bastion-vm"
BASTION_VM_SA="bastion-vm-sa"
BASTION_VM_NAME="bastion-server"

ARTIFACT_REPO="my-repo"
APP_IMAGE_NAME="app"
APP_IMAGE_VERSION="v1"
CLOUD_BUILD_SA="cloud-build-runner"

PROXY_VM_SA="proxy-vm-sa"
PROXY_VM_NAME="proxy-server"
PROXY_VM_TAG="proxy-vm"
PROXY_FW_NAME="allow-bastion-to-proxy-ssh"

NAT_ROUTER_NAME="nat-router"
NAT_CONFIG_NAME="nat-config"

gcloud services enable \
  compute.googleapis.com \
  iam.googleapis.com \
  serviceusage.googleapis.com \
  iap.googleapis.com \
  networkmanagement.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=$PROJECT_ID

echo "======================================="
echo "CREATE VPC"
echo "======================================="
if ! gcloud compute networks describe $NETWORK_NAME \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute networks create $NETWORK_NAME \
        --subnet-mode=custom \
        --project="${PROJECT_ID}"
fi

echo "======================================="
echo "CREATE SUBNET"
echo "======================================="
if ! gcloud compute networks subnets describe $SUBNET_NAME \
    --project="${PROJECT_ID}" \
    --region="$REGION" > /dev/null 2>&1; then
    gcloud compute networks subnets create $SUBNET_NAME \
        --project="${PROJECT_ID}" \
        --network="$NETWORK_NAME" \
        --region="$REGION" \
        --range=10.0.1.0/24
fi

echo "======================================="
echo "CREATE Firewall Rule for Bastion VM"
echo "======================================="

if ! gcloud compute firewall-rules describe $BASTION_FW_NAME \
    --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud compute firewall-rules create $BASTION_FW_NAME \
        --network=$NETWORK_NAME \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:22 \
        --source-ranges=35.235.240.0/20 \
        --target-tags=$BASTION_VM_TAG
fi

echo "======================================="
echo "CREATE Service Account for Bastion VM"
echo "======================================="
if ! gcloud iam service-accounts describe ${BASTION_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com \
    --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud iam service-accounts create $BASTION_VM_SA \
        --display-name="Bastion VM SA" \
        --description="Service Account for Bastion VM" \
        --project=$PROJECT_ID
fi

echo "======================================="
echo "Grant the group the Service Account role"
echo "======================================="
gcloud iam service-accounts add-iam-policy-binding \
    "${BASTION_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project="$PROJECT_ID" \
    --member="group:${GROUP_NAME}" \
    --role="roles/iam.serviceAccountUser" >/dev/null 2>&1

echo "======================================="
echo "Create Bastion VM"
echo "======================================="
if ! gcloud compute instances describe $BASTION_VM_NAME \
    --project="$PROJECT_ID" \
    --zone=$BASTION_VM_ZONE >/dev/null 2>&1; then
    gcloud compute instances create $BASTION_VM_NAME \
        --project=$PROJECT_ID \
        --network=$NETWORK_NAME \
        --subnet=$SUBNET_NAME \
        --zone=$BASTION_VM_ZONE \
        --machine-type=e2-micro \
        --image-family=ubuntu-2404-lts-amd64 \
        --image-project=ubuntu-os-cloud \
        --no-address \
        --tags=$BASTION_VM_TAG \
        --metadata=enable-oslogin=TRUE \
        --scopes=cloud-platform \
        --service-account="$BASTION_VM_SA"@"$PROJECT_ID".iam.gserviceaccount.com
fi

echo "======================================="
echo "Grant the group a bunch of roles (predefine, customized) needed to access bastion vm using SSH"
echo "======================================="
if ! gcloud iam roles describe computeProjectGetter \
    --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud iam roles create computeProjectGetter \
        --project=$PROJECT_ID \
        --title="Compute Project Getter" \
        --description="Allows reading Compute Engine project information" \
        --permissions="compute.projects.get,compute.instances.list,compute.globalOperations.get,compute.zoneOperations.get,resourcemanager.projects.get" \
        --stage=GA
fi

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="group:$GROUP_NAME" \
    --role="projects/$PROJECT_ID/roles/computeProjectGetter" >/dev/null 2>&1

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="group:$GROUP_NAME" \
    --role="roles/serviceusage.serviceUsageViewer"


if ! gcloud iam roles describe computeVMAccess \
    --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud iam roles create computeVMAccess \
        --project="$PROJECT_ID" \
        --title="Compute VM Access " \
        --description="Provides access to specifically authorized Compute Engine VMs" \
        --permissions="compute.instances.get,compute.instances.use,compute.instances.getEffectiveFirewalls,compute.instances.getSerialPortOutput" \
        --stage=GA
fi

gcloud compute instances add-iam-policy-binding $BASTION_VM_NAME \
    --zone=$BASTION_VM_ZONE \
    --project="$PROJECT_ID" \
    --member="group:$GROUP_NAME" \
    --role="projects/$PROJECT_ID/roles/computeVMAccess" >/dev/null 2>&1

gcloud compute instances add-iam-policy-binding $BASTION_VM_NAME \
  --zone=$BASTION_VM_ZONE \
  --project="$PROJECT_ID" \
  --member="group:$GROUP_NAME" \
  --role="roles/compute.osAdminLogin" >/dev/null 2>&1

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="group:$GROUP_NAME" \
  --role="roles/iap.tunnelResourceAccessor" >/dev/null 2>&1

echo "======================================="
echo "Create Artifact Repository, Cloud Storage, Cloud Build SA and grant some permissions to it"
echo "======================================="
if ! gcloud artifacts repositories describe  $ARTIFACT_REPO \
    --location=$REGION \
    --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud artifacts repositories create $ARTIFACT_REPO \
        --repository-format=docker \
        --location=$REGION \
        --project="$PROJECT_ID"
fi

if ! gcloud iam service-accounts describe \
    $CLOUD_BUILD_SA@$PROJECT_ID.iam.gserviceaccount.com >/dev/null 2>&1; then
    gcloud iam service-accounts create $CLOUD_BUILD_SA \
        --project=$PROJECT_ID
fi

if ! gcloud storage buckets describe gs://$PROJECT_ID-build-source \
    --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud storage buckets create gs://$PROJECT_ID-build-source \
        --project=$PROJECT_ID \
        --location=$REGION \
        --uniform-bucket-level-access
fi

gcloud artifacts repositories add-iam-policy-binding $ARTIFACT_REPO \
    --project=$PROJECT_ID \
    --location=$REGION \
    --member="serviceAccount:$CLOUD_BUILD_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/artifactregistry.writer" >/dev/null 2>&1

gcloud artifacts repositories add-iam-policy-binding $ARTIFACT_REPO \
  --location=$REGION \
  --project=$PROJECT_ID \
  --member="group:$GROUP_NAME" \
  --role="roles/artifactregistry.reader" >/dev/null 2>&1

gcloud iam service-accounts add-iam-policy-binding \
 "$CLOUD_BUILD_SA@$PROJECT_ID.iam.gserviceaccount.com"  \
 --project="$PROJECT_ID" \
 --member="group:$GROUP_NAME" \
 --role="roles/iam.serviceAccountUser" >/dev/null 2>&1

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="group:$GROUP_NAME" \
  --role="roles/serviceusage.serviceUsageConsumer" >/dev/null 2>&1

gcloud storage buckets add-iam-policy-binding \
  gs://${PROJECT_ID}-build-source \
  --member="group:$GROUP_NAME" \
  --role="roles/storage.bucketViewer" >/dev/null 2>&1

gcloud storage buckets add-iam-policy-binding \
  gs://${PROJECT_ID}-build-source \
  --member="group:$GROUP_NAME" \
  --role="roles/storage.objectCreator" >/dev/null 2>&1

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="group:$GROUP_NAME" \
  --role="roles/cloudbuild.builds.editor" >/dev/null 2>&1

gcloud storage buckets add-iam-policy-binding \
  gs://${PROJECT_ID}-build-source \
  --member="serviceAccount:${CLOUD_BUILD_SA}@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin" >/dev/null 2>&1

gcloud storage buckets add-iam-policy-binding \
    gs://$PROJECT_ID-build-source \
    --member="group:$GROUP_NAME" \
    --role="roles/storage.objectViewer" >/dev/null 2>&1

echo "======================================="
echo "Create a Proxy VM's service account"
echo "======================================="
if ! gcloud iam service-accounts describe $PROXY_VM_SA@$PROJECT_ID.iam.gserviceaccount.com \
    --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud iam service-accounts create $PROXY_VM_SA \
        --project=$PROJECT_ID
fi

echo "======================================="
echo "Create a Proxy VM"
echo "======================================="
if ! gcloud compute instances describe $PROXY_VM_NAME \
    --project=$PROJECT_ID \
    --zone=$PROXY_VM_ZONE >/dev/null 2>&1; then
    gcloud compute instances create $PROXY_VM_NAME \
        --project=$PROJECT_ID \
        --network=$NETWORK_NAME \
        --subnet=$SUBNET_NAME \
        --zone=$PROXY_VM_ZONE \
        --machine-type=e2-micro \
        --image-family=ubuntu-2404-lts-amd64 \
        --image-project=ubuntu-os-cloud \
        --no-address \
        --tags=$PROXY_VM_TAG \
        --metadata=enable-oslogin=TRUE \
        --scopes=cloud-platform \
        --service-account=${PROXY_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com
fi

echo "======================================="
echo "Create a firewall rule for proxy vm"
echo "======================================="

if ! gcloud compute firewall-rules describe $PROXY_FW_NAME \
    --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud compute firewall-rules create $PROXY_FW_NAME \
        --network=$NETWORK_NAME \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:22 \
        --source-tags=$BASTION_VM_TAG \
        --target-tags=$PROXY_VM_TAG \
        --project=$PROJECT_ID
fi

echo "======================================="
echo "Granting permissions to the Bastion VM's service account to allow it to connect to the Proxy VM"
echo "======================================="

gcloud projects add-iam-policy-binding $PROJECT_ID \
--member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
--role="projects/$PROJECT_ID/roles/computeProjectGetter" >/dev/null 2>&1

gcloud projects add-iam-policy-binding $PROJECT_ID \
--member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
--role="roles/serviceusage.serviceUsageViewer" >/dev/null 2>&1

gcloud compute instances add-iam-policy-binding $PROXY_VM_NAME \
  --zone=$PROXY_VM_ZONE \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="projects/$PROJECT_ID/roles/computeVMAccess" >/dev/null 2>&1

gcloud iam service-accounts add-iam-policy-binding "$PROXY_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
--project="$PROJECT_ID" \
--member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
--role="roles/iam.serviceAccountUser" >/dev/null 2>&1

gcloud compute instances add-iam-policy-binding $PROXY_VM_NAME \
  --zone=$PROXY_VM_ZONE \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.osAdminLogin"

echo "======================================="
echo "Enable Private Google Access, allowing VMs without external IP addresses to access Google Cloud APIs privately without requiring Cloud NAT. This allows the VM to call compute.googleapis.com."
echo "======================================="
gcloud compute networks subnets update $SUBNET_NAME \
  --project="$PROJECT_ID" \
  --region=$REGION \
  --enable-private-ip-google-access >/dev/null 2>&1

echo "======================================="
echo "Creating Cloud NAT to allow outbound traffics, because Proxy Server needs to access the internet for nginx installiation"
echo "======================================="

if ! gcloud compute routers describe $NAT_ROUTER_NAME \
    --project="$PROJECT_ID" \
    --region=$REGION >/dev/null 2>&1; then
    gcloud compute routers create $NAT_ROUTER_NAME \
        --network=$NETWORK_NAME \
        --region=$REGION \
        --project="$PROJECT_ID"
fi

if ! gcloud compute routers nats describe $NAT_CONFIG_NAME \
    --router=$NAT_ROUTER_NAME \
    --router-region=$REGION \
    --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud compute routers nats create $NAT_CONFIG_NAME \
        --router=$NAT_ROUTER_NAME \
        --router-region=$REGION \
        --nat-custom-subnet-ip-ranges=$SUBNET_NAME \
        --auto-allocate-nat-external-ips \
        --enable-logging
fi

echo "======================================="
echo "Done"
echo "======================================="
# This is intended for employee accounts
# echo "======================================="
# echo "Build an image from app and push it to Artifact Repository"
# echo "======================================="
# gcloud builds submit $HOME/building-servers/app/ \
#     --project=$PROJECT_ID \
#     --region=$REGION \
#     --service-account="projects/$PROJECT_ID/serviceAccounts/$CLOUD_BUILD_SA@$PROJECT_ID.iam.gserviceaccount.com" \
#     --gcs-source-staging-dir=gs://$PROJECT_ID-build-source/source \
#     --gcs-log-dir=gs://$PROJECT_ID-build-source/logs \
#     --tag=${REGION}-docker.pkg.dev/$PROJECT_ID/${ARTIFACT_REPO}/${APP_IMAGE_NAME}:${APP_IMAGE_VERSION}