#!/bin/bash
set -Eeuo pipefail

PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
BASTION_VM_ZONE="us-central1-a"
PROXY_VM_ZONE="us-central1-a"
BACKEND_VM_ZONE="us-central1-b"
OBSERVABILITY_VM_ZONE="us-central1-a"
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
PROXY_VM_TAG="proxy-vm"
PROXY_FW_NAME="allow-bastion-to-proxy-ssh"

NAT_ROUTER_NAME="nat-router"
NAT_CONFIG_NAME="nat-config"

BACKEND_VM_SA="backend-vm-sa"
BACKEND_VM_NAME="backend-server"
BACKEND_VM_TAG="backend-vm"
BACKEND_FW_SSH_NAME="allow-bastion-to-backend-ssh"
BACKEND_FW_HTTP_NAME="allow-proxy-to-backend-http"

PARENT_FOLDER="building-cloud-servers"

TEMPLATE_NAME="app-template"
MIG_HC_FW="allow-ilb-health-check"
MIG_HC="mig-autoheal-hc"
MIG_NAME="app-mig"
LB_HC="ilb-health-check"
BACKEND_SERVICE_NAME="ilb-backend-service"
LB_IP="ilb-ip"
FD_RULE_NAME="ilb-forwarding-rule"
SN_TO_VMS_FW="allow-traffic-from-mysubnet-backend"

PROXY_TEMPLATE_NAME="proxy-template"
PROXY_MIG_NAME="proxy-mig"

PROXY_MIG_HC="proxy-mig-autoheal-hc"
ELB_HC="elb-health-check"
ELB_BACKEND_SERVICE="elb-backend-service"
ELB_IP="elb-ip"
ELB_URL_MAP="proxy-elb-url-map"
ELB_HTTP_PROXY="proxy-elb-http-proxy"
ELB_FORWARDING_RULE="elb-forwarding-rule"

PROXY_ONLY_SUBNET="proxy-only-subnet"
PROXY_ONLY_SUBNET_RANGE="10.0.3.0/24"

ELB_HC_FW="allow-elb-health-check"
ELB_BACKEND_FW="allow-traffic-from-elb-backend"

OBSERVABILITY_SERVER="observability-server"
OBSERVABILITY_SERVER_TYPE="e2-small"
OBSERVABILITY_SERVER_TAG="observability-server"
OBSERVABILITY_VM_SA="observability-vm-sa"
OBSERVABILITY_VM_SA_EMAIL="observability-vm-sa@${PROJECT_ID}.iam.gserviceaccount.com"

SSH_OB_FW="allow-all-ssh-ob-fw"
NODE_EXPORTER_FW="allow-prometheus-node-exporter-proxy-vm"
LOKI_FW="allow-proxy-vm-to-loki"
GRAFANA_FW="allow-grafana-3000"
BACKEND_VM_LOKI_FW="allow-backend-vm-to-loki"
BACKEND_NODE_EXPORTER_FW="allow-prometheus-node-exporter-backend-vm"

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
        --target-tags=$BASTION_VM_TAG \
        --project="$PROJECT_ID"
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
    --role="roles/iam.serviceAccountUser" >/dev/null

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
    --role="projects/$PROJECT_ID/roles/computeProjectGetter" \
    --condition=None >/dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="group:$GROUP_NAME" \
    --role="roles/serviceusage.serviceUsageViewer" \
    --condition=None >/dev/null


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
    --role="projects/$PROJECT_ID/roles/computeVMAccess" >/dev/null

gcloud compute instances add-iam-policy-binding $BASTION_VM_NAME \
  --zone=$BASTION_VM_ZONE \
  --project="$PROJECT_ID" \
  --member="group:$GROUP_NAME" \
  --role="roles/compute.osAdminLogin" >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="group:$GROUP_NAME" \
  --role="roles/iap.tunnelResourceAccessor" \
  --condition=None >/dev/null

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
    --role="roles/artifactregistry.writer" >/dev/null

gcloud artifacts repositories add-iam-policy-binding $ARTIFACT_REPO \
  --location=$REGION \
  --project=$PROJECT_ID \
  --member="group:$GROUP_NAME" \
  --role="roles/artifactregistry.reader" >/dev/null

