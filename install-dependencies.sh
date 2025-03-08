#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 5 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <gpfs-version> <calico-version> <user> <ssh-key> <jumphost>"
    exit 1
fi

GPFS_VERSION=$1
CALICOCTL_VERSION=$2
user=$3
ssh_key=$4
jumphost=$5

if ! test -d "${GPFS_VERSION}"; then
  echo "This GPFS release is not present. Exiting."
  exit 1
fi

if command -v jq &>/dev/null; then
    echo "jq is already installed."
else
    if [[ -f /etc/redhat-release ]]; then
        yum install -y jq || dnf install -y jq
    elif [[ -f /etc/debian_version ]]; then
        apt update && apt install -y jq
    else
        echo "Unsupported Linux distribution. Please install jq manually."
        exit 1
    fi
fi

if command -v rsync &>/dev/null; then
    echo "rsync is already installed."
else
    if [[ -f /etc/redhat-release ]]; then
        yum install -y rsync || dnf install -y rsync
    elif [[ -f /etc/debian_version ]]; then
        apt update && apt install -y rsync
    else
        echo "Unsupported Linux distribution. Please install rsync manually."
        exit 1
    fi
fi

if command -v nmap &>/dev/null; then
    echo "nmap is already installed."
else
    if [[ -f /etc/redhat-release ]]; then
        yum install -y nmap || dnf install -y nmap
    elif [[ -f /etc/debian_version ]]; then
        apt update && apt install -y nmap
    else
        echo "Unsupported Linux distribution. Please install nmap manually."
        exit 1
    fi
fi

curl -L https://github.com/projectcalico/calico/releases/download/v${CALICOCTL_VERSION}/calicoctl-linux-amd64 -o calicoctl
chmod +x ./calicoctl
install -o root -g root -m 0755 calicoctl /usr/local/bin/calicoctl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x ./kubectl
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x ./get_helm.sh
./get_helm.sh
helm repo add nginx-stable https://helm.nginx.com/stable
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
workers_ip=(`kubectl get nodes -lnode-role.kubernetes.io/worker="true" -ojsonpath="{.items[*].status.addresses[0].address}"`)
for worker in ${workers_ip[@]}
do
    ssh -o "StrictHostKeyChecking=no" $worker -J $jumphost -i $ssh_key -l $user 'mkdir -p mmfs'
    ssh -o "StrictHostKeyChecking=no" $worker -J $jumphost -i $ssh_key -l $user 'sudo mkdir -p /mnt/grafana /mnt/prometheus'
    rsync -avz -e "ssh -J $jumphost -i $ssh_key -o StrictHostKeyChecking=no" "${GPFS_VERSION}" "$user"@"$worker":mmfs/
    ssh -o "StrictHostKeyChecking=no" $worker -J $jumphost -i $ssh_key -l $user 'sudo dnf install -y https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/Packages/kernel-{modules-extra-,headers-,devel-}4.18.0-553.el8_10.x86_64.rpm'
    ssh -o "StrictHostKeyChecking=no" $worker -J $jumphost -i $ssh_key -l $user 'sudo sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config'
    ssh -o "StrictHostKeyChecking=no" $worker -J $jumphost -i $ssh_key -l $user 'sudo setenforce 0'
done
