# Upgrade 2 Helms

This an example of a way to upgrade Vault with Automated upgrades using 2 Helm releases of Vault in the same namespace.

> NOTE: This method is not supported by HashiCorp, but it shows how to do a seamless upgrade of Vault by using its automatic upgrade capability using Autopilot

## Install first Helm
```
helm upgrade -i vault-168 -f 2helms/values-1.yaml -n vault hashicorp/vault --debug
```

```
kubectl exec -n vault vault-168-0 -- sh -c "vault operator init -key-shares=1 -key-threshold=1 -format=json" | tee 2helms/vault-168-init-log.json
```

```
kubectl delete secret vault-168-init-log -n vault
```
```
kubectl create secret generic vault-168-init-log -n vault --from-file=./2helms/vault-168-init-log.json
```
```
UNSEAL_KEY=$(kubectl get secret vault-168-init-log -n vault -o jsonpath="{.data.vault-168-init-log\.json}" | base64 -d | jq -r '.unseal_keys_b64[0]')
for i in vault-168-0 vault-168-1 vault-168-2; do
  echo -e "\n${YELL}Unsealing Vault pod $i...${NC}"
  kubectl exec -it $i -n vault -- /bin/sh -c "vault operator unseal $UNSEAL_KEY"
done
```

```
export VAULT_TOKEN=$(kubectl get secret vault-168-init-log -n vault -o jsonpath="{.data.vault-168-init-log\.json}" | base64 -d | jq -r '.root_token')
```


## Installing second helm and promote
```
helm upgrade -i vault-169 -f 2helms/values-upgrade.yaml -n vault hashicorp/vault --debug
``` 

```
for i in vault-169-0 vault-169-1 vault-169-2; do
  echo -e "\n${YELL}Unsealing Vault pod $i...${NC}"
  kubectl exec -it $i -n vault -- /bin/sh -c "vault operator unseal $UNSEAL_KEY"
done
```

Watching process. You need to wait till all nodes from `vault-168` release are non-voters:
```
watch "kubectl exec -ti vault-169-0 -n vault -- sh -c \"VAULT_TOKEN=$VAULT_TOKEN vault operator raft list-peers\""
```

Check also that autopilot status is `await-server-removal`:
```
watch "kubectl exec -ti vault-169-0 -n vault -- sh -c \"VAULT_TOKEN=$VAULT_TOKEN vault operator raft autopilot state -format json\" | jq .Upgrade"
```


Removing peers
```
for i in vault-168-0 vault-168-1 vault-168-2;do
  kubectl exec -ti -n vault vault-169-0 -- sh -c "VAULT_TOKEN=$VAULT_TOKEN vault operator raft remove-peer $i"
done
```

## Uninstalling old release
```
helm uninstall vault-168 -n vault
```

```
kubectl delete pvc -n vault data-vault-168-0 data-vault-168-1 data-vault-168-2
```
