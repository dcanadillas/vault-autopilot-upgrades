CONFIG_FILES_DIR="/tmp/vault"
VAULT_CHART_VERSION="0.27.0"
VSO_CHART_VERSION="0.5.0"
VAULT_NODE_PORT=32000
VAULT_LICENSE="$VAULT_LICENSE"
VAULT_NS="vault"
HELM_RELEASE="vault"

# Setting coloring with tput
NC=$(tput sgr0)
RED=$(tput setaf 1)
GRN=$(tput setaf 2)
YELL=$(tput setaf 3)
BLUE=$(tput setaf 4)


mkdir -p $CONFIG_FILES_DIR

check () {
  # Check the kubernetes cluster info
  echo -e "\n${GRN}Checking the kubernetes cluster info...${NC}"
  kubectl cluster-info

  # Let's ask the user if the k8s cluster is correct
  read -p "${YELL}Is the k8s cluster correct? (y/n): ${NC}" K8S_CORRECT
  case $K8S_CORRECT in
      y|Y)
          echo -e "\n${GRN}Great! Let's continue...${NC}"
          ;;
      n|N)
          echo -e "\n${RED}Please, check the k8s cluster and try again...${NC}"
          exit 1
          ;;
      *)
          echo -e "\n${RED}Please, select \"y\" or \"n\"...${NC}"
          exit 1
          ;;
  esac

  if check_vault ; then
    echo -e "\n${GRN}Vault will be upgraded with values \"$VALUES_FILE\"...${NC}"

    # Ask the user if the Vault will be upgraded
    read -p "${YELL}Do you want to upgrade Vault Enterprise? (y/N): ${NC}" UPGRADE_VAULT
    case $UPGRADE_VAULT in
        y|Y)
            echo -e "\n${GRN}Great! Let's continue...${NC}"
            ;;
        *)
            echo -e "\n${RED}Aborted...${NC}"
            exit 1
            ;;
    esac

    # If Vault is installed we need to check that the license is set in the secret. If not, we need to set the environment variable
    kubectl get secret vault-ent-license -n $VAULT_NS &> /dev/null || 
    if [ -z $VAULT_LICENSE ];then
      echo -e "\n${RED}The VAULT_LICENSE is not set...${NC}"
      echo -e "\n${RED}Please, set the VAULT_LICENSE as environment variable or use the -l|--license option...${NC}"
      exit 1
    else 
      echo -e "\n${GRN}The VAULT_LICENSE is set...${NC}"
    fi
  fi

  if [ -z $VAULT_LICENSE ];then
    echo -e "\n${RED}The VAULT_LICENSE is not set...${NC}"
    echo -e "\n${RED}Please, set the VAULT_LICENSE as environment variable or use the -l|--license option...${NC}"
    exit 1
  fi


}

# Function to check that Vault is installed
check_vault () {
  # If Vault is intalled the function will return 0 (true), if not, it will return 1 (false)
  echo -e "\n${YELL}Checking if Vault is installed...${NC}"
  if [[ $(helm list -n $VAULT_NS | wc -l) -gt 1 ]]; then
    echo -e "\n${RED}Vault is already installed...${NC}"
    return 0
  fi
  return 1
}

help () {
  echo -e "\n${YELL}Usage: ${NC}vault-k8s.sh [OPTIONS]"
  echo -e "\n${YELL}Options: ${NC}"
  echo -e "\n${YELL}-c|--config${NC} <VALUES_FILE>  Helm values file for Vault"
  echo -e "\n${YELL}-l|--license${NC} <VAULT_LICENSE>  Vault license"
  echo -e "\n${YELL}-h|--help${NC}  Show this help message"
  echo -e "\n${YELL}Example: ${NC}vault-k8s.sh -c /tmp/vault-values.yaml -l <VAULT_LICENSE>"
  echo -e "\n${YELL}Example: ${NC}vault-k8s.sh -l <VAULT_LICENSE>"
  echo ""
  echo -e "\n${YELL}If the -c|--config option is not used, the script will create the values file for Vault in /tmp/vault/vault-values.yaml${NC}"
  exit 0
}

# Function to create the environment
vault_prep () {
  # Create the namespace for Vault if it doesn't exist
  kubectl get ns $VAULT_NS &> /dev/null || kubectl create ns $VAULT_NS

  kubectl get secret vault-ent-license -n $VAULT_NS &> /dev/null ||
  kubectl create secret generic vault-ent-license -n $VAULT_NS --from-literal license="$VAULT_LICENSE"

  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm repo update
}

