# Upgrade 2 Helms

This an example of a way to upgrade Vault with Automated upgrades using 2 Helm releases of Vault in the same namespace.

> NOTE: This method is not supported by HashiCorp, but it shows how to do a seamless upgrade of Vault by using its automatic upgrade capability using Autopilot

## Install first Helm
```
helm upgrade -i vault-150 -f 2helms/values-1.yaml -n vault hashicorp/vault --debug
```

```
kubectl exec -n vault vault-150-0 -- sh -c "vault operator init -key-shares=1 -key-threshold=1 -format=json" | tee 2helms/vault-150-init-log.json
```

```
kubectl delete secret vault-150-init-log -n vault
```
```
kubectl create secret generic vault-150-init-log -n vault --from-file=./2helms/vault-150-init-log.json
```
```
UNSEAL_KEY=$(kubectl get secret vault-150-init-log -n vault -o jsonpath="{.data.vault-150-init-log\.json}" | base64 -d | jq -r '.unseal_keys_b64[0]')
for i in vault-150-0 vault-150-1 vault-150-2; do
  echo -e "\n${YELL}Unsealing Vault pod $i...${NC}"
  kubectl exec -it $i -n vault -- /bin/sh -c "vault operator unseal $UNSEAL_KEY"
done
```

```
export VAULT_TOKEN=$(kubectl get secret vault-150-init-log -n vault -o jsonpath="{.data.vault-150-init-log\.json}" | base64 -d | jq -r '.root_token')
```


## Installing second helm and promote
```
helm upgrade -i vault-155 -f 2helms/values-upgrade.yaml -n vault hashicorp/vault --debug
``` 

```
for i in vault-155-0 vault-155-1 vault-155-2; do
  echo -e "\n${YELL}Unsealing Vault pod $i...${NC}"
  kubectl exec -it $i -n vault -- /bin/sh -c "vault operator unseal $UNSEAL_KEY"
done
```

Watching process. You need to wait till all nodes from `vault-150` release are non-voters:
```
watch "kubectl exec -ti vault-155-0 -n vault -- sh -c \"VAULT_TOKEN=$VAULT_TOKEN vault operator raft list-peers\""
```

Check also that autopilot status is `await-server-removal`:
```
watch "kubectl exec -ti vault-155-0 -n vault -- sh -c \"VAULT_TOKEN=$VAULT_TOKEN vault operator raft autopilot state -format json\" | jq .Upgrade"
```


Removing peers
```
for i in vault-150-0 vault-150-1 vault-150-2;do
  kubectl exec -ti -n vault vault-155-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault operator raft remove-peer $i"
done
```

## Uninstalling old release
```
helm uninstall vault-150 -n vault

kubectl delete pvc -n vault data-vault-150-0 data-vault-150-1 data-vault-150-2
```
