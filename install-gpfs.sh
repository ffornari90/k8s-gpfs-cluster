#!/bin/bash
if [ $# -eq 0 ]; then
  echo "No arguments supplied. Please provide GPFS version as argument."
  exit 1
fi
GPFS_VERSION=$1
OS_SERVER_URL="http://os-server.cr.cnaf.infn.it/distro/Storage/GPFS-pkg/${GPFS_VERSION}/"
if ! curl --output /dev/null --silent --head --fail "${OS_SERVER_URL}"; then
  echo "This GPFS release is not present on os-server. Exiting."
  exit 1
fi
if ! [[ `rpm -qa | grep wget` ]]; then
    sudo yum install -y wget
fi
wget -r --no-parent --reject="index.html*" "${OS_SERVER_URL}"
kubectl label node master001 kubernetes.io/role=ingress
workers=(`kubectl get nodes | grep worker | awk '{print $1}'`)
for worker in ${workers[@]}
do
  kubectl label node $worker node-role.kubernetes.io/worker=""
  ssh $worker sudo mkdir -p /usr/lpp/mmfs
  scp -r "os-server.cr.cnaf.infn.it/distro/Storage/GPFS-pkg/${GPFS_VERSION}" $worker:
  ssh $worker sudo mv "/home/centos/${GPFS_VERSION}" /usr/lpp/mmfs/
done
rm -rf os-server.cr.cnaf.infn.it/
sudo sed -i '/\[ req \]/a req_extensions = req_ext' /etc/pki/tls/openssl.cnf
echo '[ req_ext ]' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
echo 'subjectAltName = @alt_names' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
echo '[ alt_names ]' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
echo 'IP.1 = ' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