# Function to create Vault helm values and configs
vault_configs () {
  tee $CONFIG_FILES_DIR/vault-values.yaml <<EOF
global:
  enabled: true
  namespace: ""
  tlsDisable: true

server:
  enabled: "-"
  enterpriseLicense:
    secretName: "vault-ent-license"
    secretKey: "license"

  image:
    repository: "hashicorp/vault-enterprise"
    tag: "1.15.5-ent"
    pullPolicy: IfNotPresent

  updateStrategyType: "OnDelete"
  logLevel: "debug"

  extraInitContainers: null
  extraPorts: null
  postStart: []
  extraEnvironmentVars: {}

  # extraSecretEnvironmentVars is a list of extra environment variables to set with the stateful set.
  # These variables take value from existing Secret objects.
  extraSecretEnvironmentVars: []
  extraVolumes: []
    # - type: secret (or "configMap")
    #   name: my-secret
    #   path: null # default is `/vault/userconfig`

  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: {{ template "vault.name" . }}
              app.kubernetes.io/instance: "{{ .Release.Name }}"
              component: server
          topologyKey: kubernetes.io/hostname

  priorityClassName: ""
  extraLabels: {}
  annotations: {}
  service:
    enabled: true
    active:
      enabled: true
      annotations: {}
    standby:
      enabled: true
      annotations: {}
    externalTrafficPolicy: Cluster
    port: 8200
    targetPort: 8200
    annotations: {}

  dataStorage:
    enabled: true
    size: 10Gi
    mountPath: "/vault/data"
    storageClass: null
    accessMode: ReadWriteOnce
    annotations: {}
    labels: {}

  persistentVolumeClaimRetentionPolicy: {}

  auditStorage:
    enabled: false
    size: 10Gi
    mountPath: "/vault/audit"
    storageClass: null
    accessMode: ReadWriteOnce
    annotations: {}
    labels: {}

  standalone:
    enabled: true
    config: |
      ui = true
      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }
      storage "file" {
        path = "/vault/data"
      }

      # Example configuration for using auto-unseal, using Google Cloud KMS. The
      # GKMS keys must already exist, and the cluster must have a service account
      # that is authorized to access GCP KMS.
      #seal "gcpckms" {
      #   project     = "vault-helm-dev"
      #   region      = "global"
      #   key_ring    = "vault-helm-unseal-kr"
      #   crypto_key  = "vault-helm-unseal-key"
      #}

  serviceAccount:
    create: true
    createSecret: false
    serviceDiscovery:
      enabled: true

  statefulSet:
    annotations: {}
  hostNetwork: false

# Vault UI
ui:
  enabled: true
  publishNotReadyAddresses: true
  activeVaultPodOnly: false
  serviceType: "NodePort"
  serviceNodePort: $VAULT_NODE_PORT
  externalPort: 8200
  targetPort: 8200
  externalTrafficPolicy: Cluster
  annotations: {}

EOF
  tee $CONFIG_FILES_DIR/vault-operator.yaml <<EOF
defaultVaultConnection:
  address: http://vault.vault.svc.cluster.local:8200
  enabled: true
  skipTLSVerify: false
EOF
}

vault_install () {
  local VALUES=$1
  local CHART_VERSION=$2
  helm upgrade -i $3 -n $VAULT_NS \
  -f $VALUES \
  --set server.enterpriseLicense.secretName=vault-ent-license \
  --set server.enterpriseLicense.secretKey=license \
  --version $CHART_VERSION \
  hashicorp/vault \
  --debug --wait

  # helm upgrade -i vault-secrets-operator -n vault-secrets-operator-system -f $CONFIG_FILES_DIR/vault-operator.yaml --version $VSO_CHART_VERSION hashicorp/vault-secrets-operator --debug --wait
}

