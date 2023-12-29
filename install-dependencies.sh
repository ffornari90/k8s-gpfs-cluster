#!/bin/bash
if ! [ $# -eq 2 ]; then
  echo "No arguments supplied. Please provide GPFS and calicoctl version as arguments."
  exit 1
fi
GPFS_VERSION=$1
CALICOCTL_VERSION=$2
kinit ${USER}@CERN.CH
klist
xrdcp root://eosuser.cern.ch//eos/user/${USER::1}/${USER}/gpfs-${GPFS_VERSION}.tar.gz .
tar xzvf gpfs-${GPFS_VERSION}.tar.gz
if ! test -d "${GPFS_VERSION}"; then
  echo "This GPFS release is not present. Exiting."
  exit 1
fi
kubectl label node $(kubectl get nodes -lnode-role.kubernetes.io/master="" -ojsonpath="{.items[*].metadata.name}") kubernetes.io/role=ingress
workers=(`kubectl get nodes | grep node | awk '{print $1}'`)
for worker in ${workers[@]}
do
  kubectl label node $worker node-role.kubernetes.io/worker=""
  scp -r "${GPFS_VERSION}" $worker:
done
#sudo sed -i '/\[ req \]/a req_extensions = req_ext' /etc/pki/tls/openssl.cnf
#echo '[ req_ext ]' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo 'subjectAltName = @alt_names' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo '[ alt_names ]' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo 'IP.1 = ' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
curl -L https://github.com/projectcalico/calico/releases/download/v${CALICOCTL_VERSION}/calicoctl-linux-amd64 -o calicoctl
chmod +x ./calicoctl
