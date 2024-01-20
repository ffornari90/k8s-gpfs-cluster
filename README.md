# k8s-gpfs-cluster

A project to deploy a GPFS cluster with Kubernetes.
This is an example of a command to create a GPFS cluster with 2 manager NSD servers and 1 quorum server:
``` bash
./create-cluster.sh \
  -N gpfs-test \
  -H ibm-gpfs-k8s-2lba3vszki7i-node-0,ibm-gpfs-k8s-2lba3vszki7i-node-1 \
  -C gpfs-test \
  -i rhel8 \
  -q 1 \
  -n ibm-gpfs-k8s-2lba3vszki7i-node-0,ibm-gpfs-k8s-2lba3vszki7i-node-1 \
  -d /dev/vdb \
  -f gpfs-k8s \
  -g yes
```
Then a client Pod with StoRM WebDAV service and INDIGO-IAM authentication can be created with the following command:
```bash
./add-client-node.sh \
  -N gpfs-test \
  -p iam-double.cern.ch \
  -c iam-ca.pem
```
