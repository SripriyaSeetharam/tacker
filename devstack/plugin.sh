#!/bin/bash
#
# lib/tacker
# functions - functions specific to tacker

# Dependencies:
# ``functions`` file
# ``DEST`` must be defined
# ``STACK_USER`` must be defined

# ``stack.sh`` calls the entry points in this order:
#
# - create_tacker_accounts
# - install_tacker
# - install_tackerclient
# - configure_tacker
# - init_tacker
# - start_tacker_api

#
# ``unstack.sh`` calls the entry points in this order:
#
# - stop_tacker
# - cleanup_tacker

# Tacker SeviceVM
# ---------------

# Save trace setting
XTRACE=$(set +o | grep xtrace)
set +o xtrace

# Defaults
# --------

if is_ssl_enabled_service "tacker" || is_service_enabled tls-proxy; then
    TACKER_PROTOCOL="https"
fi

# Set up default directories
GITDIR["python-tackerclient"]=$DEST/python-tackerclient

TACKER_DIR=$DEST/tacker
TACKER_AUTH_CACHE_DIR=${TACKER_AUTH_CACHE_DIR:-/var/cache/tacker}

# Support entry points installation of console scripts
if [[ -d $TACKER_DIR/bin/tacker-server ]]; then
    TACKER_BIN_DIR=$TACKER_DIR/bin
else
    TACKER_BIN_DIR=$(get_python_exec_prefix)
fi

TACKER_CONF_DIR=/etc/tacker
TACKER_CONF=$TACKER_CONF_DIR/tacker.conf

# Default name for Tacker database
TACKER_DB_NAME=${TACKER_DB_NAME:-tacker}
# Default Tacker Port
TACKER_PORT=${TACKER_PORT:-8888}
# Default Tacker Internal Port when using TLS proxy
TACKER_PORT_INT=${TACKER_PORT_INT:-18888}	# TODO(FIX)
# Default Tacker Host
TACKER_HOST=${TACKER_HOST:-$SERVICE_HOST}
# Default protocol
TACKER_PROTOCOL=${TACKER_PROTOCOL:-$SERVICE_PROTOCOL}
# Default admin username
TACKER_ADMIN_USERNAME=${TACKER_ADMIN_USERNAME:-tacker}
# Default auth strategy
TACKER_AUTH_STRATEGY=${TACKER_AUTH_STRATEGY:-keystone}
TACKER_USE_ROOTWRAP=${TACKER_USE_ROOTWRAP:-True}

TACKER_RR_CONF_FILE=$TACKER_CONF_DIR/rootwrap.conf
if [[ "$TACKER_USE_ROOTWRAP" == "False" ]]; then
    TACKER_RR_COMMAND="sudo"
else
    TACKER_ROOTWRAP=$(get_rootwrap_location tacker)
    TACKER_RR_COMMAND="sudo $TACKER_ROOTWRAP $TACKER_RR_CONF_FILE"
fi

