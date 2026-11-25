
#!/bin/bash
set -Eeuo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION="us-central1"

# =========================================================
# ZONES
# =========================================================

BASTION_VM_ZONE="us-central1-a"
PROXY_VM_ZONE="us-central1-a"
BACKEND_VM_ZONE="us-central1-b"
OBSERVABILITY_VM_ZONE="us-central1-a"

GROUP_NAME="hoofkhanh-devops-engineers@googlegroups.com"

# =========================================================
# NETWORK
# =========================================================

NETWORK_NAME="my-vpc"
SUBNET_NAME="my-subnet"
PROXY_ONLY_SUBNET="proxy-only-subnet"

# =========================================================
# BASTION VM
# =========================================================

BASTION_VM_NAME="bastion-server"
BASTION_VM_SA="bastion-vm-sa"
BASTION_VM_TAG="bastion-vm"
BASTION_FW_NAME="allow-iap-ssh"

# =========================================================
# PROXY VM / MIG
# =========================================================

PROXY_VM_SA="proxy-vm-sa"
PROXY_VM_TAG="proxy-vm"
PROXY_FW_NAME="allow-bastion-to-proxy-ssh"

PROXY_TEMPLATE_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/instanceTemplates/proxy-template"

PROXY_MIG_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/instanceGroupManagers/proxy-mig"

PROXY_MIG_HC="proxy-mig-autoheal-hc"

# =========================================================
# BACKEND VM / MIG
# =========================================================

BACKEND_VM_SA="backend-vm-sa"
BACKEND_VM_TAG="backend-vm"
BACKEND_FW_SSH_NAME="allow-bastion-to-backend-ssh"
BACKEND_FW_HTTP_NAME="allow-proxy-to-backend-http"

TEMPLATE_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/global/instanceTemplates/app-template"

MIG_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/instanceGroupManagers/app-mig"

MIG_HC="mig-autoheal-hc"
MIG_HC_FW="allow-ilb-health-check"
SN_TO_VMS_FW="allow-traffic-from-mysubnet-backend"

# =========================================================
# INTERNAL LOAD BALANCER - FULL RESOURCE URLS
# =========================================================

LB_HC_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/healthChecks/ilb-health-check"

BACKEND_SERVICE_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/backendServices/ilb-backend-service"

LB_IP_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/addresses/ilb-ip"

FD_RULE_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/forwardingRules/ilb-forwarding-rule"

# =========================================================
# EXTERNAL LOAD BALANCER - FULL RESOURCE URLS
# =========================================================

ELB_HC_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/healthChecks/elb-health-check"

ELB_BACKEND_SERVICE_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/backendServices/elb-backend-service"

ELB_IP_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/addresses/elb-ip"

ELB_URL_MAP_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/urlMaps/proxy-elb-url-map"

ELB_HTTP_PROXY_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/targetHttpProxies/proxy-elb-http-proxy"

ELB_FORWARDING_RULE_URL="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/forwardingRules/elb-forwarding-rule"

ELB_HC_FW="allow-elb-health-check"
ELB_BACKEND_FW="allow-traffic-from-elb-backend"

# =========================================================
# OBSERVABILITY
# =========================================================

OBSERVABILITY_SERVER="observability-server"
OBSERVABILITY_VM_SA="observability-vm-sa"
OBSERVABILITY_VM_TAG="observability-server"

SSH_OB_FW="allow-all-ssh-ob-fw"
NODE_EXPORTER_FW="allow-prometheus-node-exporter-proxy-vm"
LOKI_FW="allow-proxy-vm-to-loki"
GRAFANA_FW="allow-grafana-3000"
BACKEND_VM_LOKI_FW="allow-backend-vm-to-loki"
BACKEND_NODE_EXPORTER_FW="allow-prometheus-node-exporter-backend-vm"

# =========================================================
# CLOUD BUILD / ARTIFACT REGISTRY
# =========================================================

CLOUD_BUILD_SA="cloud-build-runner"
ARTIFACT_REPO="my-repo"
BUILD_BUCKET="${PROJECT_ID}-build-source"

# =========================================================
# CLOUD NAT
# =========================================================

NAT_ROUTER_NAME="nat-router"
NAT_CONFIG_NAME="nat-config"