gcloud iam service-accounts add-iam-policy-binding \
 "$CLOUD_BUILD_SA@$PROJECT_ID.iam.gserviceaccount.com"  \
 --project="$PROJECT_ID" \
 --member="group:$GROUP_NAME" \
 --role="roles/iam.serviceAccountUser" >/dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="group:$GROUP_NAME" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --condition=None >/dev/null

gcloud storage buckets add-iam-policy-binding \
  gs://${PROJECT_ID}-build-source \
  --member="group:$GROUP_NAME" \
  --role="roles/storage.bucketViewer" >/dev/null

gcloud storage buckets add-iam-policy-binding \
  gs://${PROJECT_ID}-build-source \
  --member="group:$GROUP_NAME" \
  --role="roles/storage.objectCreator" >/dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="group:$GROUP_NAME" \
  --role="roles/cloudbuild.builds.editor" \
  --condition=None >/dev/null

gcloud storage buckets add-iam-policy-binding \
  gs://${PROJECT_ID}-build-source \
  --member="serviceAccount:${CLOUD_BUILD_SA}@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin" >/dev/null

gcloud storage buckets add-iam-policy-binding \
    gs://$PROJECT_ID-build-source \
    --member="group:$GROUP_NAME" \
    --role="roles/storage.objectViewer" >/dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${CLOUD_BUILD_SA}@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/logging.logWriter" \
    --condition=None >/dev/null

echo "======================================="
echo "Build an image and push it into Artifact Registry"
echo "======================================="
gcloud builds submit "$HOME/building-cloud-servers/app/" \
    --project=$PROJECT_ID \
    --region=$REGION \
    --service-account="projects/$PROJECT_ID/serviceAccounts/$CLOUD_BUILD_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --gcs-source-staging-dir=gs://$PROJECT_ID-build-source/source \
    --gcs-log-dir=gs://$PROJECT_ID-build-source/logs \
    --tag=${REGION}-docker.pkg.dev/$PROJECT_ID/${ARTIFACT_REPO}/app:v2



# echo "======================================="
# echo "Create a Proxy VM"
# echo "======================================="
# if ! gcloud compute instances describe $PROXY_VM_NAME \
#     --project=$PROJECT_ID \
#     --zone=$PROXY_VM_ZONE >/dev/null 2>&1; then
#     gcloud compute instances create $PROXY_VM_NAME \
#         --project=$PROJECT_ID \
#         --network=$NETWORK_NAME \
#         --subnet=$SUBNET_NAME \
#         --zone=$PROXY_VM_ZONE \
#         --machine-type=e2-micro \
#         --image-family=ubuntu-2404-lts-amd64 \
#         --image-project=ubuntu-os-cloud \
#         --no-address \
#         --tags=$PROXY_VM_TAG \
#         --metadata=enable-oslogin=TRUE \
#         --scopes=cloud-platform \
#         --service-account=${PROXY_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com
# fi



# echo "======================================="
# echo "Granting permissions to the Bastion VM's service account to allow it to connect to the Proxy VM, Backend VM"
# echo "======================================="

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="projects/$PROJECT_ID/roles/computeProjectGetter" \
    --condition=None >/dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/serviceusage.serviceUsageViewer" \
    --condition=None >/dev/null

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
        --enable-logging \
        --project="$PROJECT_ID"
fi

echo "======================================="
echo "Create a Backend VMs' service account"
echo "======================================="
if ! gcloud iam service-accounts describe $BACKEND_VM_SA@$PROJECT_ID.iam.gserviceaccount.com \
    --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud iam service-accounts create $BACKEND_VM_SA \
        --project=$PROJECT_ID
fi

