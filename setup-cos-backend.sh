#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 5 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <namespace> <cluster> <s3-endpoint> <s3-access-key> <s3-secret-key>"
    exit 1
fi

NAMESPACE=$1
CLUSTER=$2
S3_ENDPOINT=$3
S3_ACCESS_KEY=$4
S3_SECRET_KEY=$5

MGR=$(kubectl \
  -n $NAMESPACE \
  get po \
  --selector app=gpfs-mgr1,cluster=$CLUSTER \
  -ojsonpath='{.items[*].metadata.name}')

CLUSTERNAME=$(kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "cat /var/mmfs/ssl/id_rsa.pub" | grep clusterName | awk -F'=' '{print $2}')

FSNAME=$(kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmlsfs all_local -T | grep attributes | awk -F\"/\" \"{print \\\$3}\" | sed \"s/://g\"")

kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmchnode --gateway -N "$MGR

kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "microdnf install -y fswatch rsync"

kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "nohup sh -c \"/usr/bin/fswatch -o /ibm/${FSNAME} | /usr/bin/xargs -n1 -I{} /usr/bin/rsync -a /ibm/${FSNAME}/ /ibm/${FSNAME}-dual\" > /tmp/fswatch.log 2>&1 & disown"

kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmafmcoskeys inference-switch:${S3_ENDPOINT} set ${S3_ACCESS_KEY} ${S3_SECRET_KEY}"

kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmafmcosconfig ${FSNAME} root --endpoint https://${S3_ENDPOINT} --new-bucket inference-switch --object-fs --mode mu --xattr --convert --acls --directory-object"

kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmlsfileset ${FSNAME} --afm -L"

kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmafmctl ${FSNAME} getstate"