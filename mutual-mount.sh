#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 4 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <owning-namespace> <owning-cluster> <accessing-namespace> <accessing-cluster>"
    exit 1
fi

OWNING_NAMESPACE=$1
OWNING_CLUSTER=$2
ACCESSING_NAMESPACE=$3
ACCESSING_CLUSTER=$4

OWNING_MGR=$(kubectl \
  -n $OWNING_NAMESPACE \
  get po \
  --selector app=gpfs-mgr1,cluster=$OWNING_CLUSTER \
  -ojsonpath='{.items[*].metadata.name}')

ACCESSING_MGR=$(kubectl \
  -n $ACCESSING_NAMESPACE \
  get po \
  --selector app=gpfs-mgr1,cluster=$ACCESSING_CLUSTER \
  -ojsonpath='{.items[*].metadata.name}')

OWNING_CLUSTERNAME=$(kubectl \
  -n $OWNING_NAMESPACE \
  exec -t \
  $OWNING_MGR \
  -- \
  bash -c \
  "cat /var/mmfs/ssl/id_rsa.pub" | grep clusterName | awk -F'=' '{print $2}')

ACCESSING_CLUSTERNAME=$(kubectl \
  -n $ACCESSING_NAMESPACE \
  exec -t \
  $ACCESSING_MGR \
  -- \
  bash -c \
  "cat /var/mmfs/ssl/id_rsa.pub" | grep clusterName | awk -F'=' '{print $2}')

OWNING_FSNAME=$(kubectl \
  -n $OWNING_NAMESPACE \
  exec -t \
  $OWNING_MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmlsfs all_local -T | grep attributes | awk -F\"/\" \"{print \\\$3}\" | sed \"s/://g\"")

ACCESSING_FSNAME=$(kubectl \
  -n $ACCESSING_NAMESPACE \
  exec -t \
  $ACCESSING_MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmlsfs all_local -T | grep attributes | awk -F\"/\" \"{print \\\$3}\" | sed \"s/://g\"")

if ! [ -f "${OWNING_CLUSTERNAME}_id_rsa.pub" ]; then
  # SSH KEY generation for OWNING
  kubectl \
    -n $OWNING_NAMESPACE \
    exec -t \
    $OWNING_MGR \
    -- \
    bash -c \
    "/usr/lpp/mmfs/bin/mmauth genkey new"

  kubectl \
    -n $OWNING_NAMESPACE \
    exec -t \
    $OWNING_MGR \
    -- \
    bash -c \
    "/usr/lpp/mmfs/bin/mmauth update . -l AUTHONLY"

  # OWNING SSH KEY copy from Pod to local folder
  kubectl \
    -n $OWNING_NAMESPACE \
    cp $OWNING_MGR:/var/mmfs/ssl/id_rsa_new.pub \
    "${OWNING_CLUSTERNAME}_id_rsa.pub"
fi

if ! [ -f "${ACCESSING_CLUSTERNAME}_id_rsa.pub" ]; then
  # SSH KEY generation for ACCESSING
  kubectl \
    -n $ACCESSING_NAMESPACE \
    exec -t \
    $ACCESSING_MGR \
    -- \
    bash -c \
    "/usr/lpp/mmfs/bin/mmauth genkey new"

  kubectl \
    -n $ACCESSING_NAMESPACE \
    exec -t \
    $ACCESSING_MGR \
    -- \
    bash -c \
    "/usr/lpp/mmfs/bin/mmauth update . -l AUTHONLY"

  # ACCESSING SSH KEY copy from Pod to local folder
  kubectl \
    -n $ACCESSING_NAMESPACE \
    cp $ACCESSING_MGR:/var/mmfs/ssl/id_rsa_new.pub \
    "${ACCESSING_CLUSTERNAME}_id_rsa.pub"
fi

# Copy ACCESSING SSH KEY from local folder to OWNING manager
kubectl \
  -n $OWNING_NAMESPACE \
  cp "${ACCESSING_CLUSTERNAME}_id_rsa.pub" \
  $OWNING_MGR:/root/"${ACCESSING_CLUSTERNAME}_id_rsa.pub"