TACKER_NOVA_URL=${TACKER_NOVA_URL:-http://127.0.0.1:8774/v2}
TACKER_NOVA_CA_CERTIFICATES_FILE=${TACKER_NOVA_CA_CERTIFICATES_FILE:-}
TACKER_NOVA_API_INSECURE=${TACKER_NOVA_API_INSECURE:-False}

# Tell Tempest this project is present
# TEMPEST_SERVICES+=,tacker

# Functions
# ---------
# Test if any Tacker services are enabled
# is_tacker_enabled
function is_tacker_enabled {
    [[ ,${ENABLED_SERVICES} =~ ,"tacker" ]] && return 0
    return 1
}

# create_tacker_cache_dir() - Part of the _tacker_setup_keystone() process
function create_tacker_cache_dir {
    # Create cache dir
    sudo install -d -o $STACK_USER $TACKER_AUTH_CACHE_DIR
    rm -f $TACKER_AUTH_CACHE_DIR/*
}

# create_tacker_accounts() - Set up common required tacker accounts

# Tenant               User       Roles
# ------------------------------------------------------------------
# service              tacker    admin        # if enabled

# Migrated from keystone_data.sh
function create_tacker_accounts {
    if is_service_enabled tacker; then
	# openstack user create tacker --password service-password
	# openstack role add admin --user <uuid> --project service
        create_service_user "tacker"
	get_or_create_role "advsvc"
        create_service_user "tacker" "advsvc"

        if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then

	    # openstack service create servicevm --name tacker '--description=tacker Service'
            local tacker_service=$(get_or_create_service "tacker" \
                "servicevm" "Tacker Service")
	    # openstack endpoint create <uuid of service> --region RegionOne --publicurl 'http://143.183.96.146:8888/' --adminurl 'http://143.183.96.146:8888/' --internalurl 'http://143.183.96.146:8888/'
            get_or_create_endpoint $tacker_service \
                "$REGION_NAME" \
                "$TACKER_PROTOCOL://$SERVICE_HOST:$TACKER_PORT/" \
                "$TACKER_PROTOCOL://$SERVICE_HOST:$TACKER_PORT/" \
                "$TACKER_PROTOCOL://$SERVICE_HOST:$TACKER_PORT/"
        fi
    fi
}

# stack.sh entry points
# ---------------------

# init_tacker() - Initialize databases, etc.
function init_tacker {
    # mysql -uroot -pmysql-password -h143.183.96.146 -e 'DROP DATABASE IF EXISTS tacker;'
    # mysql -uroot -pmysql-password -h143.183.96.146 -e 'CREATE DATABASE tacker CHARACTER SET utf8;'
    recreate_database $TACKER_DB_NAME

    # Run Tacker db migrations
    $TACKER_BIN_DIR/tacker-db-manage --config-file $TACKER_CONF upgrade head
}

# install_tacker() - Collect source and prepare
function install_tacker {
    git_clone $TACKER_REPO $TACKER_DIR $TACKER_BRANCH
    setup_develop $TACKER_DIR
}

# install_tackerclient() - Collect source and prepare
function install_tackerclient {
    if use_library_from_git "python-tackerclient"; then
        git_clone_by_name "python-tackerclient"
        setup_dev_lib "python-tackerclient"
    fi
}

function start_tacker_api {
    local cfg_file_options="--config-file $TACKER_CONF"
    local service_port=$TACKER_PORT
    local service_protocol=$TACKER_PROTOCOL
    if is_service_enabled tls-proxy; then
        service_port=$TACKER_PORT_INT
        service_protocol="http"
    fi
    # Start the Tacker service
    run_process tacker "python $TACKER_BIN_DIR/tacker-server $cfg_file_options"
    echo "Waiting for Tacker to start..."
    if is_ssl_enabled_service "tacker"; then
        ssl_ca="--ca-certificate=${SSL_BUNDLE_FILE}"
    fi
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! wget ${ssl_ca} --no-proxy -q -O- $service_protocol://$TACKER_HOST:$service_port; do sleep 1; done"; then
        die $LINENO "Tacker did not start"
    fi
    # Start proxy if enabled
    if is_service_enabled tls-proxy; then
        start_tls_proxy '*' $TACKER_PORT $TACKER_HOST $TACKER_PORT_INT &
    fi
}

# TODO
# Start running processes, including screen
function start_tacker_agents {
    # TODO
    return

    # Start up the tacker agents if enabled
    run_process q-agt "python $AGENT_BINARY --config-file $TACKER_CONF"

    if is_service_enabled q-servicevm-agent; then
        screen_it q-servicevm "cd $TACKER_DIR && python $AGENT_SERVICEVM_BINARY --config-file $TACKER_CONF --config-file $SERVICEVM_CONF_FILENAME"
    fi
}

# stop_tacker() - Stop running processes (non-screen)
function stop_tacker {
    stop_process tacker-svc
    # stop_process q-agt
}

# cleanup_tacker() - Remove residual data files, anything left over from previous
# runs that a clean run would need to clean up
function cleanup_tacker {
    # do nothing for now
    :
}


function _create_tacker_conf_dir {
    # Put config files in ``TACKER_CONF_DIR`` for everyone to find
    sudo install -d -o $STACK_USER $TACKER_CONF_DIR
}

# configure_tacker()
# Set common config for all tacker server and agents.
function configure_tacker {
    _create_tacker_conf_dir
    iniset_rpc_backend tacker $TACKER_CONF

    cp $TACKER_DIR/etc/tacker/tacker.conf $TACKER_CONF

    # If needed, move config file from ``$TACKER_DIR/etc/tacker`` to ``TACKER_CONF_DIR``
    iniset $TACKER_CONF database connection `database_connection_url $TACKER_DB_NAME`
    iniset $TACKER_CONF DEFAULT state_path $DATA_DIR/tacker
    iniset $TACKER_CONF DEFAULT use_syslog $SYSLOG

    # Format logging
    if [ "$LOG_COLOR" == "True" ] && [ "$SYSLOG" == "False" ]; then
        setup_colorized_logging $TACKER_CONF DEFAULT project_id
    else
        # Show user_name and project_name by default like in nova
        iniset $TACKER_CONF DEFAULT logging_context_format_string "%(asctime)s.%(msecs)03d %(levelname)s %(name)s [%(request_id)s %(user_name)s %(project_name)s] %(instance)s%(message)s"
    fi

    if is_service_enabled tls-proxy; then
        # Set the service port for a proxy to take the original
        iniset $TACKER_CONF DEFAULT bind_port "$TACKER_PORT_INT"
    fi

    if is_ssl_enabled_service "tacker"; then
        ensure_certificates TACKER

        iniset $TACKER_CONF DEFAULT use_ssl True
        iniset $TACKER_CONF DEFAULT ssl_cert_file "$TACKER_SSL_CERT"
        iniset $TACKER_CONF DEFAULT ssl_key_file "$TACKER_SSL_KEY"
    fi

    # server
    TACKER_API_PASTE_FILE=$TACKER_CONF_DIR/api-paste.ini
    TACKER_POLICY_FILE=$TACKER_CONF_DIR/policy.json

    cp $TACKER_DIR/etc/tacker/api-paste.ini $TACKER_API_PASTE_FILE
    cp $TACKER_DIR/etc/tacker/policy.json $TACKER_POLICY_FILE

    # allow tacker user to administer tacker to match tacker account
    sed -i 's/"context_is_admin":  "role:admin"/"context_is_admin":  "role:admin or user_name:tacker"/g' $TACKER_POLICY_FILE

    iniset $TACKER_CONF DEFAULT verbose True
    iniset $TACKER_CONF DEFAULT debug $ENABLE_DEBUG_LOG_LEVEL
    iniset $TACKER_CONF DEFAULT policy_file $TACKER_POLICY_FILE

    iniset $TACKER_CONF DEFAULT auth_strategy $TACKER_AUTH_STRATEGY
    _tacker_setup_keystone $TACKER_CONF keystone_authtoken

    # Configuration for tacker requests to nova.
    iniset $TACKER_CONF DEFAULT nova_url $TACKER_NOVA_URL
    iniset $TACKER_CONF DEFAULT nova_amin_user_name nova
    iniset $TACKER_CONF DEFAULT nova_admin_password $SERVICE_PASSWORD
    iniset $TACKER_CONF DEFAULT nova_admin_tenant_id $SERVICE_TENANT_NAME
    iniset $TACKER_CONF DEFAULT nova_admin_auth_url $KEYSTONE_AUTH_URI
    iniset $TACKER_CONF DEFAULT nova_ca_certificates_file $TACKER_NOVA_CA_CERTIFICATES_FILE
    iniset $TACKER_CONF DEFAULT nova_api_insecure $TACKER_NOVA_API_INSECURE
    iniset $TACKER_CONF DEFAULT nova_region_name $REGION_NAME

    iniset $TACKER_CONF servicevm_nova auth_plugin password
    iniset $TACKER_CONF servicevm_nova auth_url $KEYSTONE_AUTH_URI
    iniset $TACKER_CONF servicevm_nova username nova
    iniset $TACKER_CONF servicevm_nova password $SERVICE_PASSWORD
    iniset $TACKER_CONF servicevm_nova user_domain_id default
    iniset $TACKER_CONF servicevm_nova project_name $SERVICE_TENANT_NAME
    iniset $TACKER_CONF servicevm_nova project_domain_id default
    iniset $TACKER_CONF servicevm_nova region_name $REGION_NAME

    iniset $TACKER_CONF servicevm_heat heat_uri http://$SERVICE_HOST:8004/v1
    iniset $TACKER_CONF servicevm_heat stack_retries 10
    iniset $TACKER_CONF servicevm_heat stack_retry_wait 5

    _tacker_setup_rootwrap
}

# Utility Functions
#------------------

# _tacker_deploy_rootwrap_filters() - deploy rootwrap filters to $TACKER_CONF_ROOTWRAP_D (owned by root).
function _tacker_deploy_rootwrap_filters {
    local srcdir=$1
    sudo install -d -o root -m 755 $TACKER_CONF_ROOTWRAP_D
    sudo install -o root -m 644 $srcdir/etc/tacker/rootwrap.d/* $TACKER_CONF_ROOTWRAP_D/
}

# _tacker_setup_rootwrap() - configure Tacker's rootwrap
function _tacker_setup_rootwrap {
    if [[ "$TACKER_USE_ROOTWRAP" == "False" ]]; then
        return
    fi
    # Wipe any existing ``rootwrap.d`` files first
    TACKER_CONF_ROOTWRAP_D=$TACKER_CONF_DIR/rootwrap.d
    if [[ -d $TACKER_CONF_ROOTWRAP_D ]]; then
        sudo rm -rf $TACKER_CONF_ROOTWRAP_D
    fi

    _tacker_deploy_rootwrap_filters $TACKER_DIR

    sudo install -o root -g root -m 644 $TACKER_DIR/etc/tacker/rootwrap.conf $TACKER_RR_CONF_FILE
    sudo sed -e "s:^filters_path=.*$:filters_path=$TACKER_CONF_ROOTWRAP_D:" -i $TACKER_RR_CONF_FILE
    # Specify ``rootwrap.conf`` as first parameter to tacker-rootwrap
    ROOTWRAP_SUDOER_CMD="$TACKER_ROOTWRAP $TACKER_RR_CONF_FILE *"

    # Set up the rootwrap sudoers for tacker
    TEMPFILE=`mktemp`
    echo "$STACK_USER ALL=(root) NOPASSWD: $ROOTWRAP_SUDOER_CMD" >$TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/tacker-rootwrap

    # Update the root_helper
    iniset $TACKER_CONF agent root_helper "$TACKER_RR_COMMAND"
}

# Configures keystone integration for tacker service and agents
function _tacker_setup_keystone {
    local conf_file=$1
    local section=$2
    local use_auth_url=$3

    # Configures keystone for metadata_agent
    # metadata_agent needs auth_url to communicate with keystone
    if [[ "$use_auth_url" == "True" ]]; then
        iniset $conf_file $section auth_url $KEYSTONE_SERVICE_URI/v2.0
    fi

    create_tacker_cache_dir
    configure_auth_token_middleware $conf_file $TACKER_ADMIN_USERNAME $TACKER_AUTH_CACHE_DIR $section
}

# check for service enabled
if is_service_enabled tacker; then
    if [[ "$1" == "stack" && "$2" == "install" ]]; then
        # Perform installation of service source
        echo_summary "Installing Tacker"
        install_tacker
        install_tackerclient

    elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        # Configure after the other layer 1 and 2 services have been configured
        echo_summary "Configuring Tacker"
        configure_tacker
        create_tacker_accounts

    elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
        # Initialize and start the tacker service
        echo_summary "Initializing Tacker"
        init_tacker
        echo_summary "Starting Tacker API"
        start_tacker_api
    fi

    if [[ "$1" == "unstack" ]]; then
        # Shut down tacker services
        stop_tacker
    fi

    if [[ "$1" == "clean" ]]; then
        # Remove state and transient data
        # Remember clean.sh first calls unstack.sh
        cleanup_tacker
    fi
fi

# Restore xtrace
$XTRACE

# Tell emacs to use shell-script-mode
## Local variables:
## mode: shell-script
## End:
