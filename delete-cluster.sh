#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 5 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <k8s-namespace> <cluster-name> <user> <ssh-key> <jumphost>"
    exit 1
fi

namespace=$1
cluster=$2
user=$3
ssh_key=$4
jumphost=$5
workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="true" -ojsonpath="{.items[*].metadata.name}"`)
WORKER_COUNT="${#workers[@]}"
NSD_FILE="./gpfs-instance-$cluster/nsd-configmap.yaml"
if [ -f "$NSD_FILE" ]; then
  POD_NAME=$(kubectl -n $namespace get po --selector app=gpfs-mgr1,cluster=$cluster -ojsonpath="{.items[*].metadata.name}")
  FS_NAME=$(kubectl -n $namespace exec $POD_NAME -- /usr/lpp/mmfs/bin/mmlsmount all_local | awk '{print $3}')
  kubectl -n $namespace exec $POD_NAME -- /usr/lpp/mmfs/bin/mmumount all -a
  kubectl -n $namespace exec $POD_NAME -- /usr/lpp/mmfs/bin/mmdelfs $FS_NAME -p
  kubectl -n $namespace exec $POD_NAME -- /usr/lpp/mmfs/bin/mmdelnsd -F /tmp/StanzaFile
fi
for i in $(seq 1 $WORKER_COUNT)
do
  MGR_FILE="./gpfs-instance-$cluster/gpfs-mgr${i}.yaml"
  CLI_FILE="./gpfs-instance-$cluster/gpfs-cli${i}.yaml"
  if [ -f "$MGR_FILE" ]; then
    HOST_NAME=$(cat $MGR_FILE | grep nodeName | awk '{print $2}')
    IP_ADDR=$(kubectl get node $HOST_NAME -ojsonpath="{.status.addresses[0].address}")
    ssh -o "StrictHostKeyChecking=no" $IP_ADDR -J $jumphost -i $ssh_key -l $user "sudo su - -c \"rm -rf /root/gpfs-mgr*-$cluster\""
  fi
  if [ -f "$CLI_FILE" ]; then
    HOST_NAME=$(cat $CLI_FILE | grep nodeName | awk '{print $2}')
    IP_ADDR=$(kubectl get node $HOST_NAME -ojsonpath="{.status.addresses[0].address}")
    ssh -o "StrictHostKeyChecking=no" $IP_ADDR -J $jumphost -i $ssh_key -l $user "sudo su - -c \"rm -rf /root/gpfs-cli*-$cluster\""
  fi
done
GRAFANA_FILE="./gpfs-instance-$cluster/grafana.yaml"
if [ -f "$GRAFANA_FILE" ]; then
  helm uninstall gpfs
  helm uninstall prometheus
  helm uninstall grafana
  kubectl delete -f "./gpfs-instance-$cluster/grafana-admin-secret.yaml"
  kubectl delete secret grafana-cert
  #kubectl delete -f "./gpfs-instance-$namespace/prometheus-server-pvc.yaml"
  #kubectl delete -f "./gpfs-instance-$namespace/grafana-server-pvc.yaml"
  kubectl delete -f "./gpfs-instance-$cluster/prometheus-ingress.yaml"
  kubectl delete -f "./gpfs-instance-$cluster/grafana-ingress.yaml"
fi
for file in `ls ./gpfs-instance-$cluster/*.yaml | grep -vE '(namespace|patch)'`
do 
  kubectl delete -f $file 2>/dev/null
done
#kubectl delete ns $namespace
rm -rf "./gpfs-instance-$cluster"
