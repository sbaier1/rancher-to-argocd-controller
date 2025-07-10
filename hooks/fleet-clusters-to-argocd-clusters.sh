#!/bin/bash
set -e
set -x

: ${ENABLE_HOOK_FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS:="false"}
# meant to be configured externally at launch time
: ${ENVIRONMENT_ID:=""}
: ${REGION_ID:=""}
: ${SERVER_NAME_PREFIX:=${ENVIRONMENT_ID}-}
: ${SERVER_NAME_SUFFIX:=""}
: ${SECRET_NAME_PREFIX:="argocd-cluster-"}
: ${SECRET_NAME_SUFFIX:=""}
: ${ARGOCD_NAMESPACE:=argocd}
: ${FLEET_NAMESPACE:=fleet-default}
: ${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_EXCLUDE_REGEX:=""}
: ${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_INCLUDE_REGEX:=""}
: ${K8S_INSECURE:="false"}

# https://github.com/flant/shell-operator/issues/726
# https://github.com/flant/shell-operator/blob/main/docs/src/HOOKS.md
if [[ $1 == "--config" ]]; then
  if [[ "${ENABLE_HOOK_RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS}" == "true" ]]; then
    cat <<EOF
configVersion: v1
settings:
  executionMinInterval: 60s
  executionBurst: 1
kubernetes:
- apiVersion: management.cattle.io/v3
  kind: Cluster
  executeHookOnEvent: [ "Added", "Modified", "Deleted" ]
  allowFailure: true
  queue: "${0}"
  group: "${0}"
schedule:
- name: "every 15 min"
  crontab: "*/15 * * * *"
  allowFailure: true
  queue: "${0}"
  group: "${0}"
EOF
  else
    cat <<EOF
configVersion: v1
settings:
  executionMinInterval: 1s
  executionBurst: 1
EOF
  fi

  exit 0
fi

if [[ -z "${ENVIRONMENT_ID}" ]]; then
  echo "ENVIRONMENT_ID must be set"
  exit 1
fi

# Get all clusters from provisioning API
CLUSTERS=$(kubectl get clusters.provisioning.cattle.io -o json -n "${FLEET_NAMESPACE}")

# iterate through all provisioning clusters
echo $CLUSTERS | jq -crM '.items[]' | while read -r cluster; do
  clusterResourceName=$(echo "${cluster}" | jq -crM '.metadata.name')
  clusterDisplayName=$(echo "${cluster}" | jq -crM '.spec.displayName // .metadata.name')
  echo "Processing cluster ${clusterResourceName} display name: ${clusterDisplayName}"
  
  if [[ -z "${clusterResourceName}" ]]; then
    echo "Empty cluster, moving on"
    continue
  fi
  
  # cluster exclude filtering
  if [[ -n "${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_EXCLUDE_REGEX}" ]]; then
    if [[ "${clusterDisplayName}" =~ ${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_EXCLUDE_REGEX} ]]; then
      echo "Ignoring cluster ${clusterDisplayName} due to exclude filtering"
      continue
    fi
  fi
  
  # cluster include filtering
  if [[ -n "${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_INCLUDE_REGEX}" ]]; then
    if ! [[ "${clusterDisplayName}" =~ ${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_INCLUDE_REGEX} ]]; then
      echo "Ignoring cluster ${clusterDisplayName} due to include filtering"
      continue
    fi
  fi
  
  # Find corresponding Fleet kubeconfig secret for this cluster
  KUBECONFIG_SECRET=$(kubectl -n ${FLEET_NAMESPACE} get secrets -l "cluster.x-k8s.io/cluster-name=${clusterResourceName}" -o json | jq -r '.items[] | select(.metadata.name | endswith("-kubeconfig"))')
  
  if [[ -z "${KUBECONFIG_SECRET}" ]]; then
    echo "No kubeconfig secret found for cluster ${clusterResourceName}, skipping"
    continue
  fi
  
  echo "Found kubeconfig secret for cluster ${clusterResourceName}"
  
  # Extract the kubeconfig data from the secret
  KUBECONFIG_VALUE=$(echo "${KUBECONFIG_SECRET}" | jq -r '.stringData.value // .data.value')
  
  # If the value is base64 encoded (from .data), decode it
  if [[ -n "${KUBECONFIG_VALUE}" && "${KUBECONFIG_VALUE}" != "null" ]]; then
    if echo "${KUBECONFIG_SECRET}" | jq -e '.data.value' > /dev/null; then
      KUBECONFIG_VALUE=$(echo "${KUBECONFIG_VALUE}" | base64 -d)
    fi
  else
    echo "Failed to extract kubeconfig value for cluster ${clusterResourceName}, skipping"
    continue
  fi
  
  # Extract token from the kubeconfig
  TOKEN=$(echo "${KUBECONFIG_SECRET}" | jq -r '.stringData.token // .data.token')
  if [[ -n "${TOKEN}" && "${TOKEN}" != "null" ]]; then
    if echo "${KUBECONFIG_SECRET}" | jq -e '.data.token' > /dev/null; then
      TOKEN=$(echo "${TOKEN}" | base64 -d)
    fi
  else
    # If direct token extraction fails, parse it from the kubeconfig
    TOKEN=$(echo "${KUBECONFIG_VALUE}" | grep -A2 'token:' | tail -n1 | awk '{print $2}')
  fi
  
  if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
    echo "Failed to extract token for cluster ${clusterResourceName}, skipping"
    continue
  fi
  
  # Extract server URL from the kubeconfig
  SERVER_URL=$(echo "${KUBECONFIG_VALUE}" | grep 'server:' | awk '{print $2}')
  
  # Extract CA data from the kubeconfig
  CA_DATA=$(echo "${KUBECONFIG_VALUE}" | grep 'certificate-authority-data:' | awk '{print $2}')
  
  # Create ArgoCD cluster secret
  SECRET_YAML=$(
    cat <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME_PREFIX}${clusterResourceName}${SECRET_NAME_SUFFIX}
  labels:
    argocd.argoproj.io/secret-type: cluster
    clusterId: "${clusterDisplayName}"
    environmentId: "${ENVIRONMENT_ID}"
    regionId: "${REGION_ID}"
    fleetImported: "true"
type: Opaque
stringData:
  name: "${SERVER_NAME_PREFIX}${clusterDisplayName}${SERVER_NAME_SUFFIX}"
  server: "${SERVER_URL}"
  config: |
    {
      "bearerToken": "${TOKEN}",
      "tlsClientConfig": {
        "insecure": ${K8S_INSECURE},
        "caData": "${CA_DATA}"
      }
    }
EOF
  )
  
  # Apply the ArgoCD cluster secret
  echo "${SECRET_YAML}" | kubectl -n "${ARGOCD_NAMESPACE}" apply -f -
  echo "Created/updated ArgoCD cluster secret for ${clusterResourceName}"
done