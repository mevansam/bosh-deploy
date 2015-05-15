#!/bin/bash

function usage() {

cat << EOF

    USAGE: $0 [help | init | release] iaas env name [OPTIONS]

    COMMANDS:

        ACTION:
          help - Show this message.
          init - Deploy Bosh.
          release - Deploy Release.

        iaas - Folder container templates for the target IaaS
        env - Folder container the environment variables (i.e. boshrc) 
        name - Name of the manifest file without the extension to use for deployment (found in the IaaS template folder)

    OPTIONS:

    EXAMPLES:

EOF
}

function parse_yaml {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

function process_template() {

ruby - $1 <<END
require 'erb'

include ERB::Util

@vars = ENV.to_hash

if !File.exist?(ARGV[0])
    puts "ERB template #{ARGV[0]} does not exist."
    exit 1
end

template = IO.read(ARGV[0])
result = ERB.new(template, nil, '-<>').result(binding)
puts result
END
}

function initialize() {
    local iaas=$1
    local env=$2

    if [ -z $iaas ] || [ ! -d "$ROOT_DIR/templates/$iaas" ]; then
        echo "ERROR! IaaS must be one of:"
        for d in $(ls $ROOT_DIR/templates/$iaas); do echo "  - $d"; done
        exit 1
    fi
    if [ "$iaas" == "openstack" ]; then
        pip freeze 2> /dev/null | grep python-novaclient 2>&1 > /dev/null
        if [ $? -ne 0 ]; then
            echo "ERROR! Unable to find python or openstack clients."
            exit 1
        fi
    fi
    if [ -z $env ] || [ ! -d "$ROOT_DIR/environments/$env" ]; then
        echo "ERROR! Env must be one of:"
        for d in $(ls $ROOT_DIR/environments); do echo "  - $d"; done
        exit 1
    fi

    which bosh 2>&1 > /dev/null
    if [ $? -ne 0 ]; then
        echo "ERROR! Unable to find bosh CLI in system path."
        exit 1
    fi
    which bosh-init 2>&1 > /dev/null
    if [ $? -ne 0 ]; then
        echo "ERROR! Unable to find bosh-init CLI in system path."
        exit 1
    fi

    TEMPLATES_DIR=$ROOT_DIR/templates/$iaas
    ENVIRONMENT_DIR=$ROOT_DIR/environments/$env

    MANIFEST=$3
    MANIFEST_TEMPLATE="$TEMPLATES_DIR/$MANIFEST.yml.erb"
    BOSHRC_ENV="$ENVIRONMENT_DIR/boshrc"

    WORKSPACE_DIR=$ENVIRONMENT_DIR/.workspace
    mkdir -p $WORKSPACE_DIR

    if [ ! -e "$MANIFEST_TEMPLATE" ]; then
        echo "ERROR! Manifest must be one of:"
        for d in $(ls $TEMPLATES_DIR); do echo "  - ${d%.yml*}"; done
        exit 1
    fi
    if [ ! -e "$BOSHRC_ENV" ]; then
        echo "ERROR! Bosh environment variable file '$BOSHRC_ENV' not found."
        exit 1
    fi

    source $BOSHRC_ENV
    export ENV_NAME=$env

    STEMCELL_DIR=$ROOT_DIR/.stemcells
    mkdir -p $STEMCELL_DIR

    if [ -z $BOSH_STEMCELL_URL ]; then
        echo "BOSH_STEMCELL_URL environment variable is empty."
        exit 1
    fi

    STEMCELL_BASE=$(basename $BOSH_STEMCELL_URL) 
    export STEMCELL_NAME=${STEMCELL_BASE%\?*}
    export STEMCELL_VERSION=${STEMCELL_BASE#*\?v=}
    export STEMCELL_PATH=$STEMCELL_DIR/$STEMCELL_NAME.tgz

    if [ ! -e "$STEMCELL_PATH" ]; then
        curl -k -J -L https://bosh.io/d/stemcells/bosh-openstack-kvm-ubuntu-trusty-go_agent-raw?v=2968 -o $STEMCELL_PATH
    fi

    SHA1=$(openssl sha1 .stemcells/bosh-openstack-kvm-ubuntu-trusty-go_agent-raw.tgz)
    export BOSH_STEMCELL_SHA1=${SHA1#*= }
}

function bosh_init_deploy() {

    process_template $MANIFEST_TEMPLATE > $WORKSPACE_DIR/$MANIFEST.yml
    if [ $? -ne 0 ]; then
        "ERROR encountered while processing the manifest template at '$MANIFEST_TEMPLATE'."
        exit 1
    fi

    nohup bosh-init deploy $WORKSPACE_DIR/$MANIFEST.yml > $WORKSPACE_DIR/bosh_init_deploy.log 2>&1 &
    echo "Microbosh deploy running in the background. Output available at $WORKSPACE_DIR/bosh-init-deploy.log."
}

function set_bosh_target() {

    if [ ! -e "$WORKSPACE_DIR/bosh-init-state.json" ]; then
        echo "ERROR! Unable to local bosh-int state in workspace '$WORKSPACE_DIR'."
        exit 1
    fi

    local director_vmuuid=$(cat $WORKSPACE_DIR/bosh-init-state.json | awk '/current_vm_cid/ { print substr($2,2,length($2)-3) }')
    local director_ip=$(nova --insecure show  $director_vmuuid 2> /dev/null | awk -v net="$INFRA_NETWORK" '$2==net && $3=="network" { print $6 }')

    bosh -u $BOSH_USER -p $BOSH_PASSWORD target $director_ip
    export DIRECTOR_UID=$(bosh status | awk '/UUID/ { print $2 }')
}

function bosh_deploy_release() {

    process_template $MANIFEST_TEMPLATE > $WORKSPACE_DIR/$MANIFEST.yml
    if [ $? -ne 0 ]; then
        "ERROR encountered while processing the manifest template at '$MANIFEST_TEMPLATE'."
        exit 1
    fi

    bosh deployment $WORKSPACE_DIR/$MANIFEST.yml
    nohup bosh deploy > $WORKSPACE_DIR/${MANIFEST}_deploy.log 2>&1 &
    echo "Bosh deploy running in the background. Output available at $WORKSPACE_DIR/$MANIFEST_deploy.log."
}

export ROOT_DIR=$(cd $(dirname $0) && pwd)

case "$1" in
    help)
        usage
        ;;
    init)
        initialize $2 $3 $4
        bosh_init_deploy
        ;;
    release)
        initialize $2 $3 $4
        set_bosh_target
        bosh_deploy_release
        ;;
    *)
        usage
        exit 1
esac
