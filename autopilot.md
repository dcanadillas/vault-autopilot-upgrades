# Vault autopilot upgrades

In this section we are showing a way to upgrade Vault by an [semi-automated process using Vault non-voters](https://developer.hashicorp.com/vault/docs/enterprise/automated-upgrades#mechanics) capability. By adding three more nodes into the cluster with a newer version, they will automatically join the cluster, `promote` the new nodes as the voters, `demote` the previous version nodes as `non-voters` and finally transfer the new leader into the new nodes.

Because we are using one Helm chart, we need to rejoin the previous nodes to the cluster, forming a 6 voter nodes cluster. Then, the previous nodes will be upgraded and they will join now as voters automatically, forming a 6 nodes Vault cluster. After the process is completed (The autopilot `Upgrade.Status` is `await-server-removal`), we need to delete the latest nodes (the ones used for the upgrade), and transfer the leader again. In this case the transfer of the leader will be done manually by removing the leader at the end, so the cluster will re-elect a new leader, but being sure that all versions are in place. This will take a Vault service interruption during the re-election (1 minute approx) 

## Install Vault
 
We will use a custom script that:
* Installs Vault
* Creates the namespace and Kubernetes secret with the Enterprise license
* Initializes the installed Vault cluster
* Saves the `Root Token` and `Unseal Key` in a Kubernetes secret called `vault-init-log` and also in `/tmp/vault-init-log.json`
* Unseal Vault

> NOTE: Vault values in this example is using a LoadBalancer service for the Vault UI and API. If you are deploying into a local Kubernetes cluster like Minikube or Kind bear in mind that you need something like MetalLB to provide LoadBalancer IPs. You can change also the `ui.serviceType` to `NodePort` or `ClusterIP`, but in that case you will need to forward the service to a local address or using your own ingress.  


```
export VAULT_LICENSE=<vault_enterprise_license>
./vault-k8s.sh -c values.yaml -l $VAULT_LICENSE
```

Configure your Vault env variables to connect to Vault (the values are shown in the output of previous script execution):
```
export VAULT_ADDR=<vault-ui_service_address>
export VAULT_TOKEN=<root_token>
```


Check peers:
```
vault operator raft list-peers
```

You should see an output like this:
```
Node       Address                        State       Voter
----       -------                        -----       -----
vault-0    vault-0.vault-internal:8201    leader      true
vault-1    vault-1.vault-internal:8201    follower    true
vault-2    vault-2.vault-internal:8201    follower    true
```

Check the version you deployed:
```
vault status -format json | jq -r .version
```


Check 

## Upgrade Vault
```
helm upgrade vault -n vault hashicorp/vault -f values-upgrade.yaml
```

Check that are new pods running, but not ready:
```
kubectl get po -l component=server -n vault
```

Let's unseal the new Vault pods:
```
./vault-unseal.sh -s vault-init-log
```

Now all pods should join the cluster. But Vault autopilot should have put the new Vault nodes as the voters, and leave the old ones as non-voters.
Check that listing the peers:
```
vault operator raft list-peers
```

You will need to wait till the older pods are non-voters. You can execute a `watch` command:
```
watch vault operator raft list-peers
```

Your final output should be something like this:
```
Node       Address                        State       Voter
----       -------                        -----       -----
vault-0    vault-0.vault-internal:8201    follower    false
vault-1    vault-1.vault-internal:8201    follower    false
vault-2    vault-2.vault-internal:8201    follower    false
vault-3    vault-3.vault-internal:8201    leader      true
vault-4    vault-4.vault-internal:8201    follower    true
vault-5    vault-5.vault-internal:8201    follower    true
```

Once you get that you can do a `Ctrl-C` to get out from the watch command.

You can check the status of autopilot. The lifecycle should be `idle --> await-new-voters --> demoting --> promoting --> leader-transfer --> await-server-removal --> idle`. So according to this, the new state of autopilot should be `await-server-removal`. You can check it by:
```
vault operator raft autopilot state -format json | jq -r .Upgrade.Status
```

## Setting up back the 3 nodes cluster with new version
The older Vault nodes didn't get the new version because they weren't restarted, so let's do that now:
```
kubectl delete po vault-0 vault-1 vault-2 -n vault
```

And unseal them (if auto unseal is not enable in your use case. In the previous installation script we just saved the init log with one Unseal Key into a Kubernetes secret... Don't do that in a productive cluster!!):
```
./vault-unseal.sh -s vault-init-log
```

Now the old pods should be part of the consensus as voters:
```
vault operator raft list-peers
```

You should see something like this:
```
Node       Address                        State       Voter
----       -------                        -----       -----
vault-0    vault-0.vault-internal:8201    follower    true
vault-1    vault-1.vault-internal:8201    follower    true
vault-2    vault-2.vault-internal:8201    follower    true
vault-3    vault-3.vault-internal:8201    leader      true
vault-4    vault-4.vault-internal:8201    follower    true
vault-5    vault-5.vault-internal:8201    follower    true
```

Now all nodes should be on target version. Let's use autopilot to check state:
```
vault operator raft autopilot state
```

You can get the leader from autopilot also:
```
vault operator raft autopilot state -format json | jq -r .Leader
```

So now, you should remove the peers that you added in the first upgrade, but you need to do in the right order, which is to remove first the followers and finally the leader, to force a new leader election in the three remaining nodes. From the previous log this would be `vault-4 --> vault-5 --> vault-3`:
```
vault operator raft remove-peer vault-4
vault operator raft remove-peer vault-5
vault operator raft remove-peer vault-3
```

Now a new leader will be elected: 
```
$ vault operator raft list-peers
Node       Address                        State       Voter
----       -------                        -----       -----
vault-0    vault-0.vault-internal:8201    leader      true
vault-1    vault-1.vault-internal:8201    follower    true
vault-2    vault-2.vault-internal:8201    follower    true
```

But previous Vault pods are running. So, to get back the installation to the 3 replicas, you just need to do an update on the Helm like:
```
helm upgrade vault -n vault --reuse-values --set server.ha.replicas=3 hashicorp/vault
```



## The scripted path

Install Vault:
```
./vault-k8s.sh -c values.yaml -l $VAULT_LICENSE
```
> NOTE: There will be a check in the beginning to confirm that you are working in the right K8s cluster. Type `y` if that is the case.

Source Vault env variables to connect from CLI, so we don't need to pass the Vault token to the scripts:
```
source /tmp/vault/vault-env.sh
```

Upgrade to 6 replicas:
```
helm upgrade vault -n vault --reuse-values --set server.image.tag="1.16.9-ent" --set server.ha.replicas=6 hashicorp/vault 
```

Unseal the new nodes (this shouldn't be needed if using Vault auto-unseal, but we are not using it in this demo):
```
./vault-unseal.sh -s vault-init-log
```

Wait till autopilot `Upgrade.Status` is in `await-server-removal`:
```
watch "kubectl exec -ti vault-0 -n vault -- sh -c \"VAULT_TOKEN=$VAULT_TOKEN vault operator raft autopilot state -format json\" | jq .Upgrade"
```

Execute the script that removes extra peers and set the leader to the initial Vault pods that has been upgraded:
```
./remove-peers.sh -s vault-init-log
```

Let's get back the Helm chart to the 3 replicas for the StatefulSet:
```
helm upgrade vault -n vault --reuse-values --set server.ha.replicas=3 hashicorp/vault
```

Clean the extra PVCs (this part is not yet scripted):
```
kubectl delete pvc data-vault-3 data-vault-4 data-vault-5
```