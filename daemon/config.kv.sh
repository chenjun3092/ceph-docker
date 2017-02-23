#!/bin/bash
set -e

sed -r "s/@CLUSTER@/${CLUSTER:-ceph}/g" \
    /etc/confd/conf.d/ceph.conf.toml.in > /etc/confd/conf.d/ceph.conf.toml

# make sure etcd uses http or https as a prefix
if [[ "$KV_TYPE" == "etcd" ]]; then
  if [ ! -z "${KV_CA_CERT}" ]; then
  	CONFD_NODE_SCHEMA="https://"
  else
    CONFD_NODE_SCHEMA="http://"
  fi
fi

function get_admin_key {
   kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} get ${CLUSTER_PATH}/adminKeyring > /etc/ceph/${CLUSTER}.client.admin.keyring
}


function get_mon_config {

  CLUSTER_PATH=ceph-config/${CLUSTER}

  # making sure the root dirs are present for the confd to work with etcd
  if [[ "$KV_TYPE" == "etcd" ]]; then
    for dir in auth global mon mds osd client; do
      etcdctl mkdir ${CLUSTER_PATH}/$dir > /dev/null 2>&1  || log "'$dir' key already exists"
    done
  fi

  log "Adding Mon Host - ${MON_NAME}"
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/mon_host/${MON_NAME} ${MON_IP} > /dev/null 2>&1

  # Acquire lock to not run into race conditions with parallel bootstraps
  until kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} cas ${CLUSTER_PATH}/lock $MON_NAME > /dev/null 2>&1 ; do
    log "Configuration is locked by another host. Waiting."
    sleep 1
  done

  # Update config after initial mon creation
  if kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} get ${CLUSTER_PATH}/monSetupComplete > /dev/null 2>&1 ; then
    log "Configuration found for cluster ${CLUSTER}. Writing to disk."

    get_config

    log "Adding mon/admin Keyrings"
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} get ${CLUSTER_PATH}/monKeyring > /etc/ceph/${CLUSTER}.mon.keyring
    get_admin_key

    if [ ! -f /etc/ceph/monmap-${CLUSTER} ]; then
      log "Monmap is missing. Adding initial monmap..."
      kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} get ${CLUSTER_PATH}/monmap | uudecode -o /etc/ceph/monmap-${CLUSTER}
    fi

    log "Trying to get the most recent monmap..."
    if timeout 5 ceph ${CEPH_OPTS} mon getmap -o /etc/ceph/monmap-${CLUSTER}; then
      log "Monmap successfully retrieved.  Updating KV store."
      uuencode /etc/ceph/monmap-${CLUSTER} - | kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/monmap -
    else
      log "Peers not found, using initial monmap."
    fi

  else
    # Create initial Mon, keyring
    log "No configuration found for cluster ${CLUSTER}. Generating."

    local fsid=$(uuidgen)
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/auth/fsid ${fsid}

    until confd -onetime -backend ${KV_TYPE} -node ${CONFD_NODE_SCHEMA}${KV_IP}:${KV_PORT} ${CONFD_KV_TLS} -prefix="/${CLUSTER_PATH}/" ; do
      log "Waiting for confd to write initial templates..."
      sleep 1
    done

    log "Creating Keyrings"
    ceph-authtool /etc/ceph/${CLUSTER}.client.admin.keyring --create-keyring --gen-key -n client.admin --set-uid=0 --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow'
    ceph-authtool /etc/ceph/${CLUSTER}.mon.keyring --create-keyring --gen-key -n mon. --cap mon 'allow *'

    # Generate the OSD bootstrap key
    ceph-authtool /var/lib/ceph/bootstrap-osd/${CLUSTER}.keyring --create-keyring --gen-key -n client.bootstrap-osd --cap mon 'allow profile bootstrap-osd'

    # Generate the MDS bootstrap key
    ceph-authtool /var/lib/ceph/bootstrap-mds/${CLUSTER}.keyring --create-keyring --gen-key -n client.bootstrap-mds --cap mon 'allow profile bootstrap-mds'

    # Generate the RGW bootstrap key
    ceph-authtool /var/lib/ceph/bootstrap-rgw/${CLUSTER}.keyring --create-keyring --gen-key -n client.bootstrap-rgw --cap mon 'allow profile bootstrap-rgw'


    log "Creating Monmap"
    monmaptool --create --add ${MON_NAME} "${MON_IP}:6789" --fsid ${fsid} /etc/ceph/monmap-${CLUSTER}

    log "Importing Keyrings and Monmap to KV"
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/monKeyring - < /etc/ceph/${CLUSTER}.mon.keyring
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/adminKeyring - < /etc/ceph/${CLUSTER}.client.admin.keyring
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/bootstrapOsdKeyring - < /var/lib/ceph/bootstrap-osd/${CLUSTER}.keyring
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/bootstrapMdsKeyring - < /var/lib/ceph/bootstrap-mds/${CLUSTER}.keyring
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/bootstrapRgwKeyring - < /var/lib/ceph/bootstrap-rgw/${CLUSTER}.keyring

    uuencode /etc/ceph/monmap-${CLUSTER} - | kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/monmap -

    log "Completed initialization for ${MON_NAME}"
    kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} put ${CLUSTER_PATH}/monSetupComplete true > /dev/null 2>&1
  fi

  # Remove lock for other clients to install
  log "Removing lock for ${MON_NAME}"
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} del ${CLUSTER_PATH}/lock > /dev/null 2>&1

}

function get_config {

  CLUSTER_PATH=ceph-config/${CLUSTER}

  until kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} get ${CLUSTER_PATH}/monSetupComplete > /dev/null 2>&1 ; do
    log "OSD: Waiting for monitor setup to complete..."
    sleep 5
  done

  until confd -onetime -backend ${KV_TYPE} -node ${CONFD_NODE_SCHEMA}${KV_IP}:${KV_PORT} ${CONFD_KV_TLS} -prefix="/${CLUSTER_PATH}/" ; do
    log "Waiting for confd to update templates..."
    sleep 1
  done

  log "Adding bootstrap keyrings"
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} get ${CLUSTER_PATH}/bootstrapOsdKeyring > /var/lib/ceph/bootstrap-osd/${CLUSTER}.keyring
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} get ${CLUSTER_PATH}/bootstrapMdsKeyring > /var/lib/ceph/bootstrap-mds/${CLUSTER}.keyring
  kviator --kvstore=${KV_TYPE} --client=${KV_IP}:${KV_PORT} ${KV_TLS} get ${CLUSTER_PATH}/bootstrapRgwKeyring > /var/lib/ceph/bootstrap-rgw/${CLUSTER}.keyring
}