# Copy OWNING SSH KEY from local folder to ACCESSING manager
kubectl \
  -n $ACCESSING_NAMESPACE \
  cp "${OWNING_CLUSTERNAME}_id_rsa.pub" \
  $ACCESSING_MGR:/root/"${OWNING_CLUSTERNAME}_id_rsa.pub"

# Add ACCESSING SSH KEY on OWNING cluster
kubectl \
  -n $OWNING_NAMESPACE \
  exec -t \
  $OWNING_MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmauth add ${ACCESSING_CLUSTERNAME} -k /root/${ACCESSING_CLUSTERNAME}_id_rsa.pub"
  
# Setup authorization for ACCESSING cluster on OWNING manager
kubectl \
  -n $OWNING_NAMESPACE \
  exec -t \
  $OWNING_MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmauth grant ${ACCESSING_CLUSTERNAME} -f ${OWNING_FSNAME}"

# Setup mutual resolution between ACCESSING and OWNING clusters
own_pods=(`kubectl \
  -n $OWNING_NAMESPACE \
  get pod \
  -l cluster=$OWNING_CLUSTER \
  -ojsonpath="{.items[*].metadata.name}"`)

own_svcs=(`kubectl \
  -n $OWNING_NAMESPACE \
  get pod \
  -l cluster=$OWNING_CLUSTER \
  -ojsonpath="{.items[*].status.podIP}"`)

own_size=`expr "${#own_pods[@]}" - 1`

access_pods=(`kubectl \
  -n $ACCESSING_NAMESPACE \
  get pod \
  -l cluster=$ACCESSING_CLUSTER \
  -ojsonpath="{.items[*].metadata.name}"`)

access_svcs=(`kubectl \
  -n $ACCESSING_NAMESPACE \
  get pod \
  -l cluster=$ACCESSING_CLUSTER \
  -ojsonpath="{.items[*].status.podIP}"`)

access_size=`expr "${#access_pods[@]}" - 1`

for i in $(seq 0 $own_size)
do
  printf '%s %s\n' \
  "${own_svcs[$i]}" \
  "${own_pods[$i]}" \
  | tee -a hosts.tmp
done

for i in $(seq 0 $access_size)
do
  printf '%s %s\n' \
  "${access_svcs[$i]}" \
  "${access_pods[$i]}" \
  | tee -a hosts.tmp
done

for pod in ${access_pods[@]}
do
  kubectl \
  cp hosts.tmp \
  $ACCESSING_NAMESPACE/$pod:/tmp/hosts.tmp

  kubectl \
  -n $ACCESSING_NAMESPACE \
  exec -t \
  $pod \
  -- \
  bash -c \
  "cp /etc/hosts hosts.tmp; sed -i \"$ d\" hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp"

  kubectl \
  -n $ACCESSING_NAMESPACE \
  exec -t \
  $pod \
  -- \
  bash -c \
  'cat /tmp/hosts.tmp >> /etc/hosts'

  kubectl \
  -n $ACCESSING_NAMESPACE \
  exec -t \
  $pod \
  -- \
  bash -c \
  'sort /etc/hosts | uniq > hosts.tmp; yes | cp hosts.tmp /etc/hosts; rm -f hosts.tmp'
done
rm -f hosts.tmp

# Add OWNING cluster as remote cluster on ACCESSING manager  
kubectl \
  -n $ACCESSING_NAMESPACE \
  exec -t \
  $ACCESSING_MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmremotecluster add ${OWNING_CLUSTERNAME} -n ${OWNING_MGR} -k /root/${OWNING_CLUSTERNAME}_id_rsa.pub"
  
# Add OWNING FS as remote FS on ACCESSING manager
kubectl \
  -n $ACCESSING_NAMESPACE \
  exec -t \
  $ACCESSING_MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmremotefs add ${ACCESSING_FSNAME}-dual -f ${OWNING_FSNAME} -C ${OWNING_CLUSTERNAME} -T /ibm/${ACCESSING_FSNAME}-dual"

# Mount OWNING FS on ACCESSING manager
kubectl \
  -n $ACCESSING_NAMESPACE \
  exec -t \
  $ACCESSING_MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmmount ${ACCESSING_FSNAME}-dual"