# =========================================================
# CLEANUP TRACKING
# =========================================================

FAILED=()

echo "======================================="
echo "PROJECT: ${PROJECT_ID}"
echo "REGION: ${REGION}"
echo "======================================="

# Extract resource name from a full resource URL.
resource_name() {
    printf '%s\n' "${1##*/}"
}

# Run a command and record failures without stopping the script.
run_cleanup() {
    echo
    printf '>>>'
    printf ' %q' "$@"
    echo

    if "$@"; then
        echo "SUCCESS"
    else
        echo "FAILED"
        FAILED+=("$*")
    fi
}

# =========================================================
# 1. STOP MIG AUTOSCALING
# =========================================================

stop_mig_autoscaling() {
    local mig_url="$1"
    local mig_name
    mig_name="$(resource_name "$mig_url")"

    echo
    echo "Checking MIG: ${mig_url}"

    if gcloud compute instance-groups managed describe "$mig_name" \
        --region="$REGION" \
        --project="$PROJECT_ID" >/dev/null 2>&1; then

        run_cleanup gcloud compute instance-groups managed stop-autoscaling "$mig_name" \
            --region="$REGION" \
            --project="$PROJECT_ID"
    else
        echo "SKIP: MIG ${mig_url} does not exist."
    fi
}

echo "======================================="
echo "1. STOP MIG AUTOSCALING"
echo "======================================="

stop_mig_autoscaling "$PROXY_MIG_URL"
stop_mig_autoscaling "$MIG_URL"

# =========================================================
# 2. DELETE EXTERNAL LOAD BALANCER
# =========================================================

echo "======================================="
echo "2. DELETE EXTERNAL LOAD BALANCER"
echo "======================================="

run_cleanup gcloud compute forwarding-rules delete \
    "$(resource_name "$ELB_FORWARDING_RULE_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute target-http-proxies delete \
    "$(resource_name "$ELB_HTTP_PROXY_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute url-maps delete \
    "$(resource_name "$ELB_URL_MAP_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute backend-services delete \
    "$(resource_name "$ELB_BACKEND_SERVICE_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute addresses delete \
    "$(resource_name "$ELB_IP_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

# =========================================================
# 3. DELETE INTERNAL LOAD BALANCER
# =========================================================

echo "======================================="
echo "3. DELETE INTERNAL LOAD BALANCER"
echo "======================================="

run_cleanup gcloud compute forwarding-rules delete \
    "$(resource_name "$FD_RULE_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute backend-services delete \
    "$(resource_name "$BACKEND_SERVICE_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute addresses delete \
    "$(resource_name "$LB_IP_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

# =========================================================
# 4. DELETE MANAGED INSTANCE GROUPS
# =========================================================

echo "======================================="
echo "4. DELETE MANAGED INSTANCE GROUPS"
echo "======================================="

run_cleanup gcloud compute instance-groups managed delete \
    "$(resource_name "$PROXY_MIG_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute instance-groups managed delete \
    "$(resource_name "$MIG_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

# =========================================================
# 5. DELETE INSTANCE TEMPLATES
# =========================================================

echo "======================================="
echo "5. DELETE INSTANCE TEMPLATES"
echo "======================================="

run_cleanup gcloud compute instance-templates delete \
    "$(resource_name "$PROXY_TEMPLATE_URL")" \
    --region="$REGION" \
    --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute instance-templates delete \
    "$(resource_name "$TEMPLATE_URL")" \
    --region="$REGION" \
    --project="$PROJECT_ID" --quiet

# =========================================================
# 6. DELETE HEALTH CHECKS
# =========================================================

echo "======================================="
echo "6. DELETE HEALTH CHECKS"
echo "======================================="

run_cleanup gcloud compute health-checks delete \
    "$(resource_name "$ELB_HC_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute health-checks delete \
    "$(resource_name "$LB_HC_URL")" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute health-checks delete "$PROXY_MIG_HC" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute health-checks delete "$MIG_HC" \
    --region="$REGION" --project="$PROJECT_ID" --quiet

# =========================================================
# 7. DELETE STANDALONE VMs
# =========================================================

echo "======================================="
echo "7. DELETE STANDALONE VMs"
echo "======================================="

