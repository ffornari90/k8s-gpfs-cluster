#!/bin/bash
if ! [ $# -eq 2 ]; then
  echo "No arguments supplied. Please provide GPFS and calicoctl version as arguments."
  exit 1
fi
GPFS_VERSION=$1
CALICOCTL_VERSION=$2
curl -L https://github.com/projectcalico/calico/releases/download/v${CALICOCTL_VERSION}/calicoctl-linux-amd64 -o calicoctl
chmod +x ./calicoctl
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
    ssh -l core $worker 'mkdir -p mmfs'
    scp -r "${GPFS_VERSION}" core@$worker:mmfs/
    ssh -l core $worker 'curl -L "https://kojipkgs.fedoraproject.org//packages/kernel/6.6.3/100.fc38/x86_64/kernel-6.6.3-100.fc38.x86_64.rpm" -o kernel-6.6.3-100.fc38.x86_64.rpm'
    ssh -l core $worker 'curl -L "https://kojipkgs.fedoraproject.org//packages/kernel/6.6.3/100.fc38/x86_64/kernel-core-6.6.3-100.fc38.x86_64.rpm" -o kernel-core-6.6.3-100.fc38.x86_64.rpm'
    ssh -l core $worker 'curl -L "https://kojipkgs.fedoraproject.org//packages/kernel/6.6.3/100.fc38/x86_64/kernel-modules-6.6.3-100.fc38.x86_64.rpm" -o kernel-modules-6.6.3-100.fc38.x86_64.rpm'
    ssh -l core $worker 'curl -L "https://kojipkgs.fedoraproject.org//packages/kernel/6.6.3/100.fc38/x86_64/kernel-modules-core-6.6.3-100.fc38.x86_64.rpm" -o kernel-modules-core-6.6.3-100.fc38.x86_64.rpm'
    ssh -l core $worker 'sudo rpm-ostree override replace kernel-6.6.3-100.fc38.x86_64.rpm kernel-core-6.6.3-100.fc38.x86_64.rpm kernel-modules-6.6.3-100.fc38.x86_64.rpm kernel-modules-core-6.6.3-100.fc38.x86_64.rpm'
    ssh -l core $worker 'sudo systemctl reboot'
    sleep 10
done
for worker in ${workers[@]}
do
    ssh -l core $worker 'sudo rpm-ostree install kernel-headers-6.6.3-100.fc38.x86_64 kernel-devel-6.6.3-100.fc38.x86_64'
    ssh -l core $worker 'sudo systemctl reboot'
    sleep 10
done

#sudo sed -i '/\[ req \]/a req_extensions = req_ext' /etc/pki/tls/openssl.cnf
#echo '[ req_ext ]' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo 'subjectAltName = @alt_names' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo '[ alt_names ]' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo 'IP.1 = ' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
