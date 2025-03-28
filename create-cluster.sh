#! /bin/bash

# Regular Colors
Color_Off='\033[0m'       # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Blue='\033[0;34m'         # Blue
Purple='\033[0;35m'       # Purple
Cyan='\033[0;36m'         # Cyan
White='\033[0;37m'        # White


# **************************************************************************** #
#                                  Utilities                                   #
# **************************************************************************** #

function usage () {
    echo "Usage: $0 [-N <k8s_namespace>] [-H <worker_list>] [-C <cluster_name>] [-b <cc_image_repo>] [-i <cc_image_tag>] [-q <quorum_count>] [-n <nsd_list>] [-d <nsd_devices>] [-f <fs_name>] [-g <yes_or_no>] [-t <timeout>] [-v <gpfs_version>]"
    echo
    echo "-N    Specify desired kubernetes Namespace on which the cluster will live (default is 'ns\$(date +%s)')"
    echo "      It must be a compliant DNS-1123 label and match =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
    echo "      In practice, must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character"
    echo "-H    Specify the list of worker nodes on which the GPFS cluster must be deployed (comma separated, e.g.: worker001,worker002)"
    echo "-C    Specify the name of the GPFS cluster to be deployed (default is 'gpfs\$(date +%s)')"
    echo "-b    Specify docker image repository to be used for Pods creation (default is $CC_IMAGE_REPO)"
    echo "-i    Specify docker image tag to be used for Pods creation (default is $CC_IMAGE_TAG)"
    echo "-q    Specify desired number of quorum servers (default is 1)"
    echo "-n    Specify desired list of Network Shared Disks worker nodes (comma separated, e.g.: worker001,worker002)"
    echo "-d    Specify desired list of devices for NSD nodes (comma separated, e.g.: /dev/sda,/dev/sdb)"
    echo "-f    Specify desired GPFS file system name (mountpoint is /ibm/<fs_name>)"
    echo "-g    Specify if monitoring with Prometheus and Grafana has to be deployed (default is no)"
    echo "-k    Specify SSH key path for cluster creation (default is ~/.ssh/id_rsa)"
    echo "-j    Specify jump host for cluster creation (default is jumphost)"
    echo "-t    Specify desired timeout for Pods creation in seconds (default is 3600)"
    echo "-u    Specify user to perform cluster creation (default is core)"
    echo "-v    Specify desired GPFS version for cluster creation (default is 5.1.8-2)"
    echo
    echo "-h    Show usage and exit"
    echo
}

function gen_role () {
    local role=$1
    local role_count=$2
    local fs_name=$3

    image_repo=$CC_IMAGE_REPO
    image_tag=$CC_IMAGE_TAG
    hostnames=$HOST_COUNT
    hostname=""

    for i in $(seq 1 $role_count); do
        [[ -z $role_count ]] && i=""
        j=`expr $i - 1`
        ip_index=${ip_indices[$j]}
        cp "$TEMPLATES_DIR/gpfs-${role}.template.yaml" "gpfs-${role}${i}.yaml"
        sed -i "s/%%%NAMESPACE%%%/${NAMESPACE}/g" "gpfs-${role}${i}.yaml"
        sed -i "s/%%%CLUSTER_NAME%%%/${CLUSTER_NAME}/g" "gpfs-${role}${i}.yaml"
        sed -i "s/%%%USER%%%/${USER}/g" "gpfs-${role}${i}.yaml"
        sed -i "s/%%%NUMBER%%%/${i}/g" "gpfs-${role}${i}.yaml"
        sed -i "s|%%%IMAGE_REPO%%%|${image_repo}|g" "gpfs-${role}${i}.yaml"
        sed -i "s/%%%IMAGE_TAG%%%/${image_tag}/g" "gpfs-${role}${i}.yaml"
        sed -i "s/%%%FS_NAME%%%/${fs_name}/g" "gpfs-${role}${i}.yaml"
        RANDOM=$$$(date +%s)
        if [[ $hostnames -eq 0 ]]; then
          workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="true" -ojsonpath="{.items[*].metadata.name}"`)
          hostname=${workers[ $RANDOM % ${#workers[@]} ]}
        else
          hostname=${HOST_ARRAY[$j]}
        fi
        CIDR="$(calicoctl ipam check | grep host:${hostname}: | awk '{print $3}')"
        IP_LIST=($(nmap -sL $CIDR | awk '/Nmap scan report/{print $NF}' | grep -v '^$' | sed -e 's/(//g' -e 's/)//g'))
        ALLOCATED_IPS=($(comm -23 <(kubectl get po -ojsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP}{"\n"}{end}' -A | sort) \
        <(kubectl get pods -A -o json | jq -r '.items[] | select(.status.phase=="Running") | select(.spec.hostNetwork==true) | .status.podIP' | sort)))
        for k in "${ALLOCATED_IPS[@]}"
        do
            for l in "${!IP_LIST[@]}"
            do
                if [[ "${IP_LIST[l]}" = "${k}" || -z "${IP_LIST[l]}" ]]; then
                    unset 'IP_LIST[l]'
                fi
            done
        done
        pod_ip=""
        while true; do
            index=$((1 + $RANDOM % ${#IP_LIST[@]}))
            if [ -n "${IP_LIST[index-1]}" ]; then
                pod_ip="${IP_LIST[index-1]//[\(\)]/}"
                break
            fi
        done
        sed -i "s/%%%NODENAME%%%/${hostname}/g" "gpfs-${role}${i}.yaml"
        sed -i "s/%%%PODNAME%%%/${CLUSTER_NAME}-gpfs-${role}-${i}/g" "gpfs-${role}${i}.yaml"
        sed -i "s/%%%POD_IP%%%/${pod_ip}/g" "gpfs-${role}${i}.yaml"
    done
}

function k8s-exec() {

    local namespace=$NAMESPACE
    local app=$1
    local cluster=$2
    [[ $3 ]] && local k8cmd=${@:3}

    kubectl exec --namespace=$namespace $(kubectl get pods --namespace=$namespace --selector app=$app,cluster=$cluster | grep -E '([0-9]+)/\1' | awk '{print $1}') -- /bin/bash -c "$k8cmd"

}


# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ $# -eq 0 ]; then
  echo "No arguments supplied. You can see available options with -h."
  exit 1
fi

# defaults
NAMESPACE="ns$(date +%s)"
CLUSTER_NAME="gpfs$(date +%s)"
CC_IMAGE_REPO="ffornari/gpfs-mgr"
CC_IMAGE_TAG="rhel8"
HOST_LIST=""
NSD_LIST=""
DEVICE_LIST=""
FS_NAME=""
HOST_COUNT=1
NSD_COUNT=0
MON_DEPLOY="no"
QRM_COUNT=1
TIMEOUT=3600
JUMPHOST="jumphost"
SSH_KEY="~/.ssh/id_rsa"
USER="core"
VERSION=5.1.8-2
workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="true" -ojsonpath="{.items[*].metadata.name}"`)
WORKER_COUNT="${#workers[@]}"

while getopts 'N:C:H:b:i:q:n:d:f:g:k:j:t:u:v:h' opt; do
    case "${opt}" in
        N) # a DNS-1123 label must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character
            if [[ $OPTARG =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]];
                then NAMESPACE=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        C) # cluster name must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character
            if [[ $OPTARG =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]];
                then CLUSTER_NAME=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        H)
            num_commas=$(echo "${OPTARG}" | tr -cd ',' | wc -c)
            if [[ $num_commas -lt $WORKER_COUNT ]]; then
                if grep -q -P '^([[:alnum:]-]+\.)*[[:alnum:]-]+([,]([[:alnum:]-]+\.)*[[:alnum:]-]+)*$' <<< $OPTARG; then
                    IFS=', ' read -r -a HOST_ARRAY <<< "${OPTARG}"
                    HOST_COUNT="${#HOST_ARRAY[@]}"
                    HOST_LIST="${OPTARG}"
                else
                    echo "! Wrong arg -$opt"; exit 1
                fi
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        b)
            CC_IMAGE_REPO=${OPTARG} ;;
        i)
            CC_IMAGE_TAG=${OPTARG} ;;
        q) # quorum count must be an integer greater than 0
            if [[ $OPTARG =~ ^[0-9]+$ ]] && [[ $OPTARG -gt 0 ]]; then
                QRM_COUNT=${OPTARG}
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        n)
            num_commas=$(echo "${OPTARG}" | tr -cd ',' | wc -c)
            if [[ $num_commas -lt $WORKER_COUNT ]]; then
                if grep -q -P '^([[:alnum:]-]+\.)*[[:alnum:]-]+([,]([[:alnum:]-]+\.)*[[:alnum:]-]+)*$' <<< $OPTARG; then
                    IFS=', ' read -r -a NSD_ARRAY <<< "${OPTARG}"
                    NSD_COUNT="${#NSD_ARRAY[@]}"
                    NSD_LIST="${OPTARG}"
                else
                    echo "! Wrong arg -$opt"; exit 1
                fi
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        d) # list of devices must consist in a comma separated list of NSD_COUNT "/dev/xxx" strings
            num_commas=$(echo "${OPTARG}" | tr -cd ',' | wc -c)
            if [[ $NSD_COUNT -gt 0 ]]; then
                if grep -q -P '^/dev/\w+(?:\s*,\s*/dev/\w+){'$num_commas'}$' <<< $OPTARG; then
                    IFS=', ' read -r -a DEVICE_ARRAY <<< "${OPTARG}"
                    DEVICE_COUNT="${#DEVICE_ARRAY[@]}"
                    DEVICE_LIST="${OPTARG}"
                else
                    echo "! Wrong arg -$opt"; exit 1
                fi
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        f) # FS name must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character
            if [[ $OPTARG =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]];
                then FS_NAME=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        g)
            if grep -q -P '^(yes|no)$' <<< $OPTARG; then
                MON_DEPLOY="${OPTARG}"
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        k) # SSH key path must consist of a unix file path
            if [[ $OPTARG =~ ^(.+)\/([^\/]+)$ ]];
                then SSH_KEY=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        j) # jumphost name must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character
            if [[ $OPTARG =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]];
                then JUMPHOST=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        t) # timeout must be an integer greater than 0
            if [[ $OPTARG =~ ^[0-9]+$ ]] && [[ $OPTARG -gt 0 ]]; then
                TIMEOUT=${OPTARG}
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        u) # user name must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character
            if [[ $OPTARG =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
                USER=${OPTARG}
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        v) # GPFS version must match pre-installed release
            GPFS_PRE_INSTALLED=$(ls | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$')
            if [[ "$OPTARG" == "$GPFS_PRE_INSTALLED" ]]; then
                VERSION=${OPTARG}
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        h)
            usage
            exit 0 ;;
        *)
            usage
            exit 1 ;;
    esac
done
shift $((OPTIND-1))

echo "NAMESPACE=$NAMESPACE"
echo "CLUSTER_NAME=$CLUSTER_NAME"
echo "CC_IMAGE_REPO=$CC_IMAGE_REPO"
echo "CC_IMAGE_TAG=$CC_IMAGE_TAG"
echo "HOST_COUNT=$HOST_COUNT"
echo "QRM_COUNT=$QRM_COUNT"
echo "NSD_COUNT=$NSD_COUNT"
echo "HOST_LIST=$HOST_LIST"
echo "NSD_LIST=$NSD_LIST"
echo "MON_DEPLOY=$MON_DEPLOY"
echo "DEVICE_LIST=$DEVICE_LIST"
echo "FS_NAME=$FS_NAME"
echo "SSH_KEY=$SSH_KEY"
echo "JUMPHOST=$JUMPHOST"
echo "TIMEOUT=$TIMEOUT"
echo "USER=$USER"
echo "VERSION=$VERSION"


# **********************************************************************************************
# Generation of the K8s manifests and configuration scripts for a complete namespaced instance #
# **********************************************************************************************

TEMPLATES_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/templates" # one-liner that gives the full directory name of the script no matter where it is being called from.
GPFS_INSTANCE_DIR="gpfs-instance-$CLUSTER_NAME"
mkdir $GPFS_INSTANCE_DIR
cd $GPFS_INSTANCE_DIR


# Generate the namespace
cp "$TEMPLATES_DIR/namespace.template.yaml" "namespace-$NAMESPACE.yaml"
sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "namespace-$NAMESPACE.yaml"
cp "$TEMPLATES_DIR/hosts.template" "hosts"

# Generate the configmap files
cp "$TEMPLATES_DIR/init-configmap.template.yaml" "init-configmap.yaml"
sed -i "s/%%%NAMESPACE%%%/${NAMESPACE}/g" "init-configmap.yaml"
sed -i "s/%%%VERSION%%%/${VERSION}/g" "init-configmap.yaml"

