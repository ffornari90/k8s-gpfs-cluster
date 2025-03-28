#!/bin/bash
# **************************************************************************** #
#                                  Entrypoint                                  #
# **************************************************************************** #

if [ "$#" -lt 7 ]; then
    echo "ERROR: Illegal number of parameters. Syntax: $0 <namespace> <cluster> <fileset> <s3-endpoint> <s3-bucket> <s3-access-key> <s3-secret-key>"
    exit 1
fi

NAMESPACE=$1
CLUSTER=$2
FILESET=$3
S3_ENDPOINT=$4
S3_BUCKET=$5
S3_ACCESS_KEY=$6
S3_SECRET_KEY=$7

MGR=$(kubectl \
  -n $NAMESPACE \
  get po \
  --selector app=gpfs-mgr1,cluster=$CLUSTER \
  -ojsonpath='{.items[*].metadata.name}')

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
  "/usr/lpp/mmfs/bin/mmafmcoskeys ${S3_BUCKET}:${S3_ENDPOINT} set ${S3_ACCESS_KEY} ${S3_SECRET_KEY}"

kubectl \
  -n $NAMESPACE \
  exec -t \
  $MGR \
  -- \
  bash -c \
  "/usr/lpp/mmfs/bin/mmafmcosconfig ${FSNAME} ${FILESET} --endpoint https://${S3_ENDPOINT} --new-bucket ${S3_BUCKET} --object-fs --mode sw --xattr --cleanup --acls --directory-object"

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