# Let's create a function to initialize the Vault and save values in a secret in Kubernetes
vault_init () {
  # Let's get the number of Vault servers deployed from the labels of Vault pods
  NUMSERVERS=$(kubectl get pods -n $VAULT_NS -l component=server -l app.kubernetes.io/name=vault --no-headers | wc -l)
  # We need to wait for the Vault servers to be running
  for i in $(seq 0 $(($NUMSERVERS-1))); do
    while [[ $(kubectl get pods vault-$i -n $VAULT_NS -o 'jsonpath={..status.phase}') != "Running" ]]; do 
      echo "waiting for pod vault-$i to be running..." 
      sleep 1
    done
  done
  # Initialize the Vault using the first server, if the Vault is not initialized
  if [[ $(kubectl exec -n $VAULT_NS vault-0 -- vault status -format json | jq -r .initialized) ==  "false" ]]; then
    kubectl exec -n $VAULT_NS vault-0 -- sh -c "vault operator init -key-shares=1 -key-threshold=1 -format=json" | tee $CONFIG_FILES_DIR/vault-init-log.json
  fi

  if [ ! -f $CONFIG_FILES_DIR/vault-init-log.json ]; then
    echo -e "\n${RED}Error: The file vault-init-log.json doesn't exist...${NC}"
    exit 1
  fi

  # We need to unseal the Vault servers
  for i in $(seq 0 $(($NUMSERVERS-1))); do
    if [[ $(kubectl exec -n $VAULT_NS vault-$i -- vault status -format json | jq -r .sealed) == "true" ]]; then
      kubectl exec -it -n $VAULT_NS vault-$i -- sh -c "vault operator unseal $(jq -r .unseal_keys_b64[0] $CONFIG_FILES_DIR/vault-init-log.json)"
    fi
    sleep 2
  done
  # kubectl exec -n $VAULT_NS vault-0 -- sh -c "vault operator init -key-shares=1 -key-threshold=1 -format=json" | tee $CONFIG_FILES_DIR/vault/vault-init-log.json
  # kubectl exec -n $VAULT_NS vault-0 -- sh -c "vault operator unseal $(jq -r .unseal_keys_b64[0] $CONFIG_FILES_DIR/vault/vault-init-log.json)"
  # kubectl exec -n $VAULT_NS vault-0 -- vault login $(jq -r .root_token $CONFIG_FILES_DIR/vault/vault-init-log.json)
  

  if ! kubectl get secret vault-init-log -n $VAULT_NS --no-headers; then
    kubectl create secret generic vault-init-log --from-file=$CONFIG_FILES_DIR/vault-init-log.json -n $VAULT_NS
  else
    kubectl delete secret vault-init-log -n $VAULT_NS
    kubectl create secret generic vault-init-log --from-file=$CONFIG_FILES_DIR/vault-init-log.json -n $VAULT_NS
  fi


  # Let's print the Vault address from the service in Kubernetes. But check if the service is a LoadBalancer or a NodePort
  if [[ $(kubectl get svc vault-ui -n $VAULT_NS -o jsonpath='{.spec.type}') == "LoadBalancer" ]]; then
    VAULT_ADDR="http://$(kubectl get svc vault-ui -n $VAULT_NS -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8200"
    # echo -e "\n${YELL}Vault address: ${NC}http://$(kubectl get svc vault-ui -n $VAULT_NS -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8200"
  else
    VAULT_ADDR="http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}'):$(kubectl get svc vault-ui -n $VAULT_NS -o jsonpath='{.spec.ports[0].nodePort}')"
    echo -e "\n${YELL}Vault address: ${NC}http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}'):$(kubectl get svc vault-ui -n $VAULT_NS -o jsonpath='{.spec.ports[0].nodePort}')"
  fi

  VAULT_TOKEN=$(kubectl get secret vault-init-log -n $VAULT_NS -o jsonpath='{.data.vault-init-log\.json}' | base64 -d | jq -r .root_token)

  echo -e "\n${YELL}Vault address: ${NC}$VAULT_ADDR"
  # Let's print the Vault token
  echo ""
  echo -e "\n${YELL}Vault token: ${NC}$VAULT_TOKEN"
  echo ""
  echo "export VAULT_ADDR=$VAULT_ADDR" | tee $CONFIG_FILES_DIR/vault-env.sh
  echo "export VAULT_TOKEN=$VAULT_TOKEN" | tee -a $CONFIG_FILES_DIR/vault-env.sh
  echo ""
  echo -e "\n${YELL}Source the file to set the environment variables: ${NC}source $CONFIG_FILES_DIR/vault-env.sh"
  echo ""

  # Let's show where the 
  # export VAULT_ADDR=http://$(kubectl get svc vault-ui -n $VAULT_NS -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8200
  # export VAULT_TOKEN=$(kubectl get secret vault-init-log -n $VAULT_NS -o jsonpath='{.data.vault-init-log\.json}' | base64 -d | jq -r .root_token)

}


POSITIONAL=()
while [[ $# -gt 0 ]];do
  key="$1"
  case $key in
    -c|--config)
    VALUES_FILE="$2"
    shift 2
    ;;
    -l|--license)
    VAULT_LICENSE="$2"
    # if [ -z "$2" ]; then
    #   echo -e "\n${RED}The VAULT_LICENSE is empty...${NC}"
    #   echo -e "\n${RED}Please, set the VAULT_LICENSE as environment variable or use the -l|--license option...${NC}"
    #   exit 1
    # fi
    shift 2
    ;;
    -r|--release)
    HELM_RELEASE="$2"
    shift 2
    ;;
    -h|--help)
    help
    shift # past argument
    exit 0
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
  esac
done



# --------

# FUN STARTS HERE
check
# Preparing the environment with the namespace and the secrets
if [ -z VAULT_LICENSE ]; then
  echo -e "\n${RED}The VAULT_LICENSE is not set or empty...${NC}"
  echo -e "\n${RED}Please, set the VAULT_LICENSE as environment variable or use the -l|--license option...${NC}"
  exit 1
fi
vault_prep
if [ -z "$VALUES_FILE" ]; then
  VALUES_FILE="$CONFIG_FILES_DIR/vault-values.yaml"
  vault_configs
fi
# Install Vault
echo -e "\n${GRN}Installing Vault...${NC}"
vault_install $VALUES_FILE $VAULT_CHART_VERSION $HELM_RELEASE
# Initialize Vault
echo -e "\n${GRN}Initializing Vault...${NC}"
# We are executing the function to initialize the Vault only if the Vault is not initialized or if Vault is not installed
# if ! check_vault ||  [[ $(kubectl exec vault-0 -n $VAULT_NS -- vault status -format json | jq -r .initialized) ==  "false" ]]; then
vault_init
# fi

echo -e "\n${GRN}The Vault configuration is done!${NC}"

exit 0