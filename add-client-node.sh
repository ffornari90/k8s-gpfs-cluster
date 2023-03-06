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
    local fs_name=$2

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
    sed -i "s/%%%FS_NAME%%%/${fs_name}/g" "gpfs-${role}${index}.yaml"
    workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="" -o=jsonpath='{range .items[1:]}{.metadata.name}{"\n"}{end}'`)
    RANDOM=$$$(date +%s)
    selected_worker=${workers[ $RANDOM % ${#workers[@]} ]}
    CIDR="$(calicoctl ipam check | grep host:${selected_worker}: | awk '{print $3}')"
    IP_LIST=($(nmap -sL $CIDR | awk '/Nmap scan report/{print $NF}' | grep -v '^$'))
    ALLOCATED_IPS=($(calicoctl ipam check --show-all-ips | grep node=${selected_worker} | awk '{print $1}'))
    for k in "${ALLOCATED_IPS[@]}"
    do
      for l in "${!IP_LIST[@]}"
      do
        if [[ "${IP_LIST[l]}" = "${k}" || -z "${IP_LIST[l]}" ]]; then
          unset 'IP_LIST[l]'
        fi
      done
    done
    sed -i "s/%%%NODENAME%%%/${selected_worker}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%PODNAME%%%/${selected_worker%%.*}-gpfs-${role}-${index}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%POD_IP%%%/${IP_LIST[ $RANDOM % ${#IP_LIST[@]} ]}/g" "gpfs-${role}${index}.yaml"
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

if [ $# -eq 0 ]; then
  echo "No arguments supplied. You can see available options with -h."
  exit 1
fi

# defaults
NAMESPACE="ns$(date +%s)"
CC_IMAGE_REPO="ffornari/gpfs-storm-webdav"
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
FS_NAME=$(k8s-exec gpfs-mgr1 "ls /ibm/")

# Generate the manager manifests
gen_role cli $FS_NAME
index=$(ls | grep -o 'cli[0-9]\+' | cut -c4- | tail -1)
printf '\n'
# Generate the services
cp "$TEMPLATES_DIR/hosts.template" "hosts"
cp "$TEMPLATES_DIR/gpfs-cli-svc.template.yaml" "cli-svc${index}.yaml"
cp "$TEMPLATES_DIR/storm-webdav-configmap.template.yaml" "storm-webdav-configmap.yaml"
if [ ! -d "certs" ]; then
  mkdir -p certs
  openssl req -x509 -newkey rsa:4096 -days 365 \
  -nodes -sha256 -keyout certs/private.key -out certs/public.crt \
  -subj "/CN=storm-webdav-$NAMESPACE.svc.cluster.local"
  cp certs/public.crt certs/ca.crt
  kubectl create secret generic \
   tls-ssl-storm-webdav \
   -n $NAMESPACE \
   --from-file=./certs/private.key \
   --from-file=./certs/public.crt \
   --from-file=./certs/ca.crt
fi
sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "cli-svc${index}.yaml"
sed -i "s/%%%NUMBER%%%/${index}/g" "cli-svc${index}.yaml"
sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "storm-webdav-configmap.yaml"
sed -i "s/%%%FS_NAME%%%/$FS_NAME/g" "storm-webdav-configmap.yaml"

# **********************************************************************************************
# Deploy the instance #
# **********************************************************************************************

shopt -s nullglob # The shopt -s nullglob will make the glob expand to nothing if there are no matches.
roles_yaml=("gpfs-*.yaml")

# Instantiate the services
kubectl apply -f "cli-svc${index}.yaml"
kubectl apply -f "storm-webdav-configmap.yaml"

# Conditionally split the pod creation in groups, since apparently the external provisioner (manila?) can't deal with too many volume-creation request per second
g=1
count=1
CLI_FILE="./gpfs-cli${index}.yaml"
HOST_NAME=$(cat $CLI_FILE | grep nodeName | awk '{print $2}')
POD_NAME="$(cat $CLI_FILE | grep -m1 name | awk '{print $2}')-0"
for ((i=0; i < ${#roles_yaml[@]}; i+=g)); do
    scp hosts centos@"${HOST_NAME}": > /dev/null 2>&1
    ssh "${HOST_NAME}" -l centos "sudo su - -c \"mkdir -p /root/cli${index}/var_mmfs\""
    ssh "${HOST_NAME}" -l centos "sudo su - -c \"mkdir -p /root/cli${index}/root_ssh\""
    ssh "${HOST_NAME}" -l centos "sudo su - -c \"mkdir -p /root/cli${index}/etc_ssh\""
    ssh "${HOST_NAME}" -l centos "sudo su - -c \"mv /home/centos/hosts /root/cli${index}/\""

    for p in ${roles_yaml[@]:i:g}; do
        kubectl apply -f $p;
    done

    podsReady=$(kubectl get pods --namespace=$NAMESPACE -lapp=gpfs-cli${index} -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" |  wc -l)
    podsReadyExpected=$(( $((i+g))<${#roles_yaml[@]} ? $((i+g)) : ${#roles_yaml[@]} ))
    # [ tty ] && tput sc @todo
    while [[ $count -le 600 ]] && [[ "$podsReady" -lt "$podsReadyExpected" ]]; do
        podsReady=$(kubectl get pods --namespace=$NAMESPACE -lapp=gpfs-cli${index} -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" | wc -l)
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
printf '%s %s\n' "131.154.162.124" "iam-indigo.cr.cnaf.infn.it" | tee -a hosts.tmp

for pod in ${pods[@]}
do
  kubectl cp hosts.tmp $NAMESPACE/$pod:/tmp/hosts.tmp
  kubectl -n $NAMESPACE exec -it $pod -- bash -c "cp /etc/hosts hosts.tmp; sed -i \"$ d\" hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp"
  kubectl -n $NAMESPACE exec -it $pod -- bash -c 'cat /tmp/hosts.tmp >> /etc/hosts'
  kubectl -n $NAMESPACE exec -it $pod -- bash -c 'sort /etc/hosts | uniq > hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp'
done
rm -f hosts.tmp

echo -e "${Yellow} Distribute SSH keys on all the Pods... ${Color_Off}"

mgr_hosts=(`kubectl -n $NAMESPACE get pod -lrole=gpfs-mgr -ojsonpath="{.items[*].spec.nodeName}"`)
mgr_pods=(`kubectl -n $NAMESPACE get pod -lrole=gpfs-mgr -ojsonpath="{.items[*].metadata.name}"`)
cli_hosts=(`kubectl -n $NAMESPACE get pod -lrole=gpfs-cli -ojsonpath="{.items[*].spec.nodeName}"`)
cli_pods=(`kubectl -n $NAMESPACE get pod -lrole=gpfs-cli -ojsonpath="{.items[*].metadata.name}"`)

for i in $(seq 1 ${#mgr_pods[@]})
do
  j=`expr $i - 1`
  ssh "${HOST_NAME}" -l centos "echo \""$(kubectl -n $NAMESPACE exec -it ${mgr_pods[$j]} -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/cli$index/root_ssh/authorized_keys"
done

for i in $(seq 1 ${#cli_pods[@]})
do
  j=`expr $i - 1`
  ssh "${HOST_NAME}" -l centos "echo \""$(kubectl -n $NAMESPACE exec -it ${cli_pods[$j]} -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/cli$index/root_ssh/authorized_keys"
done

for i in $(seq 1 ${#mgr_hosts[@]})
do
  j=`expr $i - 1`
  ssh "${mgr_hosts[$j]}" -l centos "echo \""$(kubectl -n $NAMESPACE exec -it ${POD_NAME} -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/mgr$i/root_ssh/authorized_keys"
done

for i in $(seq 1 ${#cli_hosts[@]})
do
  j=`expr $i - 1`
  ssh "${cli_hosts[$j]}" -l centos "echo \""$(kubectl -n $NAMESPACE exec -it ${POD_NAME} -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/cli$i/root_ssh/authorized_keys"
done

for pod in ${cli_pods[@]}
do
  kubectl -n $NAMESPACE exec -it $pod -- bash -c "ssh -o \"StrictHostKeyChecking=no\" $POD_NAME hostname"
  kubectl -n $NAMESPACE exec -it $POD_NAME -- bash -c "ssh -o \"StrictHostKeyChecking=no\" $pod hostname"
done

for pod in ${mgr_pods[@]}
do
  kubectl -n $NAMESPACE exec -it $pod -- bash -c "ssh -o \"StrictHostKeyChecking=no\" $POD_NAME hostname"
  kubectl -n $NAMESPACE exec -it $POD_NAME -- bash -c "ssh -o \"StrictHostKeyChecking=no\" $pod hostname"
done

echo -e "${Yellow} Add GPFS node to the cluster from quorum-manager... ${Color_Off}"
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmaddnode -N $POD_NAME:client"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Assign GPFS client licenses to node... ${Color_Off}"
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmchlicense client --accept -N $POD_NAME"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Check GPFS cluster configuration... ${Color_Off}"
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmlscluster"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Start GPFS daemon on client node... ${Color_Off}"
failure=0; pids="";
k8s-exec gpfs-cli${index} "/usr/lpp/mmfs/bin/mmstartup"
pids="${pids} $!"
sleep 0.1
for pid in ${pids}; do
    wait ${pid} || let "failure=1"
done
if [[ "${failure}" == "1" ]]; then
    echo -e "${Red} Failed to Exec on the client node ${Color_Off}"
    exit 1
fi

echo -e "${Yellow} Wait until GPFS daemon is active on the client node... ${Color_Off}"
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

sleep 30
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmgetstate -a"

echo -e "${Yellow} Mount GPFS file system on client node... ${Color_Off}"
failure=0; pids="";
k8s-exec gpfs-cli${index} "/usr/lpp/mmfs/bin/mmmount all_local"
pids="${pids} $!"
sleep 0.1
for pid in ${pids}; do
    wait ${pid} || let "failure=1"
done
if [[ "${failure}" == "1" ]]; then
    echo -e "${Red} Failed to Exec on one of the managers ${Color_Off}"
    exit 1
fi

echo -e "${Yellow} Setup sensors and collectors to gather monitoring metrics... ${Color_Off}"
k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmchnode --perfmon -N ${POD_NAME}"
if [[ "$?" -ne 0 ]]; then exit 1; fi

k8s-exec gpfs-cli$index "systemctl start pmsensors; systemctl stop pmsensors; systemctl start pmsensors"
if [[ "$?" -ne 0 ]]; then exit 1; fi
k8s-exec gpfs-cli$index "systemctl start pmcollector"
if [[ "$?" -ne 0 ]]; then exit 1; fi

PROMETHEUS_FILE="prometheus.yaml"
if [ -f "$PROMETHEUS_FILE" ]; then
  echo -e "${Yellow} Setup Prometheus and Grafana monitoring for client node... ${Color_Off}"
  k8s-exec gpfs-cli$index "systemctl daemon-reload && systemctl start gpfs_exporter"
  if [[ "$?" -ne 0 ]]; then exit 1; fi
fi

sleep 10

if command -v oc &> /dev/null; then
  oc -n $NAMESPACE rsh $(oc -n $NAMESPACE get po -lapp=gpfs-mgr1 -ojsonpath="{.items[0].metadata.name}") /usr/lpp/mmfs/bin/mmhealth cluster show
else
  k8s-exec gpfs-mgr1 "/usr/lpp/mmfs/bin/mmhealth cluster show"
fi

echo -e "${Yellow} Starting StoRM-WebDAV service on client node... ${Color_Off}"
k8s-exec gpfs-cli$index "su - storm -c \"cp /tmp/.storm-webdav/certs/private.key /etc/grid-security/storm-webdav/hostkey.pem\""
if [[ "$?" -ne 0 ]]; then exit 1; fi
k8s-exec gpfs-cli$index "su - storm -c \"cp /tmp/.storm-webdav/certs/public.crt /etc/grid-security/storm-webdav/hostcert.pem\""
if [[ "$?" -ne 0 ]]; then exit 1; fi
k8s-exec gpfs-cli$index "su - storm -c \"cd /etc/storm/webdav && /usr/bin/java \$STORM_WEBDAV_JVM_OPTS -Djava.io.tmpdir=\$STORM_WEBDAV_TMPDIR \
-Dspring.profiles.active=\$STORM_WEBDAV_PROFILE -Dlogging.config=\$STORM_WEBDAV_LOG_CONFIGURATION -jar \$STORM_WEBDAV_JAR \
> \$STORM_WEBDAV_OUT 2>\$STORM_WEBDAV_ERR\" &"
if [[ "$?" -ne 0 ]]; then exit 1; fi

# @todo add error handling
echo -e "${Green} Exec went OK for all the Pods ${Color_Off}"

# print configuration summary
echo ""
echo "NAMESPACE=$NAMESPACE"
echo "CC_IMAGE_REPO=$CC_IMAGE_REPO"
echo "CC_IMAGE_TAG=$CC_IMAGE_TAG"
echo "TIMEOUT=$TIMEOUT"
echo "VERSION=$VERSION"
