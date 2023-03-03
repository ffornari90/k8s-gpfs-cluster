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
cli_hosts=(`kubectl -n $namespace get pod -lrole=gpfs-cli -ojsonpath="{.items[*].spec.nodeName}"`)
clis=(`kubectl -n $namespace get pods -lrole=gpfs-cli -ojsonpath="{.items[*].metadata.name}"`)
mgrs=(`kubectl -n $namespace get pods -lrole=gpfs-mgr -ojsonpath="{.items[*].metadata.name}"`)
RANDOM=$$$(date +%s)
CLI_INDEX=$(($RANDOM % ${#clis[@]}))
MGR_INDEX=$(($RANDOM % ${#mgrs[@]}))
OFFSET=`expr $INDEX + 1`
CLI_NAME=${clis[$INDEX]}
MGR_NAME=${mgrs[$INDEX]}
HOST_NAME=${cli_hosts[$INDEX]}
kubectl -n $namespace exec $CLI_NAME -- /usr/lpp/mmfs/bin/mmumount all -a
kubectl -n $namespace exec $CLI_NAME -- /usr/lpp/mmfs/bin/mmshutdown
kubectl -n $namespace exec $MGR_NAME -- /usr/lpp/mmfs/bin/mmdelnode -N $CLI_NAME
kubectl delete -f "./gpfs-instance-$namespace/gpfs-cli${OFFSET}.yaml"
for cli in ${clis[@]}
do
  #kubectl -n $namespace exec $cli -- bash -c "sed -i \"/"$CLI_NAME"/d\" /etc/hosts"
  kubectl -n $namespace exec $cli -- bash -c "sed -i \"/"$CLI_NAME"/d\" /root/.ssh/known_hosts"
  kubectl -n $namespace exec $cli -- bash -c "sed -i \"/"$CLI_NAME"/d\" /root/.ssh/authorized_keys"
done
for mgr in ${mgrs[@]}
do
  #kubectl -n $namespace exec $mgr -- bash -c "sed -i \"/"$CLI_NAME"/d\" /etc/hosts"
  kubectl -n $namespace exec $mgr -- bash -c "sed -i \"/"$CLI_NAME"/d\" /root/.ssh/known_hosts"
  kubectl -n $namespace exec $mgr -- bash -c "sed -i \"/"$CLI_NAME"/d\" /root/.ssh/authorized_keys"
done
ssh $HOST_NAME -l centos "sudo su - -c \"rm -rf /root/cli${OFFSET}\""
rm -rf "./gpfs-instance-$namespace/gpfs-cli${OFFSET}.yaml"
