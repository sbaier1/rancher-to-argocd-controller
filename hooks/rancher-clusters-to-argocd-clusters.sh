#!/bin/bash
set -e
#set -x

# Mode selection
: ${FLEET_MODE:="false"}
: ${ENABLE_HOOK_RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS:="false"}

# Common configuration
: ${ENVIRONMENT_ID:=""}
: ${REGION_ID:=""}
# Can be set to the literal "NONE" to not set a server name prefix.
: ${SERVER_NAME_SUFFIX:=""}
: ${SECRET_NAME_PREFIX:="argocd-cluster-"}
: ${SECRET_NAME_SUFFIX:=""}
: ${ARGOCD_NAMESPACE:=argocd}
: ${K8S_INSECURE:="false"}

# Fleet-specific configuration
: ${FLEET_NAMESPACE:=fleet-default}
: ${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_EXCLUDE_REGEX:=""}
: ${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_INCLUDE_REGEX:=""}

# Rancher-specific configuration
: ${RANCHER_URI:="https://rancher.cattle-system"}
: ${RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_EXCLUDE_REGEX:=""}
: ${RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_INCLUDE_REGEX:=""}
: ${RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS_REMOVE_TOKEN_TTL:="false"}
: ${RANCHER_CA_SECRET_NAME:=""}
: ${RANCHER_CA_SECRET_NS:=""}
: ${RANCHER_CA_SECRET_KEY:="tls.crt"}
: ${K8S_TOKEN:=""}
: ${K8S_CA_DATA:=""}

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

# Function to apply cluster filtering
apply_cluster_filtering() {
  local cluster_display_name="$1"
  local exclude_regex="$2"
  local include_regex="$3"
  
  # cluster exclude filtering
  if [[ -n "${exclude_regex}" ]]; then
    if [[ "${cluster_display_name}" =~ ${exclude_regex} ]]; then
      echo "Ignoring cluster ${cluster_display_name} due to exclude filtering"
      return 1
    fi
  fi
  
  # cluster include filtering
  if [[ -n "${include_regex}" ]]; then
    if ! [[ "${cluster_display_name}" =~ ${include_regex} ]]; then
      echo "Ignoring cluster ${cluster_display_name} due to include filtering"
      return 1
    fi
  fi
  
  return 0
}

# Fleet mode processing
if [[ "${FLEET_MODE}" == "true" ]]; then
  echo "Running in Fleet mode"
  
  # Get all clusters from Fleet API
  CLUSTERS=$(kubectl get clusters.fleet.cattle.io -o json -n "${FLEET_NAMESPACE}")
  
  # iterate through all Fleet clusters
  echo $CLUSTERS | jq -crM '.items[]' | while read -r cluster; do
    clusterResourceName=$(echo "${cluster}" | jq -crM '.metadata.name')
    clusterDisplayName=$(echo "${cluster}" | jq -crM '.spec.displayName // .metadata.name')
    echo "Processing Fleet cluster ${clusterResourceName} display name: ${clusterDisplayName}"
    
    if [[ -z "${clusterResourceName}" ]]; then
      echo "Empty cluster, moving on"
      continue
    fi
    
    # Apply filtering
    if ! apply_cluster_filtering "${clusterDisplayName}" \
         "${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_EXCLUDE_REGEX}" \
         "${FLEET_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_INCLUDE_REGEX}"; then
      continue
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
    
    # Get the cluster labels
    clusterLabels=$(echo "${cluster}" | yq eval '.metadata.labels' - -P | sed "s/^/    /g")
    
    # Handle special case for no prefix
    if [[ "${SERVER_NAME_PREFIX}" == "NONE" ]]; then
      CLUSTER_NAME="${clusterDisplayName}${SERVER_NAME_SUFFIX}"
    else
      CLUSTER_NAME="${SERVER_NAME_PREFIX}${clusterDisplayName}${SERVER_NAME_SUFFIX}"
    fi
    
    # Create ArgoCD cluster secret
    SECRET_YAML=$(
      cat <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME_PREFIX}${clusterResourceName}${SECRET_NAME_SUFFIX}
  labels:
${clusterLabels}
    argocd.argoproj.io/secret-type: cluster
    clusterId: "${clusterDisplayName}"
    environmentId: "${ENVIRONMENT_ID}"
    regionId: "${REGION_ID}"
    fleetImported: "true"
type: Opaque
stringData:
  name: "${CLUSTER_NAME}"
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
  
