#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 2 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <owning-namespace> <accessing-namespace>"
    exit 1
fi

OWNING_NAMESPACE=$1
ACCESSING_NAMESPACE=$2

own_pods=(`kubectl -n $OWNING_NAMESPACE get pod -ojsonpath="{.items[*].metadata.name}"`)
own_svcs=(`kubectl -n $OWNING_NAMESPACE get pod -ojsonpath="{.items[*].status.podIP}"`)
own_size=`expr "${#own_pods[@]}" - 1`

access_pods=(`kubectl -n $ACCESSING_NAMESPACE get pod -ojsonpath="{.items[*].metadata.name}"`)
access_svcs=(`kubectl -n $ACCESSING_NAMESPACE get pod -ojsonpath="{.items[*].status.podIP}"`)
access_size=`expr "${#access_pods[@]}" - 1`

for i in $(seq 0 $own_size)
do
  printf '%s %s\n' "${own_svcs[$i]}" "${own_pods[$i]}" | tee -a hosts.tmp
done

for i in $(seq 0 $access_size)
do
  printf '%s %s\n' "${access_svcs[$i]}" "${access_pods[$i]}" | tee -a hosts.tmp
done

for pod in ${access_pods[@]}
do
  kubectl cp hosts.tmp $ACCESSING_NAMESPACE/$pod:/tmp/hosts.tmp
  kubectl -n $ACCESSING_NAMESPACE exec -it $pod -- bash -c "cp /etc/hosts hosts.tmp; sed -i \"$ d\" hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp"
  kubectl -n $ACCESSING_NAMESPACE exec -it $pod -- bash -c 'cat /tmp/hosts.tmp >> /etc/hosts'
  kubectl -n $ACCESSING_NAMESPACE exec -it $pod -- bash -c 'sort /etc/hosts | uniq > hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp'
done
rm -f hosts.tmp