cp "$TEMPLATES_DIR/cluster-configmap.template.yaml" "cluster-configmap.yaml"
sed -i "s/%%%NAMESPACE%%%/${NAMESPACE}/g" "cluster-configmap.yaml"
sed -i "s/%%%CLUSTER_NAME%%%/${CLUSTER_NAME}/g" "cluster-configmap.yaml"

if [[ $NSD_COUNT -gt 0 ]]; then
  cp "$TEMPLATES_DIR/nsd-configmap.template.yaml" "nsd-configmap.yaml"
  sed -i "s/%%%NAMESPACE%%%/${NAMESPACE}/g" "nsd-configmap.yaml"
  sed -i "s/%%%CLUSTER_NAME%%%/${CLUSTER_NAME}/g" "nsd-configmap.yaml"
fi

if [[ "$MON_DEPLOY" == "yes" ]]; then
  PASSWORD=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  MASTER_IP=$(kubectl get nodes -lnode-role.kubernetes.io/master="true" -ojsonpath="{.items[*].status.addresses[0].address}")
  #cp "$TEMPLATES_DIR/prometheus-server-pvc.yaml" "prometheus-server-pvc.yaml"
  #cp "$TEMPLATES_DIR/grafana-server-pvc.yaml" "grafana-server-pvc.yaml"
  cp "$TEMPLATES_DIR/prometheus.values.yaml" "prometheus.yaml"
  cp "$TEMPLATES_DIR/grafana.values.yaml" "grafana.yaml"
  cp "$TEMPLATES_DIR/prometheus-ingress.yaml" "prometheus-ingress.yaml"
  cp "$TEMPLATES_DIR/grafana-ingress.yaml" "grafana-ingress.yaml"
  cp "$TEMPLATES_DIR/grafana-admin-secret.template.yaml" "grafana-admin-secret.yaml"
  cp "$TEMPLATES_DIR/nginx-ingress.template.yaml" "nginx-ingress.yaml"
  sed -i "s/%%%PASSWORD%%%/${PASSWORD}/g" "grafana-admin-secret.yaml"
  sed -i "s/%%%FS_NAME%%%/${FS_NAME}/g" "grafana.yaml"
  sed -i "s/%%%FIP%%%/${MASTER_IP}/g" "nginx-ingress.yaml"
fi

# Generate the manager manifests
gen_role mgr $HOST_COUNT $FS_NAME

printf '\n'
echo -e "${Yellow} Node list: ${Color_Off}"
for i in $(seq 1 $HOST_COUNT)
do
  j=`expr $i - 1`
  echo "   ${CLUSTER_NAME}-gpfs-mgr-$i-0:manager" | tee -a "cluster-configmap.yaml"
done

declare -a HOST_IPS
for i in $(seq 1 $HOST_COUNT)
do
  j=`expr $i - 1`
  HOST_IPS+=("$(kubectl get nodes ${HOST_ARRAY[$j]} -ojsonpath='{.status.addresses[0].address}')")
done

for i in $(seq 1 $QRM_COUNT)
do
  j=`expr $i - 1`
  sed -i "s/${CLUSTER_NAME}-gpfs-mgr-$i-0:manager/${CLUSTER_NAME}-gpfs-mgr-$i-0:quorum-manager/" "cluster-configmap.yaml"
done