else
  # Rancher mode processing
  echo "Running in Rancher mode"
  
  if [[ -z "${RANCHER_URI}" ]]; then
    echo "RANCHER_URI must be set"
    exit 1
  fi
  
  # fetch CA data from cluster
  if [[ -n "${RANCHER_CA_SECRET_NAME}" && -z "${K8S_CA_DATA}" ]]; then
    [[ -n "${RANCHER_CA_SECRET_NS}" ]] && {
      NS_ARGS="-n ${RANCHER_CA_SECRET_NS}"
    }
    
    K8S_CA_DATA=$(kubectl ${NS_ARGS} get secrets ${RANCHER_CA_SECRET_NAME} -o json | jq -crM ".data.\"${RANCHER_CA_SECRET_KEY}\"")
    
    if [[ -z "${K8S_CA_DATA}" ]]; then
      echo "failed to retrieve K8S_CA_DATA using secret ${RANCHER_CA_SECRET_NS}/${RANCHER_CA_SECRET_NAME}"
      exit 1
    fi
    
    echo "properly fetched caData from secret"
  fi
  
  if [[ -z "${K8S_TOKEN}" ]]; then
    # gather up info for secret creation
    user=$(kubectl get users.management.cattle.io -o json -l 'authz.management.cattle.io/bootstrapping=admin-user' | jq -crM '.items[0]')
    userResourceName=$(echo "$user" | jq -crM '.metadata.name')
    token=$(kubectl get tokens.management.cattle.io -o json -l "authn.management.cattle.io/token-userId=${userResourceName},authn.management.cattle.io/kind=kubeconfig" | jq -crM '.items[0]')
    tokenResourceName=$(echo "$token" | jq -crM '.metadata.name')
    userToken=$(echo "$token" | jq -crM '.token')
    
    # sanity check the data
    if [[ "${userToken}" == "null" || "${tokenResourceName}" == "null" ]]; then
      echo "failed to properly retrive bearerToken from rancher crds"
      exit 1
    fi
    
    if [[ "${RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS_REMOVE_TOKEN_TTL}" == "true" ]]; then
      echo "removing token ttl"
      kubectl patch tokens.management.cattle.io "${tokenResourceName}" --type='merge' -p '{ "expiresAt": "", "ttl": 0 }'
    fi
    
    K8S_TOKEN="${tokenResourceName}:${userToken}"
    echo "properly fetched bearerToken from rancher crds"
  fi
  
  if [[ -z "${K8S_TOKEN}" ]]; then
    echo "empty bearerToken"
    exit 1
  fi
  
  RANCHER_CLUSTERS=$(kubectl get clusters.management.cattle.io -o json)
  
  # iterate rancher clusters and create corresponding argocd clusters
  echo $RANCHER_CLUSTERS | jq -crM '.items[]' | while read -r cluster; do
    # removing this label so rancher does not remove the secret immediately thinking it owns the secret
    cluster=$(echo "${cluster}" | jq -crM 'del(.metadata.labels."objectset.rio.cattle.io/hash")')
    clusterResourceName=$(echo "${cluster}" | jq -crM '.metadata.name')
    clusterDisplayName=$(echo "${cluster}" | jq -crM '.spec.displayName')
    echo "Processing Rancher cluster ${clusterResourceName} display name: ${clusterDisplayName}"
    
    if [[ -z "${clusterResourceName}" ]]; then
      echo "empty cluster, moving on"
      continue
    fi
    
    # Apply filtering
    if ! apply_cluster_filtering "${clusterDisplayName}" \
         "${RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_EXCLUDE_REGEX}" \
         "${RANCHER_CLUSTERS_TO_ARGOCD_CLUSTERS_CLUSTER_NAME_INCLUDE_REGEX}"; then
      continue
    fi
    
    # Handle special case for no prefix
    if [[ "${SERVER_NAME_PREFIX}" == "NONE" ]]; then
      CLUSTER_NAME="${clusterDisplayName}${SERVER_NAME_SUFFIX}"
    else
      CLUSTER_NAME="${SERVER_NAME_PREFIX}${clusterDisplayName}${SERVER_NAME_SUFFIX}"
    fi
    
    # this is kube-ca
    caCert=$(echo "${cluster}" | jq -crM '.status.caCert')
    clusterLabels=$(echo "${cluster}" | yq eval '.metadata.labels' - -P | sed "s/^/    /g")
    SECRET_YAML=$(
      cat <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME_PREFIX}${clusterResourceName}${SECRET_NAME_SUFFIX}
  labels:
${clusterLabels}
    argocd.argoproj.io/secret-type: cluster
    clusterId: "${clusterDisplayName}"
    environmentId: "${ENVIRONMENT_ID}"
    regionId: "${REGION_ID}"
    rancherImported: "true"
type: Opaque
stringData:
  name: "${CLUSTER_NAME}"
  server: "${RANCHER_URI}/k8s/clusters/${clusterResourceName}"
  config: |
    {
      "bearerToken": "${K8S_TOKEN}",
      "tlsClientConfig": {
        "insecure": ${K8S_INSECURE},
        "caData": "${K8S_CA_DATA}"
      }
    }
EOF
    )
    echo "${SECRET_YAML}" | kubectl -n "${ARGOCD_NAMESPACE}" apply -f -
  done
fi