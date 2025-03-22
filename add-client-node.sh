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
    echo "Usage: $0 [-N <k8s_namespace>] [-b <cc_image_repo>] [-i <cc_image_tag>] [-p <oidc_provider>] [-c <iam_ca_file>] [-t <timeout>] [-v <gpfs_version>]"
    echo
    echo "-N    Specify the kubernetes Namespace on which the cluster resides (default is 'ns\$(date +%s)')"
    echo "      It must be a compliant DNS-1123 label and match =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
    echo "      In practice, must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character"
    echo "-a    Specify ingress controller IP address (default is 192.168.0.1)"
    echo "-b    Specify docker image repository to be used for node creation (default is $CC_IMAGE_REPO)"
    echo "-C    Specify the name of the GPFS cluster to be deployed (default is 'gpfs\$(date +%s)')"
    echo "-d    Specify domain name to be used for StoRM-WebDAV service (default is example.com)"
    echo "-i    Specify docker image tag to be used for node creation (default is $CC_IMAGE_TAG)"
    echo "-p    Specify an OIDC provider for StoRM-WebDAV authentication (default is iam.example.com)"
    echo "-c    Specify a CA certificate to be used for OIDC provider (default is none)"
    echo "-k    Specify SSH key path for cluster creation (default is ~/.ssh/id_rsa)"
    echo "-j    Specify jump host for cluster creation (default is jumphost)"
    echo "-m    Specify cluster issuer name to be used for StoRM-WebDAV certificate request (default is clusterissuer)"
    echo "-t    Specify desired timeout for node creation in seconds (default is 3600)"
    echo "-u    Specify user to perform cluster creation (default is core)"
    echo "-v    Specify desired GPFS version for node creation (default is 5.1.8-2)"
    echo
    echo "-h    Show usage and exit"
    echo
}