printf '\n'
if [[ $NSD_COUNT -gt 0 ]]; then
  echo -e "${Yellow} NSD list: ${Color_Off}"
  NSD_COUNTER=1
  for j in $(seq 1 $NSD_COUNT)
  do
    k=`expr $j - 1`
    DEV_PARITY=`expr $DEVICE_COUNT % 2`
    if [[ $DEV_PARITY -eq 0 ]]; then
      for i in $(seq 1 $DEVICE_COUNT)
      do
        DEVICE_INDEX=`expr $i - 1`
        NSD_PARITY=`expr $j % 2`
        DEVICE_PARITY=`expr $i % 2`
        [ $NSD_PARITY -eq 0 ] && FG="2" || FG="${NSD_PARITY}"
        [ $DEVICE_PARITY -eq 0 ] && US="metadataOnly" || US="dataOnly"
        echo '   %nsd:
          device='${DEVICE_ARRAY[$DEVICE_INDEX]}'
          nsd=nsd'$NSD_COUNTER'
          servers='"${CLUSTER_NAME}-gpfs-mgr-${j}-0"'
          usage='$US'
          failureGroup='$FG'
          pool=system' | tee -a "nsd-configmap.yaml"
        printf '\n' | tee -a "nsd-configmap.yaml"
        NSD_COUNTER=$((NSD_COUNTER+1))
      done
    else
      for i in $(seq 1 $DEVICE_COUNT)
      do
        DEVICE_INDEX=`expr $i - 1`
        PARITY=`expr $j % 2`
        [ $PARITY -eq 0 ] && FG="2" || FG="${PARITY}"
        echo '   %nsd:
          device='${DEVICE_ARRAY[$DEVICE_INDEX]}'
          nsd=nsd'$NSD_COUNTER'
          servers='"${CLUSTER_NAME}-gpfs-mgr-${j}-0"'
          usage=dataAndMetadata
          failureGroup='$FG'
          pool=system' | tee -a "nsd-configmap.yaml"
        printf '\n' | tee -a "nsd-configmap.yaml"
        NSD_COUNTER=$((NSD_COUNTER+1))
      done
    fi
  done
  cp "$TEMPLATES_DIR/nsd-patch.template.yaml" "nsd-patch.yaml"
  sed -i "s/%%%PODNAME%%%/${CLUSTER_NAME}-gpfs-mgr-1/g" "nsd-patch.yaml"
  sed -i "s/%%%CLUSTER_NAME%%%/${CLUSTER_NAME}/g" "nsd-patch.yaml"
  kubectl patch --local=true -f "gpfs-mgr1.yaml" --patch "$(cat nsd-patch.yaml)" -o yaml > tmpfile
  cat tmpfile > "gpfs-mgr1.yaml"
  rm -f tmpfile
fi

# Generate the services
for i in $(seq 1 $HOST_COUNT)
do
  cp "$TEMPLATES_DIR/gpfs-mgr-svc.template.yaml" "mgr-svc${i}.yaml"
  sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "mgr-svc${i}.yaml"
  sed -i "s/%%%CLUSTER_NAME%%%/$CLUSTER_NAME/g" "mgr-svc${i}.yaml"
  sed -i "s/%%%NUMBER%%%/${i}/g" "mgr-svc${i}.yaml"
done

# **********************************************************************************************
# Deploy the instance #
# **********************************************************************************************

shopt -s nullglob # The shopt -s nullglob will make the glob expand to nothing if there are no matches.
roles_yaml=(gpfs-*.yaml)

# Instantiate the namespace
kubectl apply -f "namespace-$NAMESPACE.yaml"
if command -v oc &> /dev/null; then
  oc adm policy add-scc-to-user privileged -z default -n $NAMESPACE
fi

# Instantiate the configmap
kubectl apply -f "init-configmap.yaml"
kubectl apply -f "cluster-configmap.yaml"
if [[ $NSD_COUNT -gt 0 ]]; then
  kubectl apply -f "nsd-configmap.yaml"
fi

# Instantiate the services
for i in $(seq 1 $HOST_COUNT)
do
  kubectl apply -f "mgr-svc${i}.yaml"
done

if [[ "$MON_DEPLOY" == "yes" ]]; then
  helm install gpfs nginx-stable/nginx-ingress --values "nginx-ingress.yaml"
  openssl req -newkey rsa:2048 -nodes -x509 -days 1825 -keyout self-signed.key.pem -out self-signed.cert.pem -subj '/CN=k8s-gpfs-grafana.novalocal'
  kubectl create secret tls grafana-cert --cert=self-signed.cert.pem --key=self-signed.key.pem -n default
  kubectl apply -f "grafana-admin-secret.yaml"
fi

