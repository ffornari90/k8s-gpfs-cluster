# k8s-gpfs-cluster

A project to deploy a GPFS cluster with Kubernetes.
This is an example of a command to create a GPFS cluster with 3 manager and quorum NSD servers:
``` bash
./create-cluster.sh \
  -N gpfs-test \
  -H ibm-spectrum-scale-abo6u6wbacgb-node-0,ibm-spectrum-scale-abo6u6wbacgb-node-1,ibm-spectrum-scale-abo6u6wbacgb-node-2 \
  -C gpfs-test \
  -i rhel8 \
  -q 3 \
  -n ibm-spectrum-scale-abo6u6wbacgb-node-0,ibm-spectrum-scale-abo6u6wbacgb-node-1,ibm-spectrum-scale-abo6u6wbacgb-node-2 \
  -d /dev/vdb \
  -f gpfs-k8s \
  -g yes
```