function gen_role () {
    local role=$1
    local fs_name=$2
    local iam_ca=false
    local iam_ca_file=$3

    [ $with_iam_ca == true ] && iam_ca=true

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
    sed -i "s/%%%CLUSTER_NAME%%%/${CLUSTER_NAME}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%USER%%%/${USER}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%NUMBER%%%/${index}/g" "gpfs-${role}${index}.yaml"
    sed -i "s|%%%IMAGE_REPO%%%|${image_repo}|g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%IMAGE_TAG%%%/${image_tag}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%FS_NAME%%%/${fs_name}/g" "gpfs-${role}${index}.yaml"
    workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="true" -o=jsonpath='{range .items[1:]}{.metadata.name}{"\n"}{end}'`)
    RANDOM=$$$(date +%s)
    selected_worker=${workers[ $RANDOM % ${#workers[@]} ]}
    CIDR="$(calicoctl ipam check | grep host:${selected_worker}: | awk '{print $3}')"
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
        ip_index=$((1 + $RANDOM % ${#IP_LIST[@]}))
        if [ -n "${IP_LIST[ip_index-1]}" ]; then
            pod_ip="${IP_LIST[ip_index-1]//[\(\)]/}"
            break
        fi
    done
    sed -i "s/%%%NODENAME%%%/${selected_worker}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%PODNAME%%%/${CLUSTER_NAME}-${role}-${index}/g" "gpfs-${role}${index}.yaml"
    sed -i "s/%%%POD_IP%%%/${pod_ip}/g" "gpfs-${role}${index}.yaml"
    if [[ $iam_ca == true ]] && [[ $role == "cli" ]]; then
        cp "$TEMPLATES_DIR/pv-patch.template.yaml" "pv-patch-${index}.yaml"
        sed -i "s/%%%IAM_CA%%%/${iam_ca_file}/g" "pv-patch-${index}.yaml"
        csplit --quiet --prefix=tmp --digit=2 "gpfs-${role}${index}.yaml" "/### DEPLOYMENT ###/+1" "{*}"
        kubectl patch --local=true -f tmp01 --patch "$(cat pv-patch-${index}.yaml)" -o yaml > tmp02
        cat tmp00 tmp02 > "gpfs-${role}${index}.yaml"
        rm -f tmp00 tmp01 tmp02
    fi
}

function k8s-exec() {

    local namespace=$NAMESPACE
    local app=$1
    local cluster=$2
    [[ $3 ]] && local k8cmd=${@:3}

    kubectl exec --namespace=$namespace $(kubectl get pods --namespace=$namespace --selector app=$app,cluster=$cluster | grep -E '([0-9]+)/\1' | awk '{print $1}') -- /bin/bash -c "$k8cmd"

}


function k8s-exec-bkg() {

    local namespace=$NAMESPACE
    local app=$1
    local cluster=$2
    shift
    local k8cmd="$@"
    local pod_name=$(kubectl get pods --namespace=$namespace --selector app=$app,cluster=$cluster | grep -E '([0-9]+)/\1' | awk '{print $1}')

    kubectl exec --namespace=$namespace $pod_name -- /bin/bash -c "nohup $k8cmd > /dev/null 2>&1 & disown"
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
CC_IMAGE_REPO="ffornari/gpfs-storm-webdav"
CC_IMAGE_TAG="rhel8"
HOST_COUNT=0
TIMEOUT=3600
JUMPHOST="jumphost"
SSH_KEY="~/.ssh/id_rsa"
USER="core"
VERSION=5.1.8-2
workers=(`kubectl get nodes -lnode-role.kubernetes.io/worker="true" -ojsonpath="{.items[*].metadata.name}"`)
WORKER_COUNT="${#workers[@]}"
with_iam_ca=false
IAM_CA_FILE=""
OIDC_PROVIDER="iam.example.com"
DOMAIN="example.com"
CONTROLLER_IP="192.168.0.1"
CLUSTER_ISSUER="clusterissuer"

while getopts 'N:C:a:b:d:i:p:c:k:j:m:t:u:v:h' opt; do
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
        a) # ingress controller ip address must consist of 4 sequences of numeric characters separated by dots
            if [[ $OPTARG =~ ^[0-9]+.[0-9]+.[0-9]+.[0-9]+$ ]];
                then CONTROLLER_IP=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        b)
            CC_IMAGE_REPO=${OPTARG} ;;
        d)
            if [[ $OPTARG =~ ^[[:alnum:]][[:alnum:].-]*[[:alnum:]]$ ]];
                then DOMAIN=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        i)
            CC_IMAGE_TAG=${OPTARG} ;;
        p)
            if [[ $OPTARG =~ ^[[:alnum:]][[:alnum:].-]*[[:alnum:]]$ ]];
                then OIDC_PROVIDER=${OPTARG}
                else echo "! Wrong arg -$opt"; exit 1
            fi ;;
        c)
            if [[ -f ${OPTARG} ]]; then
                IAM_CA_FILE=${OPTARG}
            else
                echo "! Wrong arg -$opt"; exit 1
            fi
            with_iam_ca=true ;;
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
        m) # a DNS-1123 label must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character
            if [[ $OPTARG =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]];
                then CLUSTER_ISSUER=${OPTARG}
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
echo "TIMEOUT=$TIMEOUT"
echo "VERSION=$VERSION"
echo "with_iam_ca=$with_iam_ca"
echo "IAM_CA_FILE=$IAM_CA_FILE"
echo "OIDC_PROVIDER=$OIDC_PROVIDER"
echo "USER=$USER"
echo "SSH_KEY=$SSH_KEY"
echo "JUMPHOST=$JUMPHOST"
echo "DOMAIN=$DOMAIN"
echo "CONTROLLER_IP=$CONTROLLER_IP"
echo "CLUSTER_ISSUER=$CLUSTER_ISSUER"

# **********************************************************************************************
# Generation of the K8s manifests and configuration scripts for a complete namespaced instance #
# **********************************************************************************************

TEMPLATES_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/templates" # one-liner that gives the full directory name of the script no matter where it is being called from.
GPFS_INSTANCE_DIR="gpfs-instance-$CLUSTER_NAME"
if [ ! -d $GPFS_INSTANCE_DIR ]; then
  echo "k8s namespace $NAMESPACE does not exist. Exit."
  exit 1
fi
cd $GPFS_INSTANCE_DIR
FS_NAME=$(k8s-exec mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmlsfs all_local -T | grep attributes | awk -F\"/\" \"{print \\\$3}\" | sed \"s/://g\"")

if [ $with_iam_ca == true ]; then
  if ! kubectl get secret iam-ca -n $NAMESPACE &> /dev/null; then
    kubectl create secret generic iam-ca \
     -n $NAMESPACE \
     --from-file=../${IAM_CA_FILE}
  fi
fi

# Generate the manager manifests
gen_role cli $FS_NAME $IAM_CA_FILE
index=$(ls | grep -o 'cli[0-9]\+' | cut -c4- | tail -1)
printf '\n'

REDIRECT_URI="https://storm-webdav.$DOMAIN/login/oauth2/code/iam-indigo"

# Generate the services
cp "$TEMPLATES_DIR/hosts.template" "hosts"
cp "$TEMPLATES_DIR/gpfs-cli-svc.template.yaml" "cli-svc${index}.yaml"
cp "$TEMPLATES_DIR/storm-webdav-svc.template.yaml" "storm-webdav-svc.yaml"
cp "$TEMPLATES_DIR/storm-webdav-ingress.template.yaml" "storm-webdav-ingress.yaml"
cp "$TEMPLATES_DIR/storm-webdav-configmap.template.yaml" "storm-webdav-configmap.yaml"
cp "$TEMPLATES_DIR/client-req.template.json" "client-req${index}.json"
sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "cli-svc${index}.yaml"
sed -i "s/%%%NUMBER%%%/${index}/g" "cli-svc${index}.yaml"
sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "storm-webdav-svc.yaml"
sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "storm-webdav-configmap.yaml"
sed -i "s/%%%CLUSTER_NAME%%%/$CLUSTER_NAME/g" "storm-webdav-configmap.yaml"
sed -i "s/%%%FS_NAME%%%/$FS_NAME/g" "storm-webdav-configmap.yaml"
sed -i "s/%%%OIDC_PROVIDER%%%/$OIDC_PROVIDER/g" "storm-webdav-configmap.yaml"
sed -i "s#%%%REDIRECT_URI%%%#$REDIRECT_URI#g" "client-req${index}.json"
sed -i "s/%%%NAMESPACE%%%/$NAMESPACE/g" "storm-webdav-ingress.yaml"
sed -i "s/%%%DOMAIN%%%/$DOMAIN/g" "storm-webdav-ingress.yaml"
sed -i "s/%%%CONTROLLER_IP%%%/$CONTROLLER_IP/g" "storm-webdav-ingress.yaml"
sed -i "s/%%%CLUSTER_ISSUER%%%/$CLUSTER_ISSUER/g" "storm-webdav-ingress.yaml"
sed -i "s/%%%NUMBER%%%/${index}/g" "storm-webdav-ingress.yaml"

curl -H "Content-Type: application/json" -d "@client-req${index}.json" -X POST \
 -sk https://${OIDC_PROVIDER}/iam/api/client-registration > "client${index}.json"

OIDC_CLIENT_ID=$(jq -r '.client_id' "client${index}.json")
OIDC_CLIENT_SECRET=$(jq -r '.client_secret' "client${index}.json")

sed -i "s/%%%OIDC_CLIENT_ID%%%/$OIDC_CLIENT_ID/g" "storm-webdav-configmap.yaml"
sed -i "s/%%%OIDC_CLIENT_SECRET%%%/$OIDC_CLIENT_SECRET/g" "storm-webdav-configmap.yaml"

# **********************************************************************************************
# Deploy the instance #
# **********************************************************************************************

shopt -s nullglob # The shopt -s nullglob will make the glob expand to nothing if there are no matches.
roles_yaml=("gpfs-*.yaml")

# Instantiate the services
kubectl apply -f "storm-webdav-ingress.yaml"
kubectl apply -f "storm-webdav-configmap.yaml"
kubectl apply -f "cli-svc${index}.yaml"
kubectl apply -f "storm-webdav-svc.yaml"

mkdir -p "certs"
CAROOT=/etc/grid-security/certificates/ \
mkcert -install -cert-file ./certs/tls.crt \
-key-file ./certs/tls.key storm-webdav.$DOMAIN

if ! kubectl get secret tls-ssl-storm-webdav -n $NAMESPACE &> /dev/null; then
  kubectl create secret generic \
   tls-ssl-storm-webdav \
   -n $NAMESPACE \
   --from-file=./certs/tls.key \
   --from-file=./certs/tls.crt
fi

# Conditionally split the pod creation in groups, since apparently the external provisioner (manila?) can't deal with too many volume-creation request per second
g=1
count=1
CLI_FILE="./gpfs-cli${index}.yaml"
HOST_NAME=$(cat $CLI_FILE | grep nodeName | awk '{print $2}')
HOST_IP=$(kubectl get nodes ${HOST_NAME} -ojsonpath='{.status.addresses[0].address}')
POD_NAME="$(cat $CLI_FILE | grep -m1 name | awk '{print $2}')-0"
for ((i=0; i < ${#roles_yaml[@]}; i+=g)); do
    scp -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" hosts "${USER}"@"${HOST_IP}": > /dev/null 2>&1
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IP}" -l "${USER}" "sudo su - -c \"mkdir -p /root/cli${index}-$CLUSTER_NAME/var_mmfs\""
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IP}" -l "${USER}" "sudo su - -c \"mkdir -p /root/cli${index}-$CLUSTER_NAME/root_ssh\""
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IP}" -l "${USER}" "sudo su - -c \"mkdir -p /root/cli${index}-$CLUSTER_NAME/etc_ssh\""
    ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IP}" -l "${USER}" "sudo su - -c \"mv /home/$USER/hosts /root/cli${index}-$CLUSTER_NAME/\""

    for p in ${roles_yaml[@]:i:g}; do
        kubectl apply -f $p;
    done

    podsReady=$(kubectl get pods --namespace=$NAMESPACE --selector app=cli${index},cluster=$CLUSTER_NAME -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" |  wc -l)
    podsReadyExpected=$(( $((i+g))<${#roles_yaml[@]} ? $((i+g)) : ${#roles_yaml[@]} ))
    # [ tty ] && tput sc @todo
    while [[ $count -le 600 ]] && [[ "$podsReady" -lt "$podsReadyExpected" ]]; do
        podsReady=$(kubectl get pods --namespace=$NAMESPACE --selector app=cli${index},cluster=$CLUSTER_NAME -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" | wc -l)
        if [[ $(($count%10)) == 0 ]]; then
            # [ tty ] && tput rc @todo
            echo -e "\n${Yellow} Current situation of pods: ${Color_Off}"
            kubectl get pods --namespace=$NAMESPACE --selector app=cli${index},cluster=$CLUSTER_NAME
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
  kubectl -n $NAMESPACE exec -it $pod -- bash -c 'sort /etc/hosts | uniq > hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp'
done
rm -f hosts.tmp

echo -e "${Yellow} Distribute SSH keys on all the Pods... ${Color_Off}"

mgr_hosts=(`kubectl -n $NAMESPACE get pod --selector role=gpfs-mgr,cluster=$CLUSTER_NAME -ojsonpath="{.items[*].spec.nodeName}"`)
mgr_pods=(`kubectl -n $NAMESPACE get pod --selector role=gpfs-mgr,cluster=$CLUSTER_NAME -ojsonpath="{.items[*].metadata.name}"`)
cli_hosts=(`kubectl -n $NAMESPACE get pod --selector role=gpfs-cli,cluster=$CLUSTER_NAME -ojsonpath="{.items[*].spec.nodeName}"`)
cli_pods=(`kubectl -n $NAMESPACE get pod --selector role=gpfs-cli,cluster=$CLUSTER_NAME -ojsonpath="{.items[*].metadata.name}"`)

declare -a mgr_ips
for node in ${mgr_hosts[@]}
do
  mgr_ips+=("$(kubectl get node $node -ojsonpath='{.status.addresses[0].address}')")
done

declare -a cli_ips
for node in ${cli_hosts[@]}
do
  cli_ips+=("$(kubectl get node $node -ojsonpath='{.status.addresses[0].address}')")
done

for i in $(seq 1 ${#mgr_pods[@]})
do
  j=`expr $i - 1`
  ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IP}" -l "${USER}" \
  "echo \""$(kubectl -n $NAMESPACE exec -it ${mgr_pods[$j]} -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/cli$index-$CLUSTER_NAME/root_ssh/authorized_keys"
done

for i in $(seq 1 ${#cli_pods[@]})
do
  j=`expr $i - 1`
  ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${HOST_IP}" -l "${USER}" \
  "echo \""$(kubectl -n $NAMESPACE exec -it ${cli_pods[$j]} -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/cli$index-$CLUSTER_NAME/root_ssh/authorized_keys"
done

for i in $(seq 1 ${#mgr_ips[@]})
do
  j=`expr $i - 1`
  ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${mgr_ips[$j]}" -l "${USER}" \
  "echo \""$(kubectl -n $NAMESPACE exec -it ${POD_NAME} -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/mgr$i-$CLUSTER_NAME/root_ssh/authorized_keys"
done

for i in $(seq 1 ${#cli_ips[@]})
do
  j=`expr $i - 1`
  ssh -o "StrictHostKeyChecking=no" -i "${SSH_KEY}" -J "${JUMPHOST}" "${cli_ips[$j]}" -l "${USER}" \
  "echo \""$(kubectl -n $NAMESPACE exec -it ${POD_NAME} -- bash -c "cat /root/.ssh/id_rsa.pub")"\" | sudo tee -a /root/cli$i-$CLUSTER_NAME/root_ssh/authorized_keys"
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
k8s-exec mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmaddnode -N $POD_NAME:client"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Assign GPFS client licenses to node... ${Color_Off}"
k8s-exec mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmchlicense client --accept -N $POD_NAME"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Check GPFS cluster configuration... ${Color_Off}"
k8s-exec mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmlscluster"
if [[ "$?" -ne 0 ]]; then exit 1; fi

echo -e "${Yellow} Start GPFS daemon on client node... ${Color_Off}"
failure=0; pids="";
k8s-exec cli${index} ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmstartup"
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
node_states=(`k8s-exec mgr1 ${CLUSTER_NAME} '/usr/lpp/mmfs/bin/mmgetstate -a | grep gpfs | awk '"'"'{print \$3}'"'"`)
until check_active ${node_states[*]}
do
  node_states=(`k8s-exec mgr1 ${CLUSTER_NAME} '/usr/lpp/mmfs/bin/mmgetstate -a | grep gpfs | awk '"'"'{print \$3}'"'"`)
done

sleep 30
k8s-exec mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmgetstate -a"

echo -e "${Yellow} Mount GPFS file system on client node... ${Color_Off}"
failure=0; pids="";
k8s-exec cli${index} ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmmount all_local"
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
k8s-exec mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmchnode --perfmon -N ${POD_NAME}"
if [[ "$?" -ne 0 ]]; then exit 1; fi

k8s-exec cli${index} ${CLUSTER_NAME} "systemctl start pmsensors; systemctl stop pmsensors; systemctl start pmsensors"
if [[ "$?" -ne 0 ]]; then exit 1; fi
k8s-exec cli${index} ${CLUSTER_NAME} "systemctl start pmcollector"
if [[ "$?" -ne 0 ]]; then exit 1; fi

PROMETHEUS_FILE="prometheus.yaml"
if [ -f "$PROMETHEUS_FILE" ]; then
  echo -e "${Yellow} Setup Prometheus and Grafana monitoring for client node... ${Color_Off}"
  k8s-exec cli${index} ${CLUSTER_NAME} "systemctl daemon-reload && systemctl start gpfs_exporter"
  if [[ "$?" -ne 0 ]]; then exit 1; fi
fi

sleep 10

if command -v oc &> /dev/null; then
  oc -n $NAMESPACE rsh $(oc -n $NAMESPACE get po --selector app=mgr1,cluster=$CLUSTER_NAME -ojsonpath="{.items[0].metadata.name}") /usr/lpp/mmfs/bin/mmhealth cluster show
else
  k8s-exec mgr1 ${CLUSTER_NAME} "/usr/lpp/mmfs/bin/mmhealth cluster show"
fi

echo -e "${Yellow} Starting StoRM-WebDAV service on client node... ${Color_Off}"
k8s-exec cli${index} ${CLUSTER_NAME} "su - storm -c \"cp /tmp/.storm-webdav/certs/tls.key /etc/grid-security/storm-webdav/hostkey.pem\""
if [[ "$?" -ne 0 ]]; then exit 1; fi
k8s-exec cli${index} ${CLUSTER_NAME} "su - storm -c \"cp /tmp/.storm-webdav/certs/tls.crt /etc/grid-security/storm-webdav/hostcert.pem\""
if [[ "$?" -ne 0 ]]; then exit 1; fi
k8s-exec-bkg cli${index} ${CLUSTER_NAME} "su - storm -c \"cd /etc/storm/webdav && /usr/bin/java \$STORM_WEBDAV_JVM_OPTS -Djava.io.tmpdir=\$STORM_WEBDAV_TMPDIR \
-Dspring.profiles.active=\$STORM_WEBDAV_PROFILE -Dlogging.config=\$STORM_WEBDAV_LOG_CONFIGURATION -jar \$STORM_WEBDAV_JAR \
> \$STORM_WEBDAV_OUT 2>\$STORM_WEBDAV_ERR\""
if [[ "$?" -ne 0 ]]; then exit 1; fi

# @todo add error handling
echo -e "${Green} Exec went OK for all the Pods ${Color_Off}"

# print configuration summary
echo ""
echo "NAMESPACE=$NAMESPACE"
echo "CLUSTER_NAME=$CLUSTER_NAME"
echo "CC_IMAGE_REPO=$CC_IMAGE_REPO"
echo "CC_IMAGE_TAG=$CC_IMAGE_TAG"
echo "TIMEOUT=$TIMEOUT"
echo "VERSION=$VERSION"
echo "with_iam_ca=$with_iam_ca"
echo "IAM_CA_FILE=$IAM_CA_FILE"
echo "OIDC_PROVIDER=$OIDC_PROVIDER"
echo "USER=$USER"
echo "SSH_KEY=$SSH_KEY"
echo "JUMPHOST=$JUMPHOST"
echo "DOMAIN=$DOMAIN"
echo "CONTROLLER_IP=$CONTROLLER_IP"
echo "CLUSTER_ISSUER=$CLUSTER_ISSUER"
