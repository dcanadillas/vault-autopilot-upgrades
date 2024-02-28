# Upgrading Vault Enterprise using Autopilot in Kubernetes

This repo is made for Vault demo purposes to understand how the Vault autopilot works when performing a Vault upgrade in Kubernetes.

The official Kubernetes upgrade guide for Vault is 

> NOTE: This Vault demo example is storing the Vault init log (`Root Token` and `Unseal Key`) in a Kubernetes secret. This is not a recommended pattern at all and it is done only for demo purposes!!

## Requirements
* Linux or MacOS terminal (WSL in Windows should work)
* `jq` command installed
* A Kubernetes cluster already deployed and connected (current context)
* Vault CLI if you follow the manual steps (if you run only without the provided scripts)

## Use cases

I have included a couple of use cases to follow with this repo:
* Use a semi-automated upgrade process using [Vault Enterprise automated upgrade](https://developer.hashicorp.com/vault/docs/enterprise/automated-upgrades), following manual commands. You can check it [here](autopilot.md)
  * Use the same semi automated process, but executing some helper scripts to accelerate process: [here](./autopilot.md#the-scripted-path)
* By using 2 different Helm charts and Vault Enterprise automated upgrades, without the need to do a manual re-election process: [here](./2helms/2Helms.md)
 