echo "======================================="
echo "Create an Internal Passthrough Network LB with Managed Instance Group for backend vms"
echo "======================================="
if ! gcloud compute instance-templates describe $TEMPLATE_NAME \
        --project $PROJECT_ID \
        --region=$REGION >/dev/null 2>&1; then
    gcloud compute instance-templates create $TEMPLATE_NAME \
        --project $PROJECT_ID \
        --machine-type=e2-micro \
        --image-family=ubuntu-2404-lts-amd64 \
        --image-project=ubuntu-os-cloud \
        --network=$NETWORK_NAME \
        --subnet=$SUBNET_NAME \
        --region=$REGION \
        --instance-template-region=$REGION \
        --no-address \
        --tags=$BACKEND_VM_TAG \
        --metadata=enable-oslogin=TRUE \
        --metadata-from-file="startup-script=$HOME/$PARENT_FOLDER/cloud/backend-vm-startup.sh" \
        --scopes=cloud-platform \
        --service-account=$BACKEND_VM_SA@$PROJECT_ID.iam.gserviceaccount.com
fi

if ! gcloud compute firewall-rules describe $MIG_HC_FW \
        --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud compute firewall-rules create $MIG_HC_FW \
        --project=$PROJECT_ID \
        --network=$NETWORK_NAME \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:8081 \
        --source-ranges=35.191.0.0/16,130.211.0.0/22 \
        --target-tags=$BACKEND_VM_TAG
fi

if ! gcloud compute health-checks describe $MIG_HC \
        --project=$PROJECT_ID \
        --region=$REGION >/dev/null 2>&1; then
    gcloud compute health-checks create http $MIG_HC \
        --project=$PROJECT_ID \
        --region=$REGION \
        --port=8081 \
        --request-path=/hello \
        --check-interval=30s \
        --timeout=10s \
        --healthy-threshold=1 \
        --unhealthy-threshold=3
fi

if ! gcloud compute instance-groups managed describe $MIG_NAME \
        --project=$PROJECT_ID \
        --region=$REGION >/dev/null 2>&1; then
    gcloud compute instance-groups managed create $MIG_NAME \
        --project=$PROJECT_ID \
        --region=$REGION \
        --zones=us-central1-a,us-central1-b \
        --template=projects/$PROJECT_ID/regions/$REGION/instanceTemplates/$TEMPLATE_NAME \
        --size=2 \
        --health-check=projects/$PROJECT_ID/regions/$REGION/healthChecks/$MIG_HC \
        --initial-delay=600 \
        --action-on-vm-failed-health-check=repair

    gcloud compute instance-groups managed set-autoscaling $MIG_NAME \
        --region=$REGION \
        --min-num-replicas=2 \
        --max-num-replicas=4 \
        --target-cpu-utilization=0.60 \
        --cool-down-period=600
fi


if ! gcloud compute health-checks describe $LB_HC \
        --project="$PROJECT_ID" \
        --region=$REGION >/dev/null 2>&1; then
    gcloud compute health-checks create tcp $LB_HC \
        --project="$PROJECT_ID" \
        --region=$REGION \
        --port=8081
fi

if ! gcloud compute backend-services describe $BACKEND_SERVICE_NAME \
        --project="$PROJECT_ID" \
        --region=$REGION >/dev/null 2>&1; then
    gcloud compute backend-services create $BACKEND_SERVICE_NAME \
        --project="$PROJECT_ID" \
        --region=$REGION \
        --load-balancing-scheme=internal \
        --protocol=TCP \
        --network=$NETWORK_NAME \
        --health-checks=$LB_HC \
        --health-checks-region=$REGION

    gcloud compute backend-services add-backend $BACKEND_SERVICE_NAME \
        --project="$PROJECT_ID" \
        --region=$REGION \
        --instance-group=$MIG_NAME \
        --instance-group-region=$REGION
fi

if ! gcloud compute addresses describe $LB_IP \
        --project="$PROJECT_ID" \
        --region=$REGION >/dev/null 2>&1; then
    gcloud compute addresses create $LB_IP \
        --project="$PROJECT_ID" \
        --region=$REGION \
        --subnet=$SUBNET_NAME \
        --addresses=10.0.1.100
fi

