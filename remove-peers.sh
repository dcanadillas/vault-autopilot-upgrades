#!/bin/bash

# Setting coloring with tput
NC=$(tput sgr0)
RED=$(tput setaf 1)
GRN=$(tput setaf 2)
YELL=$(tput setaf 3)
BLUE=$(tput setaf 4)

# We are getting the non upgraded non-voters before deleting the pods, because the initial non voters will be the ones to remain at the end.
get_non_voters () {
  NON_VOTERS=($(kubectl exec $VAULT_ACTIVE -n $1 -- /bin/sh -c "VAULT_TOKEN=$VAULT_TOKEN vault operator raft autopilot state -format json" | jq -r '.Upgrade.OtherVersionNonVoters[]?'))
  if [ ${#NON_VOTERS[@]} -eq 0 ]; then
    echo -e "\n${RED}There are no non-voters...${NC}"
    exit 1
  else
    echo -e "\n${YELL}Non voters are: ${NC}${NON_VOTERS[@]}"
  fi
}



get_peers () {
  LEADER=$(kubectl exec $VAULT_ACTIVE -n $1 -- /bin/sh -c "VAULT_TOKEN=$VAULT_TOKEN vault operator raft list-peers -format json" | jq -r '.data.config.servers[] | select(.leader == true) | .node_id')
  ALL_FOLLOWERS=($(kubectl exec vault-0 -n $1 -- /bin/sh -c "VAULT_TOKEN=$VAULT_TOKEN vault operator raft list-peers -format json" | jq -r '.data.config.servers[] | select(.leader == false) | .node_id'))
  echo -e "\n${YELL}Leader is: ${NC}$LEADER"
  echo -e "${YELL}Followers are: ${NC}${ALL_FOLLOWERS[@]}"
}

get_followers () {
  # This function will get the followers to remove (which are the ones created after the auto-upgrade process started)
  FOLLOWERS_TO_KEEP=${NON_VOTERS[@]}
  FOLLOWERS=()
  for i in "${ALL_FOLLOWERS[@]}"; do
    if [[ ! " ${FOLLOWERS_TO_KEEP[@]} " =~ " ${i} " ]]; then
      FOLLOWERS+=($i)
    fi
  done
  echo -e "${YELL}Order to delete pods should be: ${NC}${FOLLOWERS[@]} ${LEADER}"
}

# Function to get the Vault leader and delete first the followers
remove_peers () {
  # Parameters: $1: namespace
  echo -e "\n${YELL}Removing the Vault peers...${NC}"
  for i in "${FOLLOWERS[@]}"; do
    echo -e "\n${YELL}Removing Follower peer $i...${NC}"
    kubectl exec -it $VAULT_ACTIVE -n $1 -- /bin/sh -c "VAULT_TOKEN=$VAULT_TOKEN vault operator raft remove-peer $i"
    # echo "kubectl exec -it vault-0 -n $1 -- /bin/sh -c \"VAULT_TOKEN=$VAULT_TOKEN vault operator raft remove-peer $i\""
  done

  echo -e "\n${YELL}Removing Leader peer $LEADER...${NC}"
  kubectl exec -it $VAULT_ACTIVE -n $1 -- /bin/sh -c "VAULT_TOKEN=$VAULT_TOKEN vault operator raft remove-peer $LEADER"
  # echo "kubectl exec -it vault-0 -n $1 -- /bin/sh -c \"VAULT_TOKEN=$VAULT_TOKEN vault operator raft remove-peer $LEADER\""
}

check_vault_running () {
  # This function will check if the vault is running
  VAULT_RUNNING=$(kubectl get pods -n $VAULT_KNS -l app.kubernetes.io/name=vault --no-headers -o custom-columns=":metadata.name" | wc -l)
  if [ $VAULT_RUNNING -eq 0 ]; then
    echo -e "\n${RED}The Vault pods are not running...${NC}"
    exit 1
  fi

  # This will check if the vault pods are running even if the status is not ready
  NUMSERVERS=$(kubectl get pods -n $VAULT_KNS -l component=server -l app.kubernetes.io/name=vault --no-headers | wc -l)
  # We need to wait for the Vault servers to be running
  for i in $(seq 0 $(($NUMSERVERS-1))); do
    while [[ $(kubectl get pods vault-$i -n $VAULT_KNS -o 'jsonpath={..status.phase}') != "Running" ]]; do 
      echo "waiting for pod vault-$i to be running..." 
      sleep 1
    done
  done
}

target_version_non_voters () {
  # This function will get the target version non-voters
  TIMEOUT=0
  while [ $TIMEOUT -lt 30 ]; do
    # We are using the ? in jq to avoid errors if the array is empty
    VERSION_NON_VOTERS=($(kubectl exec $VAULT_ACTIVE -n $1 -- /bin/sh -c "VAULT_TOKEN=$VAULT_TOKEN vault operator raft autopilot state -format json" | jq -r '.Upgrade.TargetVersionNonVoters[]?'))
    echo -e "\n${YELL}Waiting for the non-voters to be updated...${NC}"
    if [[ -z ${VERSION_NON_VOTERS[@]} ]]; then
      echo -e "\n${YELL}There are no non-voters for the target version...${NC}"
      break
    fi
    TIMEOUT=$((TIMEOUT+1))
    sleep 2
  done
}

delete_and_promote () {
  # Let's delete pods for the non-voters (the ones not updated yet)
  # echo -e "\nkubectl delete pods ${NON_VOTERS[@]} -n $VAULT_KNS"
  kubectl delete pods ${NON_VOTERS[@]} -n $VAULT_KNS
  # Let's check if Vault pods are running (even if the status is not ready)
  check_vault_running

  # We need to unseal Vault deleted pods after the pods are deleted (the following script won't do nothing if you have auto-unseal enabled).
  # We are assuming that there is only one unseal.
  if [[ -z $UNSEAL_KEY ]]; then
    if [[ -z $VAULT_INIT_LOG ]]; then
      echo -e "\n${RED}The unseal key or the vault-init-log secret is not set...${NC}"
      echo -e "${RED}Please, set the unseal key or the vault-init-log secret with environment variable or use the -k|--key or -s|--secret options...${NC}"
      exit 1
    fi
    ./vault-unseal.sh -s $VAULT_INIT_LOG
  else
    ./vault-unseal.sh -k $UNSEAL_KEY
  fi

  # Let's get the target version non-voters till they are empty
}


POSITIONAL=()
while [[ $# -gt 0 ]];do
  key="$1"
  case $key in
    -h|--help)
    echo -e "\n${YELL}Usage: ${NC}remove-peers.sh <vault_operator_token> <namespace>"
    echo -e "\n${YELL}Example:${NC}"
    echo -e "  remove-peers.sh hvs.xxxxxxxxxxxxxxxxxxxxxxxx vault"
    shift # past argument
    exit 0
    ;;
    -t|--token)
    VAULT_TOKEN="$2"
    shift 2
    ;;
    -n|--namespace)
    VAULT_KNS="$2"
    shift 2
    ;;
    -k|--key)
    UNSEAL_KEY="$2"
    # In case the unseal key is set, we need to shift 2
    if [[ -z $UNSEAL_KEY ]]; then
      shift
    else
      shift 2
    fi
    ;;
    -s|--secret)
    VAULT_INIT_LOG="$2"
    if [[ -z $VAULT_INIT_LOG ]]; then
      shift
    else
      shift 2
    fi
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
  esac
