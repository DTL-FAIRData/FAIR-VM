#!/bin/bash

if [ "$#" -lt 2 ]; then
    echo "Please provide the VM name and your email address as parameters:"
    echo "$0 vm-name name@domain.tld [purl]"
    exit 1
fi

if [ "$#" -gt 3 ]; then
    echo "Received more than 3 parameters, ignoring the following:"

    until [ -z "$4" ]; do
        echo $4
        shift
    done
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with root priviliges:"
    echo "sudo $0"
    exit 1
fi

apt-get -qq install nano
if [ "$?" -ne 0 ]; then
    echo "Encountered a problem with apt/dpkg, please fix it before running this script again"
    exit 1
fi

VMNAME=$1
EMAIL=$2
PURL=$3
VMHOST="$VMNAME.fair-dtls.surf-hosted.nl"

DOCKERCOMPOSE_VERSION="1.24.1"

host $VMHOST
if [ "$?" -ne 0 ]; then
    echo "DNS information for this host cannot be resolved. This will cause issues with
    certbot later on. Please wait until this host is resolvable through DNS lookup."
    exit 1
fi

set -e

export LC_ALL="en_US.UTF-8"
export LC_CTYPE="en_US.UTF-8"

install_packages() {
    apt-get -qq -y install software-properties-common
}

configure_hostname() {
    hostname $VMHOST
    echo $VMHOST > /etc/hostname
}

mount_storage() {
    mkdir /data
    mkfs -t xfs /dev/vdb
    mount /dev/vdb /data
    mkdir -p /etc/rc.d/ && touch /etc/rc.d/rc.local
    echo "echo 4096 > /sys/block/vdb/queue/read_ahead_kb" > /etc/rc.d/rc.local
    chmod 755 /etc/rc.d/rc.local
    echo "/dev/vdb /data xfs defaults 0 0" >> /etc/fstab
}

setup_nginx() {
    apt-get -qq -y install nginx-core
    echo "server {
        listen 80;
        server_name $VMHOST;
        root /var/www/html;

        include /data/apps/nginx/*.conf;
    }" > /etc/nginx/sites-available/$VMNAME
    pushd /etc/nginx/sites-enabled
    ln -s /etc/nginx/sites-available/$VMNAME $VMNAME
    popd
    mkdir -p /data/apps/nginx
    service nginx reload
}

setup_certbot() {
    add-apt-repository -y -u ppa:certbot/certbot
    apt-get -qq -y install certbot python-certbot-nginx
    ufw allow http
    ufw allow https
    certbot --nginx --non-interactive --agree-tos --email $EMAIL --no-eff-email --domain $VMHOST --redirect
}

install_docker() {
    apt-get -qq -y install gnupg-agent
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get -qq update
    apt-get -qq -y install docker-ce docker-ce-cli containerd.io
    usermod -aG docker ubuntu
}

install_docker_compose() {
    curl -L https://github.com/docker/compose/releases/download/$DOCKERCOMPOSE_VERSION/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    curl -L https://raw.githubusercontent.com/docker/compose/$DOCKERCOMPOSE_VERSION/contrib/completion/bash/docker-compose -o /etc/bash_completion.d/docker-compose
}

configure_docker() {
    service docker stop
    mkdir -p /data/apps
    pushd /var/lib
    mv docker /data/apps
    ln -s /data/apps/docker docker
    popd
    service docker start

    # configure docker-compose
    sed -r -i "s%\"ES_URL=.+\"%\"ES_URL=https://$VMHOST/searchserver\"%" docker-compose.yml
}

setup_editor() {
    echo "{\"endpoint\":\"https://$VMHOST/fdp\"}" > /data/apps/editor/config/settings.json
}

setup_fdp() {
    local config="webapps/ROOT/WEB-INF/classes/conf/fdpConfig.yml"

    # configure storage
    docker exec fdp sh -c "sed -r -i 's/type: .+$/type: 1/' $config"
    docker exec fdp sh -c "sed -r -i 's/url: .+$/url: http:\/\/agraph:10035\/repositories\/fdp/' $config"
    docker exec fdp sh -c "sed -r -i 's/username: .+$/username: test/' $config"
    docker exec fdp sh -c "sed -r -i 's/password: .+$/password: xyzzy/' $config"

    curl -X PUT -u test:xyzzy http://localhost:10035/repositories/fdp

    # configure search engine integration
    docker exec fdp sh -c "sed -r -i 's%fdpSubmitUrl: .+$%fdpSubmitUrl: https://$VMHOST/search-api/fse/submitFdp%' $config"

    # multiline sed matching, see https://stackoverflow.com/a/14191827
    if [ -n "$PURL" ]; then
        # configure persistence system
        docker exec fdp sh -c "sed -r -i ':l;N;$!tl;N;s/(purl:\s+baseUrl:) .+/\1 $PURL/' $config"
    else
        # fallback to the local address
        # sed doesn't want to match on the shorthand digit notation (\d), so matching on the [0-9] group instead
        docker exec fdp sh -c "sed -r -i ':l;N;$!tl;N;s/(pidSystem:\s+type:) [0-9]/\1 1/' $config"
    fi

    su ubuntu -c "docker-compose restart fdp"
}

setup_fairifier() {
    mkdir -p /data/apps/fairifier/{data,config}
    echo "<xml>
        <pushToFtp>
            <enabled>false</enabled>
            <username></username>
            <password></password>
            <host></host>
            <directory></directory>
        </pushToFtp>
        <pushToVirtuoso>
            <enabled>true</enabled>
            <username>dba</username>
            <password>dba</password>
            <host>https://$VMHOST</host>
            <directory>/DAV/home/dba/rdf_sink/</directory>
        </pushToVirtuoso>
    </xml>" > /data/apps/fairifier/config/config.xml

    docker exec fairifier sh -c "echo \"REFINE_DATA_DIR=/fairifier_data\" >> /home/FAIRifier/refine.ini"
    
    su ubuntu -c "docker-compose restart fairifier"
}

setup_search() {
    docker exec search sh -c "sed -r -i 's/http:\/\/127.0.0.1:8080/https:\/\/$VMHOST\/search-api/' /var/www/html/submit/index.html"
}

setup_docker_images() {
    su ubuntu -c "docker-compose up -d"
    mv nginx/*.conf /data/apps/nginx
    service nginx reload
    
    setup_editor
    setup_fdp
    setup_fairifier
    setup_search
}

install_packages
configure_hostname
mount_storage
setup_nginx
setup_certbot
install_docker
install_docker_compose
configure_docker
setup_docker_images