if ! gcloud compute forwarding-rules describe $FD_RULE_NAME \
        --project="$PROJECT_ID" \
        --region=$REGION >/dev/null 2>&1; then
    gcloud compute forwarding-rules create $FD_RULE_NAME \
        --project="$PROJECT_ID" \
        --region=$REGION \
        --load-balancing-scheme=internal \
        --network=$NETWORK_NAME \
        --subnet=$SUBNET_NAME \
        --address=$LB_IP \
        --ip-protocol=TCP \
        --ports=8081 \
        --backend-service=$BACKEND_SERVICE_NAME \
        --backend-service-region=$REGION
fi

echo "======================================="
echo "Create a firewall rule for sending traffic to VMs, it can only work within the vpc network)"
echo "======================================="
if ! gcloud compute firewall-rules describe $SN_TO_VMS_FW \
    --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud compute firewall-rules create $SN_TO_VMS_FW \
        --project=$PROJECT_ID \
        --network=$NETWORK_NAME \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:8081 \
        --source-ranges=10.0.1.0/24 \
        --target-tags=backend-vm
fi

echo "======================================="
echo "Create a firewall rule for Backend vms (bastion connects to backends)"
echo "======================================="
if ! gcloud compute firewall-rules describe $BACKEND_FW_SSH_NAME \
    --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud compute firewall-rules create $BACKEND_FW_SSH_NAME \
        --network=$NETWORK_NAME \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:22 \
        --source-tags=$BASTION_VM_TAG \
        --target-tags=$BACKEND_VM_TAG \
        --project=$PROJECT_ID
fi

echo "======================================="
echo "Granting permissions to the Bastion VM's service account to allow it to connect to the Backend VMs"
echo "======================================="

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="projects/$PROJECT_ID/roles/computeVMAccess" \
  --condition='expression=resource.type == "compute.googleapis.com/Instance" && resource.name.extract("/instances/{name}").startsWith("app-mig-"),title=backend-mig-only,description=Allow Bastion access only to backend MIG instances'

gcloud iam service-accounts add-iam-policy-binding "$BACKEND_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:bastion-vm-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.osAdminLogin" \
  --condition='expression=(resource.type == "compute.googleapis.com/Instance" && resource.name.extract("/instances/{name}").startsWith("app-mig-")),title=backend-mig-only,description=Allow OS Admin Login only to backend MIG instances'

echo "======================================="
echo "Granting permissions to the Backend VMs' service account to allow it to pull images from Artifact Registry"
echo "======================================="
gcloud artifacts repositories add-iam-policy-binding $ARTIFACT_REPO \
    --project=$PROJECT_ID \
    --location=$REGION \
    --member="serviceAccount:${BACKEND_VM_SA}@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/artifactregistry.reader" >/dev/null

echo "======================================="
echo "Create a firewall rule for Backend vms (proxys forward requests to backend vms)"
echo "======================================="
if ! gcloud compute firewall-rules describe $BACKEND_FW_HTTP_NAME \
        --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud compute firewall-rules create $BACKEND_FW_HTTP_NAME \
        --network=$NETWORK_NAME \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:8081 \
        --source-tags=$PROXY_VM_TAG \
        --target-tags=$BACKEND_VM_TAG \
        --project=$PROJECT_ID
fi

echo "======================================="
echo "Create a Proxy VM's service account"
echo "======================================="
if ! gcloud iam service-accounts describe $PROXY_VM_SA@$PROJECT_ID.iam.gserviceaccount.com \
    --project=$PROJECT_ID >/dev/null 2>&1; then
    gcloud iam service-accounts create $PROXY_VM_SA \
        --project=$PROJECT_ID
fi

echo "======================================="
echo "CREATE PROXY INSTANCE TEMPLATE"
echo "======================================="

if ! gcloud compute instance-templates describe $PROXY_TEMPLATE_NAME \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute instance-templates create $PROXY_TEMPLATE_NAME \
        --project="$PROJECT_ID" \
        --machine-type=e2-micro \
        --image-family=ubuntu-2404-lts-amd64 \
        --image-project=ubuntu-os-cloud \
        --network=$NETWORK_NAME \
        --subnet=$SUBNET_NAME \
        --region=$REGION \
        --instance-template-region=$REGION \
        --no-address \
        --tags=$PROXY_VM_TAG \
        --metadata=enable-oslogin=TRUE \
        --metadata-from-file="startup-script=$HOME/$PARENT_FOLDER/cloud/nginx-vm-startup.sh" \
        --scopes=cloud-platform \
        --service-account=$PROXY_VM_SA@$PROJECT_ID.iam.gserviceaccount.com