done

if [ -z $VAULT_TOKEN ];then
  echo -e "\n${YELLOW}The VAULT_TOKEN is not set...${NC}"
  echo -e "\n${YELLOW}Please, set the VAULT_TOKEN with environment variable or use the -t|--token option...${NC}"
  exit 1
fi

if [ -z $VAULT_KNS ];then
  echo -e "\n${YELLOW}The Vault namespace is not set...${NC}"
  echo -e "${YELLOW}We will use the default namespace \"vault\"...${NC}"
  VAULT_KNS="vault"
fi

VAULT_PODS=($(kubectl get pods -n $VAULT_KNS -l app.kubernetes.io/name=vault --no-headers -o custom-columns=":metadata.name"))
VAULT_ACTIVE=$(kubectl get pods -n $VAULT_KNS -l app.kubernetes.io/name=vault --no-headers -l vault-active=true -o custom-columns=":metadata.name")


# FUN STARTS HERE
# Let's get the non-voters before the were updated
get_non_voters $VAULT_KNS

# Let's get the peers and the leader to remove the followers first

get_peers $VAULT_KNS

# Deleting the non-voters pods and promoting the new ones as voters
delete_and_promote

# Wait for the target version non-voters to be empty
target_version_non_voters $VAULT_KNS

# Let's get the followers to remove
get_followers
remove_peers $VAULT_KNS

# Deleting pods of previous followers and previous leader
kubectl delete pods ${FOLLOWERS[@]} $LEADER -n $VAULT_KNS

