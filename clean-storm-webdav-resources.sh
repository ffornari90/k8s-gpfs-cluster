#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 2 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <k8s-namespace> <cluster-name>"
    exit 1
fi

namespace=$1
cluster=$2
kubectl delete -f gpfs-instance-$cluster/storm-webdav-ingress.yaml
kubectl delete -f gpfs-instance-$cluster/storm-webdav-svc.yaml
kubectl delete -f gpfs-instance-$cluster/storm-webdav-configmap.yaml
for cert in $(kubectl -n$namespace get secret | grep tls-ssl-storm-webdav | awk '{print $1}')
do
    kubectl -n$namespace delete secret $cert
done