run_cleanup gcloud compute instances remove-iam-policy-binding "$OBSERVABILITY_SERVER" \
  --zone="$OBSERVABILITY_VM_ZONE" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${PROXY_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/compute.viewer"

run_cleanup gcloud compute instances remove-iam-policy-binding "$OBSERVABILITY_SERVER" \
  --zone="$OBSERVABILITY_VM_ZONE" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${BACKEND_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/compute.viewer"
  
run_cleanup gcloud compute instances delete "$OBSERVABILITY_SERVER" \
    --zone="$OBSERVABILITY_VM_ZONE" \
    --project="$PROJECT_ID" --quiet

run_cleanup gcloud compute instances delete "$BASTION_VM_NAME" \
    --zone="$BASTION_VM_ZONE" \
    --project="$PROJECT_ID" --quiet

# =========================================================
# 8. DELETE FIREWALL RULES
# =========================================================

echo "======================================="
echo "8. DELETE FIREWALL RULES"
echo "======================================="

FIREWALL_RULES=(
    "$BASTION_FW_NAME"
    "$PROXY_FW_NAME"
    "$BACKEND_FW_SSH_NAME"
    "$BACKEND_FW_HTTP_NAME"
    "$MIG_HC_FW"
    "$SN_TO_VMS_FW"
    "$ELB_HC_FW"
    "$ELB_BACKEND_FW"
    "$SSH_OB_FW"
    "$NODE_EXPORTER_FW"
    "$LOKI_FW"
    "$GRAFANA_FW"
    "$BACKEND_NODE_EXPORTER_FW"
    "$BACKEND_VM_LOKI_FW"
)

for FW in "${FIREWALL_RULES[@]}"; do
    if gcloud compute firewall-rules describe "$FW" \
        --project="$PROJECT_ID" >/dev/null 2>&1; then

        run_cleanup gcloud compute firewall-rules delete "$FW" \
            --project="$PROJECT_ID" --quiet
    else
        echo "SKIP: Firewall rule $FW does not exist."
    fi
done

# =========================================================
# 9. DELETE CLOUD NAT AND ROUTER
# =========================================================

echo "======================================="
echo "9. DELETE CLOUD NAT AND ROUTER"
echo "======================================="

if gcloud compute routers nats describe "$NAT_CONFIG_NAME" \
    --router="$NAT_ROUTER_NAME" \
    --router-region="$REGION" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    run_cleanup gcloud compute routers nats delete "$NAT_CONFIG_NAME" \
        --router="$NAT_ROUTER_NAME" \
        --router-region="$REGION" \
        --project="$PROJECT_ID" --quiet
else
    echo "SKIP: NAT configuration does not exist."
fi

if gcloud compute routers describe "$NAT_ROUTER_NAME" \
    --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then

    run_cleanup gcloud compute routers delete "$NAT_ROUTER_NAME" \
        --region="$REGION" --project="$PROJECT_ID" --quiet
else
    echo "SKIP: Cloud Router does not exist."
fi

# =========================================================
# 10. DELETE SUBNETS AND VPC
# =========================================================

echo "======================================="
echo "10. DELETE SUBNETS AND VPC"
echo "======================================="

for SUBNET in "$PROXY_ONLY_SUBNET" "$SUBNET_NAME"; do
    if gcloud compute networks subnets describe "$SUBNET" \
        --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then

        run_cleanup gcloud compute networks subnets delete "$SUBNET" \
            --region="$REGION" --project="$PROJECT_ID" --quiet
    else
        echo "SKIP: Subnet $SUBNET does not exist."
    fi
done

if gcloud compute networks describe "$NETWORK_NAME" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    run_cleanup gcloud compute networks delete "$NETWORK_NAME" \
        --project="$PROJECT_ID" --quiet
else
    echo "SKIP: VPC $NETWORK_NAME does not exist."
fi

# =========================================================
# 11. DELETE CLOUD STORAGE BUCKET
# =========================================================

echo "======================================="
echo "11. DELETE CLOUD STORAGE BUCKET"
echo "======================================="

if gcloud storage buckets describe "gs://${BUILD_BUCKET}" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    run_cleanup gcloud storage rm --recursive "gs://${BUILD_BUCKET}" \
        --project="$PROJECT_ID"

else
    echo "SKIP: Build bucket does not exist."
fi

# =========================================================
# 12. DELETE ARTIFACT REGISTRY
# =========================================================

echo "======================================="
echo "12. DELETE ARTIFACT REGISTRY"
echo "======================================="

if gcloud artifacts repositories describe "$ARTIFACT_REPO" \
    --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then

    run_cleanup gcloud artifacts repositories delete "$ARTIFACT_REPO" \
        --location="$REGION" --project="$PROJECT_ID" --quiet
else
    echo "SKIP: Artifact Registry repository does not exist."
fi

# =========================================================
# 13. REMOVE PROJECT IAM BINDINGS
# =========================================================

echo "======================================="
echo "13. REMOVE PROJECT IAM BINDINGS"
echo "======================================="

# Group bindings
run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="group:$GROUP_NAME" \
    --role="projects/$PROJECT_ID/roles/computeProjectGetter" \
    --condition=None

run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="group:$GROUP_NAME" \
    --role="roles/serviceusage.serviceUsageViewer" \
    --condition=None

run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="group:$GROUP_NAME" \
    --role="roles/iap.tunnelResourceAccessor" \
    --condition=None

run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="group:$GROUP_NAME" \
    --role="roles/serviceusage.serviceUsageConsumer" \
    --condition=None

run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="group:$GROUP_NAME" \
    --role="roles/cloudbuild.builds.editor" \
    --condition=None

# Bastion service account bindings
run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${BASTION_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="projects/$PROJECT_ID/roles/computeProjectGetter" \
    --condition=None

run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${BASTION_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/serviceusage.serviceUsageViewer" \
    --condition=None

# Observability service account binding
run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${OBSERVABILITY_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/compute.viewer" \
    --condition=None

# Cloud Build service account binding
run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${CLOUD_BUILD_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/logging.logWriter" \
    --condition=None

# =========================================================
# 14. REMOVE CONDITIONAL IAM BINDINGS
# =========================================================

echo "======================================="
echo "14. REMOVE CONDITIONAL IAM BINDINGS"
echo "======================================="

BASTION_SA_MEMBER="serviceAccount:${BASTION_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

# Backend MIG access
run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="$BASTION_SA_MEMBER" \
    --role="projects/$PROJECT_ID/roles/computeVMAccess" \
    --condition='expression=resource.type == "compute.googleapis.com/Instance" && resource.name.extract("/instances/{name}").startsWith("app-mig-"),title=backend-mig-only,description=Allow Bastion access only to backend MIG instances'

run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="$BASTION_SA_MEMBER" \
    --role="roles/compute.osAdminLogin" \
    --condition='expression=(resource.type == "compute.googleapis.com/Instance" && resource.name.extract("/instances/{name}").startsWith("app-mig-")),title=backend-mig-only,description=Allow OS Admin Login only to backend MIG instances'

# Proxy MIG access
run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="$BASTION_SA_MEMBER" \
    --role="projects/$PROJECT_ID/roles/computeVMAccess" \
    --condition='expression=resource.type == "compute.googleapis.com/Instance" && resource.name.extract("/instances/{name}").startsWith("proxy-mig-"),title=proxy-mig-only,description=Allow Bastion access only to proxy MIG instances'

run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="$BASTION_SA_MEMBER" \
    --role="roles/compute.osAdminLogin" \
    --condition='expression=(resource.type == "compute.googleapis.com/Instance" && resource.name.extract("/instances/{name}").startsWith("proxy-mig-")),title=proxy-mig-only,description=Allow OS Admin Login only to proxy MIG instances'

# FW for Service Discovery in many mig used by observability-server
run_cleanup gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${OBSERVABILITY_VM_SA}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="projects/$PROJECT_ID/roles/computeVMAccess" \
    --condition='None'

# =========================================================
# 15. DELETE SERVICE ACCOUNTS
# =========================================================

echo "======================================="
echo "15. DELETE SERVICE ACCOUNTS"
echo "======================================="

SERVICE_ACCOUNTS=(
    "$BASTION_VM_SA"
    "$PROXY_VM_SA"
    "$BACKEND_VM_SA"
    "$OBSERVABILITY_VM_SA"
    "$CLOUD_BUILD_SA"
)

for SA in "${SERVICE_ACCOUNTS[@]}"; do
    SA_EMAIL="${SA}@${PROJECT_ID}.iam.gserviceaccount.com"

    if gcloud iam service-accounts describe "$SA_EMAIL" \
        --project="$PROJECT_ID" >/dev/null 2>&1; then

        run_cleanup gcloud iam service-accounts delete "$SA_EMAIL" \
            --project="$PROJECT_ID" --quiet
    else
        echo "SKIP: Service account $SA_EMAIL does not exist."
    fi
done

# =========================================================
# 16. VERIFY CUSTOM IAM ROLES - NEVER DELETE
# =========================================================

echo "======================================="
echo "16. VERIFY CUSTOM IAM ROLES"
echo "======================================="

CUSTOM_ROLES=(
    "computeInstanceUser"
    "computeProjectGetter"
    "computeVMAccess"
    "storageBucketLister"
)

for ROLE in "${CUSTOM_ROLES[@]}"; do
    echo
    echo "Checking custom role: $ROLE"

    if gcloud iam roles describe "$ROLE" \
        --project="$PROJECT_ID" \
        --format="value(name)"; then
        echo "PRESERVED: $ROLE"
    else
        echo "WARNING: Could not verify $ROLE"
    fi
done

# =========================================================
# CLEANUP SUMMARY
# =========================================================

echo
echo "======================================="
echo "CLEANUP SUMMARY"
echo "======================================="

if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "All cleanup commands completed successfully."
else
    echo "Some cleanup commands failed:"
    for ITEM in "${FAILED[@]}"; do
        echo " - $ITEM"
    done
    echo
    echo "Check dependencies and retry failed commands."
fi

echo
echo "Custom IAM role definitions were NOT deleted."
echo "======================================="


#!/bin/bash

PROJECT_ID="building-servers"
REGION="us-central1"

echo "========== COMPUTE INSTANCES =========="
gcloud compute instances list --project="$PROJECT_ID"

echo "========== INSTANCE TEMPLATES =========="
gcloud compute instance-templates list --project="$PROJECT_ID"

echo "========== MANAGED INSTANCE GROUPS =========="
gcloud compute instance-groups managed list --project="$PROJECT_ID"

echo "========== INSTANCE GROUPS =========="
gcloud compute instance-groups list --project="$PROJECT_ID"

echo "========== HEALTH CHECKS =========="
gcloud compute health-checks list --project="$PROJECT_ID"

echo "========== BACKEND SERVICES =========="
gcloud compute backend-services list --project="$PROJECT_ID"

echo "========== FORWARDING RULES =========="
gcloud compute forwarding-rules list --project="$PROJECT_ID"

echo "========== TARGET HTTP PROXIES =========="
gcloud compute target-http-proxies list --project="$PROJECT_ID"

echo "========== URL MAPS =========="
gcloud compute url-maps list --project="$PROJECT_ID"

echo "========== ADDRESSES =========="
gcloud compute addresses list --project="$PROJECT_ID"

echo "========== FIREWALL RULES =========="
gcloud compute firewall-rules list --project="$PROJECT_ID"

echo "========== NETWORKS =========="
gcloud compute networks list --project="$PROJECT_ID"

echo "========== SUBNETS =========="
gcloud compute networks subnets list --project="$PROJECT_ID"

echo "========== ROUTERS =========="
gcloud compute routers list --project="$PROJECT_ID"

echo "========== CLOUD NAT =========="
gcloud compute routers nats list --router=nat-router --router-region="$REGION" --project="$PROJECT_ID" 2>/dev/null || true

echo "========== SERVICE ACCOUNTS =========="
gcloud iam service-accounts list --project="$PROJECT_ID"

echo "========== ARTIFACT REGISTRY =========="
gcloud artifacts repositories list --project="$PROJECT_ID"

echo "========== STORAGE BUCKETS =========="
gcloud storage buckets list --project="$PROJECT_ID"

echo "========== CUSTOM IAM ROLES =========="
gcloud iam roles list --project="$PROJECT_ID"

echo "========== PROJECT IAM POLICY =========="
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --format="table(bindings.role,bindings.members,bindings.condition.title)"

echo "========== ENABLED SERVICES =========="
gcloud services list --enabled --project="$PROJECT_ID"

echo "========== DONE =========="