# Conditionally split the pod creation in groups, since apparently the external provisioner (manila?) can't deal with too many volume-creation request per second
g=1
count=1;
for ((i=0; i < ${#roles_yaml[@]}; i+=g)); do
    j=`expr $i + 1`
    scp -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" hosts "${USER}@${HOST_IPS[$i]}": > /dev/null 2>&1
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IPS[$i]}" -l "${USER}" "sudo su - -c \"mkdir -p /root/gpfs-mgr$j-$CLUSTER_NAME/var_mmfs\""
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IPS[$i]}" -l "${USER}" "sudo su - -c \"mkdir -p /root/gpfs-mgr$j-$CLUSTER_NAME/root_ssh\""
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IPS[$i]}" -l "${USER}" "sudo su - -c \"mkdir -p /root/gpfs-mgr$j-$CLUSTER_NAME/etc_ssh\""
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IPS[$i]}" -l "${USER}" "sudo su - -c \"mv /home/$USER/hosts /root/gpfs-mgr$j-$CLUSTER_NAME/\""

    for p in ${roles_yaml[@]:i:g}; do
        kubectl apply -f $p;
    done

    podsReady=$(kubectl get pods --namespace=$NAMESPACE -l cluster=$CLUSTER_NAME -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" |  wc -l)
    podsReadyExpected=$(( $((i+g))<${#roles_yaml[@]} ? $((i+g)) : ${#roles_yaml[@]} ))
    # [ tty ] && tput sc @todo
    while [[ $count -le 600 ]] && [[ "$podsReady" -lt "$podsReadyExpected" ]]; do
        podsReady=$(kubectl get pods --namespace=$NAMESPACE -l cluster=$CLUSTER_NAME -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" | wc -l)
        if [[ $(($count%10)) == 0 ]]; then
            # [ tty ] && tput rc @todo
            echo -e "\n${Yellow} Current situation of pods: ${Color_Off}"
            kubectl get pods --namespace=$NAMESPACE -l cluster=$CLUSTER_NAME
            if [[ $with_pvc == true ]]; then
                echo -e "${Yellow} and persistent volumes: ${Color_Off}"
                kubectl get pv --namespace=$NAMESPACE | grep "$NAMESPACE"
            fi
        fi
        echo -ne "\r Waiting $count secs for $podsReadyExpected pods to be Ready... $podsReady/$podsReadyExpected"
        sleep 1
        ((count+=1))
    done

done

if [[ $count -le $TIMEOUT ]] ; then
    echo -e "${Green} OK, all the Pods are in Ready state! $podsReady/$podsReadyExpected ${Color_Off}"
else
    echo -e "${Red} KO, not all the Pods are in Ready state! $podsReady/$podsReadyExpected ${Color_Off}"
    exit 1
fi

# **********************************************************************************************
# Start the GPFS services in each Pod
# **********************************************************************************************

echo "Starting the GPFS services in each Pod"

echo -e "${Yellow} Setup mutual resolution on all the Pods... ${Color_Off}"

pods=(`kubectl -n $NAMESPACE get pod -l cluster=$CLUSTER_NAME -ojsonpath="{.items[*].metadata.name}"`)
svcs=(`kubectl -n $NAMESPACE get pod -l cluster=$CLUSTER_NAME -ojsonpath="{.items[*].status.podIP}"`)
size=`expr "${#pods[@]}" - 1`

for i in $(seq 0 $size)
do
  printf '%s %s\n' "${svcs[$i]}" "${pods[$i]}" | tee -a hosts.tmp
done

for pod in ${pods[@]}
do
  kubectl cp hosts.tmp $NAMESPACE/$pod:/tmp/hosts.tmp
  kubectl -n $NAMESPACE exec -it $pod -- bash -c "cp /etc/hosts hosts.tmp; sed -i \"$ d\" hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp"
  kubectl -n $NAMESPACE exec -it $pod -- bash -c 'cat /tmp/hosts.tmp >> /etc/hosts'
done
rm -f hosts.tmp

echo -e "${Yellow} Distribute SSH keys on all the Pods... ${Color_Off}"

for pod in ${pods[@]}
do
  for i in $(seq 1 $HOST_COUNT)
  do
    j=`expr $i - 1`
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IPS[$j]}" -l "${USER}" \
    "echo \""$(kubectl -n $NAMESPACE exec -it $pod -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/gpfs-mgr$i-$CLUSTER_NAME/root_ssh/authorized_keys"
  done
done
for pod1 in ${pods[@]}
do
  for pod2 in ${pods[@]}
  do
    kubectl -n $NAMESPACE exec -it $pod1 -- bash -c "ssh -o \"StrictHostKeyChecking=no\" $pod2 hostname"
  done
done

echo -e "${Yellow} Exec GPFS cluster setup on quorum-manager... ${Color_Off}"
k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmcrcluster -N /root/node.list -C ${CLUSTER_NAME} -r /usr/bin/ssh -R /usr/bin/scp --profile gpfsprotocoldefaults"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Assign GPFS server licenses to managers... ${Color_Off}"
k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmchlicense server --accept -N managerNodes"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Check GPFS cluster configuration... ${Color_Off}"
k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmlscluster"
if [[ "$?" -ne 0 ]]; then exit 1; fi

if [[ "$MON_DEPLOY" == "yes" ]]; then
  echo -e "${Yellow} Setup Prometheus and Grafana for cluster monitoring... ${Color_Off}"
  CLUSTER_NAME=`k8s-exec gpfs-mgr1 ${CLUSTER_NAME} '/usr/lpp/mmfs/bin/mmlscluster -Y | grep ssh  | awk -F '"'"':'"'"' '"'"'{print \$7}'"'"`
  declare -a targets
  for i in $(seq 1 $HOST_COUNT)
  do
    targets+=("gpfs-mgr${i}")
  done
  PATTERN="        target_label: host"
  TARGETS=""
  suffix=".%%%NAMESPACE%%%.svc.cluster.local:9303"
  for item in "${targets[@]}"
  do
    TARGETS+="$(printf '\\t- %s%s\\n' ${item} ${suffix})"
  done
  LINE="    static_configs:\n\
      - targets:\n\
$(echo ${TARGETS})\
        labels:\n\
          cluster: %%%CLUSTER_NAME%%%\n\
          environment: test\n\
          role: compute"
  awk "/$PATTERN/{c++;if(c==1){print;print \"$LINE\";next}}1" "prometheus.yaml" > "prometheus.yaml.tmp"
  mv "prometheus.yaml.tmp" "prometheus.yaml"
  rm -f "prometheus.yaml.tmp"
  expand -t 8 "prometheus.yaml" > "prometheus.yaml.tmp"
  mv "prometheus.yaml.tmp" "prometheus.yaml"
  rm -f "prometheus.yaml.tmp"
  sed -i "s/%%%CLUSTER_NAME%%%/${CLUSTER_NAME}/g" "prometheus.yaml"
  sed -i "s/%%%NAMESPACE%%%/${NAMESPACE}/g" "prometheus.yaml"
  #kubectl apply -f "prometheus-server-pvc.yaml"
  helm install -f "prometheus.yaml" prometheus prometheus-community/prometheus
  kubectl apply -f "prometheus-ingress.yaml"
  #kubectl apply -f "grafana-server-pvc.yaml"
  helm install -f "grafana.yaml" grafana grafana/grafana
  kubectl apply -f "grafana-ingress.yaml"
fi

echo -e "${Yellow} Start GPFS daemon on every manager... ${Color_Off}"
failure=0; pids="";
for i in $(seq 1 $HOST_COUNT); do
    k8s-exec gpfs-mgr${i} ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmstartup"
    pids="${pids} $!"
    sleep 0.1
done
for pid in ${pids}; do
    wait ${pid} || let "failure=1"
done
if [[ "${failure}" == "1" ]]; then
    echo -e "${Red} Failed to Exec on one of the managers ${Color_Off}"
    exit 1
fi

echo -e "${Yellow} Wait until GPFS daemon is active on every manager... ${Color_Off}"
# Check status
check_active() {
    [[ "${*}" =~ ^(active )*active$ ]]
    return
}
node_states=(`k8s-exec gpfs-mgr1 ${CLUSTER_NAME} '/usr/lpp/mmfs/bin/mmgetstate -a | grep gpfs | awk '"'"'{print \$3}'"'"`)
until check_active ${node_states[*]}
do
  node_states=(`k8s-exec gpfs-mgr1 ${CLUSTER_NAME} '/usr/lpp/mmfs/bin/mmgetstate -a | grep gpfs | awk '"'"'{print \$3}'"'"`)
done

if [[ $NSD_COUNT -gt 0 ]]; then
    k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmgetstate -a"
    echo -e "${Yellow} Create desired number of NSDs... ${Color_Off}"
    k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmcrnsd -F /tmp/StanzaFile -v no"
    if [[ "$?" -ne 0 ]]; then exit 1; fi
else
    sleep 30
    k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmgetstate -a"
fi

if [ ! -z "$FS_NAME" ]; then
    echo -e "${Yellow} Create GPFS file system on previously created NSDs... ${Color_Off}"
    k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmcrfs ${FS_NAME} -F /tmp/StanzaFile -A no -B 4M -m ${NSD_COUNT} -M ${NSD_COUNT} -n 100 -Q yes -j scatter -k nfs4 -r ${NSD_COUNT} -R ${NSD_COUNT} -T /ibm/${FS_NAME}"
    if [[ "$?" -ne 0 ]]; then exit 1; fi

    echo -e "${Yellow} Mount GPFS file system on every manager... ${Color_Off}"
    failure=0; pids="";
    for i in $(seq 1 $HOST_COUNT); do
        k8s-exec gpfs-mgr${i} ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmmount ${FS_NAME}"
        pids="${pids} $!"
        sleep 0.1
    done
    for pid in ${pids}; do
        wait ${pid} || let "failure=1"
    done
    if [[ "${failure}" == "1" ]]; then
        echo -e "${Red} Failed to Exec on one of the managers ${Color_Off}"
        exit 1
    fi
fi

echo -e "${Yellow} Setup sensors and collectors to gather monitoring metrics... ${Color_Off}"
declare -a mgr_pod_list
for i in $(seq 1 $HOST_COUNT)
do
  j=`expr $i - 1`
  mgr_pod_list+=("${CLUSTER_NAME}-gpfs-mgr-$i-0")
done
printf -v mgr_pod_joined '%s,' "${mgr_pod_list[@]}"
k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmperfmon config generate --collectors ${mgr_pod_joined%,}"
if [[ "$?" -ne 0 ]]; then exit 1; fi
k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmchnode --perfmon -N managerNodes"
if [[ "$?" -ne 0 ]]; then exit 1; fi

for i in $(seq 1 $HOST_COUNT)
do
  k8s-exec gpfs-mgr${i} ${CLUSTER_NAME} "systemctl start pmsensors; systemctl stop pmsensors; systemctl start pmsensors"
  if [[ "$?" -ne 0 ]]; then exit 1; fi
  k8s-exec gpfs-mgr${i} ${CLUSTER_NAME} "systemctl start pmcollector"
  if [[ "$?" -ne 0 ]]; then exit 1; fi
done

if [[ "$MON_DEPLOY" == "yes" ]]; then
  for j in $(seq 1 $HOST_COUNT)
  do
    k8s-exec gpfs-mgr${j} ${CLUSTER_NAME} "systemctl daemon-reload && systemctl start gpfs_exporter"
    if [[ "$?" -ne 0 ]]; then exit 1; fi
  done
fi

sleep 10

if command -v oc &> /dev/null; then
  oc -n $NAMESPACE rsh $(oc -n $NAMESPACE get po --selector app=gpfs-mgr1,cluster=$CLUSTER_NAME -ojsonpath="{.items[0].metadata.name}") /usr/lpp/mmfs/bin/mmhealth cluster show
else
  k8s-exec gpfs-mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmhealth cluster show"
fi

# @todo add error handling
echo -e "${Green} Exec went OK for all the Pods ${Color_Off}"

# print configuration summary
echo ""
echo "NAMESPACE=$NAMESPACE"
echo "CLUSTER_NAME=$CLUSTER_NAME"
echo "CC_IMAGE_REPO=$CC_IMAGE_REPO"
echo "CC_IMAGE_TAG=$CC_IMAGE_TAG"
echo "HOST_COUNT=$HOST_COUNT"
echo "QRM_COUNT=$QRM_COUNT"
echo "NSD_COUNT=$NSD_COUNT"
echo "MON_DEPLOY=$MON_DEPLOY"
echo "HOST_LIST=$HOST_LIST"
echo "NSD_LIST=$NSD_LIST"
echo "DEVICE_LIST=$DEVICE_LIST"
echo "FS_NAME=$FS_NAME"
echo "SSH_KEY=$SSH_KEY"
echo "JUMPHOST=$JUMPHOST"
echo "TIMEOUT=$TIMEOUT"
echo "USER=$USER"
echo "VERSION=$VERSION"
