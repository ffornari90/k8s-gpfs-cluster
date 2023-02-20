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
    echo "Usage: $0 [-N <k8s_namespace>] [-b <cc_image_repo>] [-i <cc_image_tag>] [-t <timeout>] [-v <gpfs_version>]"
    echo
    echo "-N    Specify the kubernetes Namespace on which the cluster resides (default is 'ns\$(date +%s)')"
    echo "      It must be a compliant DNS-1123 label and match =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
    echo "      In practice, must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character"
    echo "-b    Specify docker image repository to be used for node creation (default is $CC_IMAGE_REPO)"
    echo "-i    Specify docker image tag to be used for node creation (default is $CC_IMAGE_TAG)"
    echo "-t    Specify desired timeout for node creation in seconds (default is 3600)"
    echo "-v    Specify desired GPFS version for node creation (default is 5.1.2-8)"
    echo
    echo "-h    Show usage and exit"
    echo
}

function gen_role () {
    local role=$1

    image_repo=$CC_IMAGE_REPO
    image_tag=$CC_IMAGE_TAG

    result=$(ls | grep -o "${role}[0-9]\+" | cut -c4- | tail -1)
    if [ -z "$result" ]; then
      index=1
    else
      index=`expr $result + 1`
    fi
    cp "$TEMPLATES_DIR/gpfs-${role}.template.yaml" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%NAMESPACE%%%/${NAMESPACE}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%NUMBER%%%/${index}/g" "gpfs-${role}${index}.yaml"
    sed -i "s|%%%IMAGE_REPO%%%|${image_repo}|g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%IMAGE_TAG%%%/${image_tag}/g" "gpfs-${role}${index}.yaml"
    workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="" -ojsonpath="{.items[*].metadata.name}"`)
    RANDOM=$$$(date +%s)
    selected_worker=${workers[ $RANDOM % ${#workers[@]} ]}
    sed -i "s/%%%NODENAME%%%/${selected_worker}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%PODNAME%%%/${selected_worker%%.*}-gpfs-${role}-${index}/g" "gpfs-${role}${index}.yaml"
}

function k8s-exec() {

    local namespace=$NAMESPACE
    local app=$1
    [[ $2 ]] && local k8cmd=${@:2}

    kubectl exec --namespace=$namespace $(kubectl get pods --namespace=$namespace -l app=$app | grep -E '([0-9]+)/\1' | awk '{print $1}') -- /bin/bash -c "$k8cmd"

}


# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

# defaults
NAMESPACE="ns$(date +%s)"
CC_IMAGE_REPO="ffornari/gpfs-mgr"
CC_IMAGE_TAG="centos7"
HOST_COUNT=0
TIMEOUT=3600
VERSION=5.1.2-8
workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="" -ojsonpath="{.items[*].metadata.name}"`)
WORKER_COUNT="${#workers[@]}"

