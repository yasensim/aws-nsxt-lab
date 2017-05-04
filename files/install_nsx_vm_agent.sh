#! /bin/bash

set +e

exec > >(tee -i /tmp/nsx-bundle-install.log)
exec 2>&1

# LOCALTAR will be the nsx vm agent bundle file downloaded
LOCALTAR="/tmp/nsx-ubuntu-vm-bundle.tar.gz"
# UNTARDIR is the directory where the bundle will be extracted
UNTARDIR="/tmp/nsx_data"

VMWARE_PUBLIC_KEY="vmware_pubkey"
VMWARE_PUBLIC_GPGRING="vmware_pubring.gpg"

write_vmware_public_key() {
   rm -f $UNTARDIR/$VMWARE_PUBLIC_KEY
   cat <<EOF > $UNTARDIR/$VMWARE_PUBLIC_KEY
@PUBLICKEY@
EOF
}

show_usage() {
    cat <<EOF
usage: $(basename $0) <GW_IP>
param: GW_IP: optional param for GATEWAY IP.
       Default gateway DNS name will be used
       if this param is not passed.
EOF
}

download_bundle() {
    echo "------------------------------"
    echo "Downloading nsx lcp bundle"
    echo "Gateway IP: $1"

    # remove any previous instance of file
    rm -rf $LOCALTAR
    if [ "$2" = true ]; then
        ip_list=`nslookup $1 | awk '/^Address: / { print $2 }'`
        if [ -z "$ip_list" ]; then
            echo "ERROR: Failed to resolve: $1"
            exit
        fi
        i=1
        downloaded=false
        while [[ $i -le 3 ]] && [ "$downloaded" = false ]; do
            for ip in $ip_list; do
                url="http://$ip:8080/factory_default/trusty_amd64/nsx-vm-agent-bundle.tar.gz"
                echo "Trying wget: $url"
                # retry with 5 sec timeout
                wget -T 5 -t 1 -O $LOCALTAR $url
                if [ $? -eq 0 ]; then
                    downloaded=true
                    break
                fi
            done
            (( i++ ))
        done
    else
        url="http://$1:8080/factory_default/trusty_amd64/nsx-vm-agent-bundle.tar.gz"
        echo "Trying wget: $url"
        # retry 6 times with 5 sec timeout
        wget -T 5 -t 6 -O $LOCALTAR $url
    fi

    if [ $? -ne 0 ] || [ ! -s "$LOCALTAR" ]; then
        echo "ERROR: Failed to download nsx-lcp-bundle"
        exit 1
    fi
}

handle_cleanup() {
    rm -rf $LOCALTAR
    rm -rf $UNTARDIR
    if [ -f /etc/apt/sources.list.d/vmware.list ]; then
        rm -f /etc/apt/sources.list.d/vmware.list
    fi
    exit
}

extract_and_verify() {
    echo "------------------------------"
    echo "Extracting signed bundle"
    # remove any existence of the directory
    rm -rf $UNTARDIR
    mkdir $UNTARDIR
    tar -zxvf $LOCALTAR -C $UNTARDIR

    echo -e "\n------------------------------"
    echo "Verifying the bundle"
    write_vmware_public_key

    gpg --yes -o $UNTARDIR/$VMWARE_PUBLIC_GPGRING --dearmor $UNTARDIR/$VMWARE_PUBLIC_KEY
    gpg --status-fd 1 --no-default-keyring --keyring $UNTARDIR/$VMWARE_PUBLIC_GPGRING \
        --trust-model always --verify $UNTARDIR/nsx-lcp-*tar.gz.sig 2>/dev/null

    echo -e "\n------------------------------"
    echo "Extracting nsx lcp packages"
    tar -zxvf $UNTARDIR/nsx-lcp-*tar.gz -C $UNTARDIR
    echo -e "\n"
}

fix_dependency_error() {
    echo -e "\n------------------------------"
    echo "Fix any dependency errors"
    sudo apt-get -y --force-yes install -f
}

install_openvswitch_package() {
    echo -e "\n------------------------------"
    echo "Installing Openvswitch packages"
    cd $UNTARDIR/nsx-lcp-public-cloud*

    for i in $( ls openvswitch*); do sudo dpkg -i $i; done
    fix_dependency_error

    echo -e "\n------------------------------"
    echo "Loading Openvswitch kernel module"
    sudo service openvswitch-switch force-reload-kmod
    sudo modprobe vport-geneve
    if [ $? -ne 0 ]; then
        echo "ERROR: Openvswitch installation failed!!!"
        handle_cleanup
    fi
}

install_other_nsx_packages() {
    echo -e "\n------------------------------"
    echo "Installing NSX packages"
    for i in $( ls --ignore=openvswitch* | grep .deb); do sudo dpkg -i $i; done
    fix_dependency_error
    if [ $? -ne 0 ]; then
        echo "ERROR: Installation failed!!!"
        handle_cleanup
    fi
}

post_install() {
    cp $UNTARDIR/$VMWARE_PUBLIC_GPGRING /etc/vmware/nsx/
    chmod 640 /etc/vmware/nsx/$VMWARE_PUBLIC_GPGRING
    mv /tmp/nsx-bundle-install.log /var/log/vmware/nsx-agent/
}

create_local_repositry() {
    cd $UNTARDIR/nsx-lcp-public-cloud*
    apt-ftparchive packages . | gzip > Packages.gz

    echo "deb file://$(pwd) /" > /etc/apt/sources.list.d/vmware.list
    apt-get update -o Dir::Etc::sourcelist="sources.list.d/vmware.list" \
       -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
}

download_dependencies() {
    create_local_repositry

    #get dependenices URL
    apt-get --print-uris --yes install `ls * | grep deb | sed 's/_.*//g'` | \
        grep ^\' | cut -d\' -f2 | grep "http://" > downloads.list
    if [ ! -s downloads.list ]; then
        echo "No dependencies. Begin package installation"
        return
    fi

    echo -e "\n------------------------------"
    echo "Downloading dependencies"
    mkdir dependencies
    while read -r url; do
        echo "wget: $url"
        wget -q -T 5 $url -P dependencies/
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to download dependencies"
            handle_cleanup
            exit 1
        fi
    done < downloads.list

    echo -e "\n------------------------------"
    echo "Installing dependencies"
    for i in $( ls dependencies); do sudo dpkg -i dependencies/$i; done
    fix_dependency_error
}

## Parse the parameters passed to the script
if [ "$1" = "--help" ]; then
    show_usage
    exit 0
fi

echo "$(date): Installation started"
if [ "$1" = "" ]; then
    gw_ip="nsx-gw.vmware.com"
    dns=true
else
    gw_ip=$1
    dns=false
fi

download_bundle $gw_ip $dns
extract_and_verify

sudo apt-get update
download_dependencies

install_openvswitch_package
install_other_nsx_packages
post_install

`sudo chmod 777 /etc/vmware/nsx/public-cloud-config`
`sudo printf "gw=$1 \ninterface=eth1:overlay \n" >> /etc/vmware/nsx/public-cloud-config`
`sudo service nsx-agent restart`

echo -e "\n------------------------------"
echo "$(date): Installation completed!!!"
handle_cleanup



