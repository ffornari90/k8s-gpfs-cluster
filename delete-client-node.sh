#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 4 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <k8s-namespace> <user> <ssh-key> <jumphost>"
    exit 1
fi

namespace=$1
user=$2
ssh_key=$3
jumphost=$4
workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="true" -ojsonpath="{.items[*].metadata.name}"`)
WORKER_COUNT="${#workers[@]}"
cli_hosts=(`kubectl -n $namespace get pod -lrole=gpfs-cli -ojsonpath="{.items[*].spec.nodeName}"`)
clis=(`kubectl -n $namespace get pods -lrole=gpfs-cli -ojsonpath="{.items[*].metadata.name}"`)
mgrs=(`kubectl -n $namespace get pods -lrole=gpfs-mgr -ojsonpath="{.items[*].metadata.name}"`)
MGR_POD_NAME=(`kubectl -n $namespace get pods -lapp=gpfs-mgr1 -ojsonpath="{.items[*].metadata.name}"`)
RANDOM=$$$(date +%s)
CLI_INDEX=$(($RANDOM % ${#clis[@]}))
CLI_POD_NAME=${clis[$CLI_INDEX]}
CLI_NAME=$(echo "$CLI_POD_NAME" | sed 's/-0$//')
CLI_FILE=$(grep -m1 -Ir $CLI_NAME | awk -F':' '{print $1}')
OFFSET=$(echo "$CLI_FILE" | grep -oP '\d+(?=[^/]*$)')
HOST_NAME=${cli_hosts[$CLI_INDEX]}
kubectl -n $namespace exec $CLI_POD_NAME -- /usr/bin/pkill -u storm
kubectl -n $namespace exec $CLI_POD_NAME -- /usr/lpp/mmfs/bin/mmumount all -a
kubectl -n $namespace exec $MGR_POD_NAME -- /usr/lpp/mmfs/bin/mmdelnode -N $CLI_POD_NAME
kubectl delete -f "./gpfs-instance-$namespace/gpfs-cli${OFFSET}.yaml"
kubectl delete -f "./gpfs-instance-$namespace/cli-svc${OFFSET}.yaml"
for cli in ${clis[@]}
do
  kubectl -n $namespace exec $cli -- bash -c "cp /etc/hosts hosts.tmp; sed -i \"/"$CLI_POD_NAME"/d\" hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp"
  kubectl -n $namespace exec $cli -- bash -c "sed -i \"/"$CLI_POD_NAME"/d\" /root/.ssh/known_hosts"
  kubectl -n $namespace exec $cli -- bash -c "sed -i \"/"$CLI_POD_NAME"/d\" /root/.ssh/authorized_keys"
done
for mgr in ${mgrs[@]}
do
  kubectl -n $namespace exec $mgr -- bash -c "cp /etc/hosts hosts.tmp; sed -i \"/"$CLI_POD_NAME"/d\" hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp"
  kubectl -n $namespace exec $mgr -- bash -c "sed -i \"/"$CLI_POD_NAME"/d\" /root/.ssh/known_hosts"
  kubectl -n $namespace exec $mgr -- bash -c "sed -i \"/"$CLI_POD_NAME"/d\" /root/.ssh/authorized_keys"
done
IP_ADDR=$(kubectl get node $HOST_NAME -ojsonpath="{.status.addresses[0].address}")
ssh -o "StrictHostKeyChecking=no" $IP_ADDR -J $jumphost -i $ssh_key -l $user "sudo su - -c \"rm -rf /root/cli${OFFSET}\""
rm -rf "./gpfs-instance-$namespace/cli-svc${OFFSET}.yaml"
rm -rf "./gpfs-instance-$namespace/gpfs-cli${OFFSET}.yaml"
rm -rf "./gpfs-instance-$namespace/client-req${OFFSET}.json"
rm -rf "./gpfs-instance-$namespace/client${OFFSET}.json"