fi

echo "======================================="
echo "CREATE FIREWALL RULE FOR ELB HEALTH CHECKS"
echo "======================================="

if ! gcloud compute firewall-rules describe $ELB_HC_FW \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    gcloud compute firewall-rules create $ELB_HC_FW \
        --project="$PROJECT_ID" \
        --network=$NETWORK_NAME \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:80 \
        --source-ranges=35.191.0.0/16,130.211.0.0/22 \
        --target-tags=$PROXY_VM_TAG
fi

echo "======================================="
echo "CREATE PROXY MIG AUTOHEAL HEALTH CHECK"
echo "======================================="

if ! gcloud compute health-checks describe $PROXY_MIG_HC \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute health-checks create http $PROXY_MIG_HC \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --port=80 \
        --request-path=/ \
        --check-interval=30s \
        --timeout=10s \
        --healthy-threshold=1 \
        --unhealthy-threshold=3
fi

echo "======================================="
echo "CREATE PROXY MANAGED INSTANCE GROUP"
echo "======================================="

if ! gcloud compute instance-groups managed describe $PROXY_MIG_NAME \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute instance-groups managed create $PROXY_MIG_NAME \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --zones=us-central1-a,us-central1-b \
        --template=projects/$PROJECT_ID/regions/$REGION/instanceTemplates/$PROXY_TEMPLATE_NAME \
        --size=2 \
        --health-check=projects/$PROJECT_ID/regions/$REGION/healthChecks/$PROXY_MIG_HC \
        --initial-delay=150 \
        --action-on-vm-failed-health-check=repair
fi

echo "======================================="
echo "CONFIGURE PROXY MIG NAMED PORTS"
echo "======================================="

gcloud compute instance-groups managed set-named-ports $PROXY_MIG_NAME \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --named-ports=khanh:80

echo "======================================="
echo "CONFIGURE PROXY MIG AUTOSCALING"
echo "======================================="

gcloud compute instance-groups managed set-autoscaling $PROXY_MIG_NAME \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --min-num-replicas=2 \
    --max-num-replicas=4 \
    --target-cpu-utilization=0.60 \
    --cool-down-period=150

echo "======================================="
echo "CREATE EXTERNAL APPLICATION LOAD BALANCER HEALTH CHECK"
echo "======================================="

if ! gcloud compute health-checks describe $ELB_HC \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute health-checks create http $ELB_HC \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --port=80 \
        --request-path=/ \
        --check-interval=5s \
        --timeout=5s \
        --healthy-threshold=2 \
        --unhealthy-threshold=2
fi

echo "======================================="
echo "CREATE EXTERNAL MANAGED BACKEND SERVICE"
echo "======================================="

if ! gcloud compute backend-services describe $ELB_BACKEND_SERVICE \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute backend-services create $ELB_BACKEND_SERVICE \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --load-balancing-scheme=EXTERNAL_MANAGED \
        --protocol=HTTP \
        --port-name=khanh \
        --health-checks=$ELB_HC \
        --health-checks-region="$REGION"

    gcloud compute backend-services add-backend $ELB_BACKEND_SERVICE \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --instance-group=$PROXY_MIG_NAME \
        --instance-group-region="$REGION"
fi

echo "======================================="
echo "CREATE EXTERNAL LOAD BALANCER IP"
echo "======================================="

if ! gcloud compute addresses describe $ELB_IP \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute addresses create $ELB_IP \
        --project="$PROJECT_ID" \
        --region="$REGION"
fi

echo "======================================="
echo "CREATE URL MAP"
echo "======================================="

if ! gcloud compute url-maps describe $ELB_URL_MAP \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute url-maps create $ELB_URL_MAP \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --default-service=$ELB_BACKEND_SERVICE
fi

