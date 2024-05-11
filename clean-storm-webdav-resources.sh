#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 1 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <k8s-namespace>"
    exit 1
fi

namespace=$1
kubectl delete -f gpfs-instance-$namespace/storm-webdav-ingress.yaml
kubectl delete -f gpfs-instance-$namespace/storm-webdav-svc.yaml
kubectl delete -f gpfs-instance-$namespace/storm-webdav-configmap.yaml
for cert in $(kubectl -n$namespace get secret | grep tls-ssl-storm-webdav | awk '{print $1}')
do
    kubectl -n$namespace delete secret $cert
done
kubectl -n$namespace delete secret storm-cert
rm -rf gpfs-instance-$namespace/certs*
