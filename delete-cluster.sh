#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 1 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <k8s-namespace>"
    exit 1
fi

namespace=$1
workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="" -ojsonpath="{.items[*].metadata.name}"`)
WORKER_COUNT="${#workers[@]}"
NSD_FILE="./gpfs-instance-$namespace/nsd-configmap.yaml"
if [ -f "$NSD_FILE" ]; then
  POD_NAME=$(kubectl -n $namespace get po -lapp=gpfs-mgr1 -ojsonpath="{.items[*].metadata.name}")
  FS_NAME=$(kubectl -n $namespace exec $POD_NAME -- /usr/lpp/mmfs/bin/mmlsmount all_local | awk '{print $3}')
  kubectl -n $namespace exec $POD_NAME -- /usr/lpp/mmfs/bin/mmumount all -a
  kubectl -n $namespace exec $POD_NAME -- /usr/lpp/mmfs/bin/mmdelfs $FS_NAME -p
  kubectl -n $namespace exec $POD_NAME -- /usr/lpp/mmfs/bin/mmdelnsd -F /tmp/StanzaFile
fi
for i in $(seq 1 $WORKER_COUNT)
do
  MGR_FILE="./gpfs-instance-$namespace/gpfs-mgr${i}.yaml"
  CLI_FILE="./gpfs-instance-$namespace/gpfs-cli${i}.yaml"
  if [ -f "$MGR_FILE" ]; then
    HOST_NAME=$(cat $MGR_FILE | grep nodeName | awk '{print $2}')
    ssh $HOST_NAME -l centos "sudo su - -c \"rm -rf /root/mgr*\""
  fi
  if [ -f "$CLI_FILE" ]; then
    HOST_NAME=$(cat $CLI_FILE | grep nodeName | awk '{print $2}')
    ssh $HOST_NAME -l centos "sudo su - -c \"rm -rf /root/cli*\""
  fi
done
GUI_FILE="./gpfs-instance-$namespace/gui-svc.yaml"
if [ -f "$GUI_FILE" ]; then
  helm uninstall gpfs  
fi
kubectl delete ns $namespace
rm -rf "./gpfs-instance-$namespace"