echo "======================================="
echo "CREATE REGIONAL TARGET HTTP PROXY"
echo "======================================="

if ! gcloud compute target-http-proxies describe $ELB_HTTP_PROXY \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute target-http-proxies create $ELB_HTTP_PROXY \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --url-map=$ELB_URL_MAP
fi

echo "======================================="
echo "CREATE REGIONAL MANAGED PROXY SUBNET"
echo "======================================="

if ! gcloud compute networks subnets describe $PROXY_ONLY_SUBNET \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute networks subnets create $PROXY_ONLY_SUBNET \
        --project="$PROJECT_ID" \
        --network=$NETWORK_NAME \
        --region="$REGION" \
        --range=$PROXY_ONLY_SUBNET_RANGE \
        --purpose=REGIONAL_MANAGED_PROXY \
        --role=ACTIVE
fi

echo "======================================="
echo "CREATE EXTERNAL MANAGED FORWARDING RULE"
echo "======================================="

if ! gcloud compute forwarding-rules describe $ELB_FORWARDING_RULE \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    gcloud compute forwarding-rules create $ELB_FORWARDING_RULE \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --network=$NETWORK_NAME \
        --load-balancing-scheme=EXTERNAL_MANAGED \
        --address=$ELB_IP \
        --target-http-proxy=$ELB_HTTP_PROXY \
        --target-http-proxy-region="$REGION" \
        --ports=80
fi

echo "======================================="
echo "ALLOW TRAFFIC FROM REGIONAL MANAGED PROXY SUBNET"
echo "======================================="

GG_MANAGED_PROXY_IP_RANGE=$(gcloud compute networks subnets describe $PROXY_ONLY_SUBNET \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --format="get(ipCidrRange)")

if ! gcloud compute firewall-rules describe $ELB_BACKEND_FW \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    gcloud compute firewall-rules create $ELB_BACKEND_FW \
        --project="$PROJECT_ID" \
        --network=$NETWORK_NAME \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:80 \
        --source-ranges=$GG_MANAGED_PROXY_IP_RANGE \
        --target-tags=$PROXY_VM_TAG
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
echo "Granting permissions to the Bastion VM's service account to allow it to connect to the Proxy VMs"
echo "======================================="

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="projects/$PROJECT_ID/roles/computeVMAccess" \
  --condition='expression=resource.type == "compute.googleapis.com/Instance" && resource.name.extract("/instances/{name}").startsWith("proxy-mig-"),title=proxy-mig-only,description=Allow Bastion access only to proxy MIG instances'

gcloud iam service-accounts add-iam-policy-binding "$PROXY_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:$BASTION_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:bastion-vm-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.osAdminLogin" \
  --condition='expression=(resource.type == "compute.googleapis.com/Instance" && resource.name.extract("/instances/{name}").startsWith("proxy-mig-")),title=proxy-mig-only,description=Allow OS Admin Login only to proxy MIG instances'


echo "======================================="
echo "Create an observability vm"
echo "======================================="
if gcloud iam service-accounts describe "$OBSERVABILITY_VM_SA_EMAIL" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Observability service account already exists. Skipping."

else

  gcloud iam service-accounts create "$OBSERVABILITY_VM_SA" \
    --project="$PROJECT_ID" \
    --display-name="Observability Server Service Account"

fi

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$OBSERVABILITY_VM_SA_EMAIL" \
  --role="roles/compute.viewer" \
  --condition=None


if gcloud compute instances describe "$OBSERVABILITY_SERVER" \
  --project="$PROJECT_ID" \
  --zone="$OBSERVABILITY_VM_ZONE" >/dev/null 2>&1; then

  echo "Observability VM already exists. Skipping."

else

  gcloud compute instances create "$OBSERVABILITY_SERVER" \
    --project="$PROJECT_ID" \
    --zone="$OBSERVABILITY_VM_ZONE" \
    --machine-type="$OBSERVABILITY_SERVER_TYPE" \
    --network="$NETWORK_NAME" \
    --subnet="$SUBNET_NAME" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --scopes=cloud-platform \
    --tags="$OBSERVABILITY_SERVER_TAG" \
    --service-account="$OBSERVABILITY_VM_SA_EMAIL" \
    --metadata-from-file="startup-script=$HOME/$PARENT_FOLDER/cloud/observability-vm-startup.sh"

