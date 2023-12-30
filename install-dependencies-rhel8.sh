#!/bin/bash
if ! [ $# -eq 3 ]; then
  echo "No arguments supplied. Please provide GPFS version, calicoctl version and k8s master node IP as arguments."
  exit 1
fi
GPFS_VERSION=$1
CALICOCTL_VERSION=$2
K8S_MASTER_IP=$3
curl -L https://github.com/projectcalico/calico/releases/download/v${CALICOCTL_VERSION}/calicoctl-linux-amd64 -o calicoctl
chmod +x ./calicoctl
kinit ${USER}@CERN.CH
klist
xrdcp -r root://eosuser.cern.ch//eos/user/${USER::1}/${USER}/gpfs/${GPFS_VERSION} .
if ! test -d "${GPFS_VERSION}"; then
  echo "This GPFS release is not present. Exiting."
  exit 1
fi
ssh -l core ${K8S_MASTER_IP} 'sudo cp /etc/kubernetes/admin.conf .'
ssh -l core ${K8S_MASTER_IP} 'sudo cp -r /etc/kubernetes/certs .'
ssh -l core ${K8S_MASTER_IP} 'sudo chown core:core -R admin.conf certs'
rm -rf $HOME/.kube
mkdir -p $HOME/.kube
scp core@${K8S_MASTER_IP}:admin.conf $HOME/.kube/config
scp -r core@${K8S_MASTER_IP}:certs $HOME/.kube/
sed -i 's#/etc/kubernetes#'$HOME'/.kube#g' $HOME/.kube/config
sed -i 's/127.0.0.1/'${K8S_MASTER_IP}'/g' $HOME/.kube/config
export KUBECONFIG=$HOME/.kube/config
kubectl label node $(kubectl get nodes -lnode-role.kubernetes.io/master="" -ojsonpath="{.items[*].metadata.name}") kubernetes.io/role=ingress
workers=(`kubectl get nodes | grep node | awk '{print $1}'`)
for worker in ${workers[@]}
do
    kubectl label node $worker node-role.kubernetes.io/worker=""
    ssh -l core $worker 'mkdir -p mmfs'
    scp -r "${GPFS_VERSION}" core@$worker:mmfs/
    ssh -l core $worker 'sudo rpm-ostree override replace https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/Packages/kernel-{,core-,modules-,modules-core-}4.18.0-513.9.1.el8_9.x86_64.rpm'
    ssh -l core $worker 'sudo systemctl reboot'
    sleep 10
done
for worker in ${workers[@]}
do
    ssh -l core $worker 'sudo rpm-ostree install https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/Packages/kernel-{headers-,devel-}4.18.0-513.9.1.el8_9.x86_64.rpm'
    ssh -l core $worker 'sudo systemctl reboot'
    sleep 10
done

#sudo sed -i '/\[ req \]/a req_extensions = req_ext' /etc/pki/tls/openssl.cnf
#echo '[ req_ext ]' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo 'subjectAltName = @alt_names' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo '[ alt_names ]' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
#echo 'IP.1 = ' | sudo tee -a /etc/pki/tls/openssl.cnf > /dev/null