while getopts 'N:b:i:t:v:h' opt; do
    case "${opt}" in
        N) # a DNS-1123 label must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character
            if [[ $OPTARG =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]];
                then NAMESPACE=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        b)
            CC_IMAGE_REPO=${OPTARG} ;;
        i)
            CC_IMAGE_TAG=${OPTARG} ;;
        t) # timeout must be an integer greater than 0
            if [[ $OPTARG =~ ^[0-9]+$ ]] && [[ $OPTARG -gt 0 ]]; then
                TIMEOUT=${OPTARG}
            else
                echo "! Wrong arg -$opt"; exit 1
            fi ;;
        v) # GPFS version must match pre-installed release
            GPFS_PRE_INSTALLED=$(ssh ${workers[0]} sudo ls /usr/lpp/mmfs | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$')
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
echo "CC_IMAGE_REPO=$CC_IMAGE_REPO"
echo "CC_IMAGE_TAG=$CC_IMAGE_TAG"
echo "HOST_COUNT=$HOST_COUNT"
echo "TIMEOUT=$TIMEOUT"
echo "VERSION=$VERSION"


# **********************************************************************************************
# Generation of the K8s manifests and configuration scripts for a complete namespaced instance #
# **********************************************************************************************

TEMPLATES_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/templates" # one-liner that gives the full directory name of the script no matter where it is being called from.
GPFS_INSTANCE_DIR="gpfs-instance-$NAMESPACE"
if [ ! -d $GPFS_INSTANCE_DIR ]; then
  echo "k8s namespace $NAMESPACE does not exist. Exit."
  exit 1
fi
cd $GPFS_INSTANCE_DIR

# Generate the manager manifests
gen_role cli
index=$(ls | grep -o 'cli[0-9]\+' | cut -c4- | tail -1)
printf '\n'
# Generate the services
cp "$TEMPLATES_DIR/gpfs-svc.template.yaml" "cli-svc${index}.yaml"
sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "cli-svc${index}.yaml"
sed -i "s/%%%NUMBER%%%/${i}/g" "cli-svc${index}.yaml"

# **********************************************************************************************
# Deploy the instance #
# **********************************************************************************************

shopt -s nullglob # The shopt -s nullglob will make the glob expand to nothing if there are no matches.
roles_yaml=(gpfs-cli*.yaml)

# Instantiate the services
kubectl apply -f "cli-svc${index}.yaml"

# Conditionally split the pod creation in groups, since apparently the external provisioner (manila?) can't deal with too many volume-creation request per second
g=1
count=1;
for ((i=0; i < ${#roles_yaml[@]}; i+=g)); do
    j=`expr $i + 1`
    ssh "${HOST_ARRAY[$i]}" -l centos "sudo su - -c \"mkdir -p /root/client$j/var_mmfs\""
    ssh "${HOST_ARRAY[$i]}" -l centos "sudo su - -c \"mkdir -p /root/client$j/root_ssh\""
    ssh "${HOST_ARRAY[$i]}" -l centos "sudo su - -c \"mkdir -p /root/client$j/etc_ssh\""

    for p in ${roles_yaml[@]:i:g}; do
        kubectl apply -f $p;
    done

    podsReady=$(kubectl get pods --namespace=$NAMESPACE -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" |  wc -l)
    podsReadyExpected=$(( $((i+g))<${#roles_yaml[@]} ? $((i+g)) : ${#roles_yaml[@]} ))
    # [ tty ] && tput sc @todo
    while [[ $count -le 600 ]] && [[ "$podsReady" -lt "$podsReadyExpected" ]]; do
        podsReady=$(kubectl get pods --namespace=$NAMESPACE -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" | wc -l)
        if [[ $(($count%10)) == 0 ]]; then
            # [ tty ] && tput rc @todo
            echo -e "\n${Yellow} Current situation of pods: ${Color_Off}"
            kubectl get pods --namespace=$NAMESPACE
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

pods=(`kubectl -n $NAMESPACE get pod -ojsonpath="{.items[*].metadata.name}"`)
svcs=(`kubectl -n $NAMESPACE get pod -ojsonpath="{.items[*].status.podIP}"`)
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
    ssh "${HOST_ARRAY[$j]}" -l centos "echo \""$(kubectl -n $NAMESPACE exec -it $pod -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/client$i/root_ssh/authorized_keys"
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
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmcrcluster -N /root/node.list -C ${CLUSTER_NAME} -r /usr/bin/ssh -R /usr/bin/scp --profile gpfsprotocoldefaults"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Assign GPFS server licenses to managers... ${Color_Off}"
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmchlicense server --accept -N managerNodes"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Check GPFS cluster configuration... ${Color_Off}"
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmlscluster"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Start GPFS daemon on every manager... ${Color_Off}"
failure=0; pids="";
for i in $(seq 1 $HOST_COUNT); do
    k8s-exec gpfs-mgr${i} "/usr/lpp/mmfs/bin/mmstartup"
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
node_states=(`k8s-exec gpfs-mgr1 '/usr/lpp/mmfs/bin/mmgetstate -a | grep gpfs | awk '"'"'{print \$3}'"'"`)
until check_active ${node_states[*]}
do
  node_states=(`k8s-exec gpfs-mgr1 '/usr/lpp/mmfs/bin/mmgetstate -a | grep gpfs | awk '"'"'{print \$3}'"'"`)
done

if [[ $NSD_COUNT -gt 0 ]]; then
    k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmgetstate -a"
    echo -e "${Yellow} Create desired number of NSDs... ${Color_Off}"
    k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmcrnsd -F /tmp/StanzaFile -v no"
    if [[ "$?" -ne 0 ]]; then exit 1; fi
else
    sleep 30
    k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmgetstate -a"
fi

if ! [ -z "$FS_NAME" ]; then
    echo -e "${Yellow} Create GPFS file system on previously created NSDs... ${Color_Off}"
    k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmcrfs ${FS_NAME} -F /tmp/StanzaFile -A no -B 4M -m 1 -M 2 -n 100 -Q no -j scatter -k nfs4 -r 2 -R 2 -T /ibm/${FS_NAME}"
    if [[ "$?" -ne 0 ]]; then exit 1; fi

    echo -e "${Yellow} Mount GPFS file system on every manager... ${Color_Off}"
    failure=0; pids="";
    for i in $(seq 1 $HOST_COUNT); do
        k8s-exec gpfs-mgr${i} "/usr/lpp/mmfs/bin/mmmount ${FS_NAME}"
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
declare -a mgr_list
for i in $(seq 1 $HOST_COUNT)
do
  j=`expr $i - 1`
  mgr_list+=("${HOST_ARRAY[$j]%%.*}-gpfs-mgr-$i-0")
done
printf -v mgr_joined '%s,' "${mgr_list[@]}"
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmperfmon config generate --collectors ${mgr_joined%,}"
if [[ "$?" -ne 0 ]]; then exit 1; fi
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmchnode --perfmon -N managerNodes"
if [[ "$?" -ne 0 ]]; then exit 1; fi

for i in $(seq 1 $HOST_COUNT)
do
  k8s-exec gpfs-mgr$i "sed -i 's/%H/\$HOSTNAME/g' /usr/lib/systemd/system/pmsensors.service"
  k8s-exec gpfs-mgr$i "systemctl start pmsensors; systemctl stop pmsensors; systemctl start pmsensors"
  if [[ "$?" -ne 0 ]]; then exit 1; fi
  k8s-exec gpfs-mgr$i "systemctl start pmcollector"
  if [[ "$?" -ne 0 ]]; then exit 1; fi
done
sleep 10
if command -v oc &> /dev/null; then
  oc -n $NAMESPACE rsh $(oc -n $NAMESPACE get po -lapp=gpfs-mgr1 -ojsonpath="{.items[0].metadata.name}") /usr/lpp/mmfs/bin/mmhealth cluster show
else
  k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmhealth cluster show"
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
echo "MGR_COUNT=$MGR_COUNT"
echo "NSD_COUNT=$NSD_COUNT"
echo "HOST_LIST=$HOST_LIST"
echo "NSD_LIST=$NSD_LIST"
echo "DEVICE_LIST=$DEVICE_LIST"
echo "FS_NAME=$FS_NAME"
echo "TIMEOUT=$TIMEOUT"
echo "VERSION=$VERSION"