fi

# Allow nginx-vm and backend-vm startup scripts to get internal ip of observability-server 
gcloud compute instances add-iam-policy-binding $OBSERVABILITY_SERVER \
  --zone=$OBSERVABILITY_VM_ZONE \
  --project=$PROJECT_ID \
  --member="serviceAccount:$PROXY_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.viewer"

  gcloud compute instances add-iam-policy-binding $OBSERVABILITY_SERVER \
  --zone=$OBSERVABILITY_VM_ZONE \
  --project=$PROJECT_ID \
  --member="serviceAccount:$BACKEND_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.viewer"

# Support MIG Discovery
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$OBSERVABILITY_VM_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="projects/$PROJECT_ID/roles/computeVMAccess" \
  --condition=None

if gcloud compute firewall-rules describe "$SSH_OB_FW" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Firewall rule $SSH_OB_FW already exists. Skipping."

else

  gcloud compute firewall-rules create "$SSH_OB_FW" \
    --project="$PROJECT_ID" \
    --network="$NETWORK_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=0.0.0.0/0 \
    --target-tags="$OBSERVABILITY_SERVER_TAG"

fi


echo "======================================="
echo "Configuring some firewall rules to allow Prometheus, Loki to communicate each other for Observability vm and proxy, backend vms"
echo "======================================="
if gcloud compute firewall-rules describe "$NODE_EXPORTER_FW" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Firewall rule $NODE_EXPORTER_FW already exists. Skipping."

else

  gcloud compute firewall-rules create "$NODE_EXPORTER_FW" \
    --project="$PROJECT_ID" \
    --network="$NETWORK_NAME" \
    --allow=tcp:9100 \
    --source-tags="$OBSERVABILITY_SERVER_TAG" \
    --target-tags="$PROXY_VM_TAG"

fi

if gcloud compute firewall-rules describe "$LOKI_FW" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Firewall rule $LOKI_FW already exists. Skipping."

else

  gcloud compute firewall-rules create "$LOKI_FW" \
    --project="$PROJECT_ID" \
    --network="$NETWORK_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:3100 \
    --source-tags="$PROXY_VM_TAG" \
    --target-tags="$OBSERVABILITY_SERVER_TAG" \
    --description="Allow proxy VM to push logs to Loki"

fi


if gcloud compute firewall-rules describe "$GRAFANA_FW" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Firewall rule $GRAFANA_FW already exists. Skipping."

else

  gcloud compute firewall-rules create "$GRAFANA_FW" \
    --project="$PROJECT_ID" \
    --network="$NETWORK_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:3000 \
    --source-ranges=0.0.0.0/0 \
    --target-tags="$OBSERVABILITY_SERVER_TAG" \
    --description="Allow Grafana access"

fi


if gcloud compute firewall-rules describe "$BACKEND_NODE_EXPORTER_FW" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Firewall rule $BACKEND_NODE_EXPORTER_FW already exists. Skipping."

else

  gcloud compute firewall-rules create "$BACKEND_NODE_EXPORTER_FW" \
    --project="$PROJECT_ID" \
    --network="$NETWORK_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:9100 \
    --source-tags="$OBSERVABILITY_SERVER_TAG" \
    --target-tags="$BACKEND_VM_TAG" \
    --description="Allow Prometheus on Observability VM to scrape Backend Node Exporter"

fi

if gcloud compute firewall-rules describe "$BACKEND_VM_LOKI_FW" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Firewall rule $BACKEND_VM_LOKI_FW already exists. Skipping."

else

  gcloud compute firewall-rules create "$BACKEND_VM_LOKI_FW" \
    --project="$PROJECT_ID" \
    --network="$NETWORK_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:3100 \
    --source-tags="$BACKEND_VM_TAG" \
    --target-tags="$OBSERVABILITY_SERVER_TAG" \
    --description="Allow backend VM to push logs to Loki"

fi







echo "======================================="
echo "Done"
echo "======================================="