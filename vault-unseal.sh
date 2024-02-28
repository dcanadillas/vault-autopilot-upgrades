#!/bin/bash

# Setting coloring with tput
NC=$(tput sgr0)
RED=$(tput setaf 1)
GRN=$(tput setaf 2)
YELL=$(tput setaf 3)
BLUE=$(tput setaf 4)

VAULT_KNS="vault"

help () {
  echo -e "\n${YELL}Usage: ${NC}vault-unseal.sh [OPTIONS]"
  echo -e "\n${YELL}Options:${NC}"
  echo -e "  -k, --key\t\tUnseal key"
  echo -e "  -s, --secret\t\tVault init log secret"
  echo -e "  -h, --help\t\tShow this help message and exit"
  echo -e "\n${YELL}Example:${NC}"
  echo -e "  vault-unseal.sh -k <unseal_key> -s <vault-init-log>"
  echo -e "  vault-unseal.sh --key <unseal_key> --secret <vault-init-log>"
  echo -e "\n${YELL}Note:${NC}"
  echo -e "  The unseal key is required to unseal the vault"
  echo -e "  The vault-init-log secret is required to get the unseal key"
}

#Function to unseal vault from a JSON file or secrets in K8s
unseal_vault () {
  # Parameters: $1: unsealKey, $2: vault-0 pod name, $3: namespace
  UNSEALED=($(kubectl get pods -n $VAULT_KNS -l app.kubernetes.io/name=vault --no-headers -l vault-sealed=true -o custom-columns=":metadata.name"))
  for i in "${UNSEALED[@]}"; do
    echo -e "\n${YELL}Unsealing Vault pod $i...${NC}"
    kubectl exec -it $i -n $VAULT_KNS -- /bin/sh -c "vault operator unseal $1"
  done
}

get_unseal_key () {
  # Parameters: $1: vault-init-log secret, $2: namespace
  echo -e "\n${YELL}Getting the unseal key...${NC}"
  if kubectl get secret $1 -n $2 > /dev/null 2>&1; then
    UNSEAL_KEY=$(kubectl get secret $1 -n $2 -o jsonpath="{.data.vault-init-log\.json}" | base64 -d | jq -r '.unseal_keys_b64[0]')
  fi
  echo -e "\n${YELL}The unseal key is: ${GRN}$UNSEAL_KEY${NC}"
}

POSITIONAL=()
while [[ $# -gt 0 ]];do
  key="$1"
  case $key in
    -k|--key)
    UNSEAL_KEY="$2"
    shift 2
    ;;
    -s|--secret)
    VAULT_INIT_LOG="$2"
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

# if [[ -z $UNSEAL_KEY ]] || [[ -z $VAULT_INIT_LOG ]]; then
#   echo -e "\n${RED}Error: Missing required options${NC}"
#   help
#   exit 1
# fi

if [[ -z $UNSEAL_KEY ]]; then
  if [[ -z $VAULT_INIT_LOG ]]; then
    echo -e "\n${RED}You need to provide the unseal key or the vault-init-log secret${NC}"
    help
    exit 1
  fi
  get_unseal_key $VAULT_INIT_LOG $VAULT_KNS
  unseal_vault $UNSEAL_KEY $VAULT_KNS
else
  unseal_vault $UNSEAL_KEY $VAULT_KNS
fi
