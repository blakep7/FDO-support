#!/bin/bash

# Used *inside* the sdo-owner-services container to start all of the SDO services the Horizon management hub (IoT platform/owner) needs.

# Defaults/constants
opsPortDefault='8042'
rvPortDefault='8040'
ocsApiPortDefault='9008'

# These can be passed in via CLI args or env vars
ocsDbDir="${1:-$SDO_OCS_DB_PATH}"
ocsApiPort="${2:-${SDO_OCS_API_PORT:-$ocsApiPortDefault}}"

opsPort=${SDO_OPS_PORT:-$opsPortDefault}
rvPort=${SDO_RV_PORT:-$rvPortDefault}

if [[ "$1" == "-h" || "$1" == "--help" || -z "$SDO_OCS_DB_PATH" || -z "$SDO_OCS_API_PORT" ]]; then
    cat << EndOfMessage
Usage: ${0##*/} [<ocs-db-path>] [<ocs-api-port>]
Environment variables that can be used instead of CLI args: SDO_OCS_DB_PATH, SDO_OCS_API_PORT
Required environment variables: HZN_EXCHANGE_URL, HZN_FSS_CSSURL, HZN_ORG_ID
Recommended environment variables: HZN_MGMT_HUB_CERT (unless the mgmt hub uses http or a CA-trusted certificate)
EndOfMessage
    exit 1
fi

# These env vars are needed by ocs-api to set up the common config files for ocs
if [[ -z "$HZN_EXCHANGE_URL" || -z "$HZN_FSS_CSSURL" || -z "$HZN_ORG_ID" || -z "$SDO_OWNER_SVC_HOST" ]]; then
    echo "Error: all of these environment variables must be set: HZN_EXCHANGE_URL, HZN_FSS_CSSURL, HZN_ORG_ID, SDO_OWNER_SVC_HOST"
fi

echo "Using ports: RV: $rvPort, OPS: $opsPort, OCS-API: $ocsApiPort"

# So to0scheduler will point RV (and by extension, the device) to the correct OPS host. Can be a hostname or IP address
if [[ $SDO_OWNER_SVC_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # IP address
    sed -i -e "s/^com.intel.sdo.to0.ownersign.to1d.bo.i1=.*$/com.intel.sdo.to0.ownersign.to1d.bo.i1=$SDO_OWNER_SVC_HOST/" -e "s/^com.intel.sdo.to0.ownersign.to1d.bo.dns1=.*$/com.intel.sdo.to0.ownersign.to1d.bo.dns1=/" to0scheduler/config/application.properties
else
    # hostname
    sed -i -e "s/^com.intel.sdo.to0.ownersign.to1d.bo.dns1=.*$/com.intel.sdo.to0.ownersign.to1d.bo.dns1=$SDO_OWNER_SVC_HOST/" to0scheduler/config/application.properties
fi

# If using a non-default port number for OPS, configure both ops and to0scheduler with that value
if [[ "$opsPort" != "$opsPortDefault" ]]; then
    sed -i -e "s/^server.port=.*$/server.port=$opsPort/" ops/config/application.properties
    sed -i -e "s/^com.intel.sdo.to0.ownersign.to1d.bo.port1=.*$/com.intel.sdo.to0.ownersign.to1d.bo.port1=$opsPort/" to0scheduler/config/application.properties
fi

# If using a non-default port number for RV, configure RV with that value
if [[ "$rvPort" != "$rvPortDefault" ]]; then
    sed -i -e "s/^server.port=.*$/server.port=$rvPort/" rv/application.properties
fi

# This sed is for dev/test/demo and makes the to0scheduler respond to changes more quickly, and let us use the same voucher over again
sed -i -e 's/^to0.scheduler.interval=.*$/to0.scheduler.interval=5/' -e 's/^to2.credential-reuse.enabled=.*$/to2.credential-reuse.enabled=true/' ocs/config/application.properties

# Need to move this file into the ocs db *after* the docker run mount is done
# If the user specified their own owner private key, run-sdo-owner-services.sh will mount it at ocs/config/owner-keystore.p12, otherwise use the default
mkdir -p $ocsDbDir/v1/creds
if [[ -f 'ocs/config/owner-keystore.p12' ]]; then
    cp ocs/config/owner-keystore.p12 $ocsDbDir/v1/creds   # need to copy it, because can't move a mounted file
else
    # Use the default key file that Dockerfile stored, ocs/config/sample-owner-keystore.p12, but name it owner-keystore.p12
    mv ocs/config/sample-owner-keystore.p12 $ocsDbDir/v1/creds/owner-keystore.p12
fi

# Run all of the services
echo "Starting rendezvous service..."
(cd rv && ./rendezvous) &
echo "Starting to0scheduler service..."
(cd to0scheduler/config && ./run-to0scheduler) &
echo "Starting ocs service..."
(cd ocs/config && ./run-ocs) &
echo "Starting ops service..."
(cd ops/config && ./run-ops) &
echo "Starting ocs-api service..."
${0%/*}/ocs-api $ocsApiPort $ocsDbDir  # run this in the foreground so the start cmd doesn't end
