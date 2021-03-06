#!/usr/bin/env bash

BASE_DIR="/opt/corrade"

BASIC_AUTH_USER="corrade"
RANDOM_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24 ; echo '')

if [ "$1" != "" ];
    then
        FILE_PATH_OR_URL_TO_CORRADE_ZIP="$1"
    else
        echo "Please include the required argument FILE_PATH_OR_URL_TO_CORRADE_ZIP"
        exit
fi


if [ "$2" != "" ];
    then
        PATH_TO_CONFIG_XML="$2"
    else
        echo "Please include the required argument PATH_TO_CONFIG_XML"
        exit
fi



if [ "$3" != "" ];
    then
        CERT_BOT_EMAIL="$3"
    else
        CERT_BOT_EMAIL=root@$HOSTNAME
fi



function doContinue() {
ANS=""

while [[ ! ${ANS} =~ ^([yY][eE][sS]|[yY])$ ]]
    do
        if [[ ${ANS} =~ ^([nN][oO]|[nN])$ ]]
            then
                return 1
            else
                read -p "Continue y/n? " ANS
        fi

        if [[ ${ANS} =~ ^([yY][eE][sS]|[yY])$ ]]
            then
                return 0
        fi
    done
}


####

function installMono() {
    rpm --import "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF"
    su -c 'curl https://download.mono-project.com/repo/centos7-stable.repo | tee /etc/yum.repos.d/mono-centos7-stable.repo'
    yum install -y mono-complete

}

function setupFirewalld() {
    systemctl enable firewalld.service
    systemctl start firewalld.service

    firewall-cmd --permanent --zone=public --add-service=https
    firewall-cmd --permanent --zone=public --add-service=http
    firewall-cmd --permanent --zone=public --add-port=9000/tcp #tcp
    firewall-cmd --permanent --zone=public --add-port=9005/tcp #mqtt
    systemctl restart firewalld.service
}

function installCorradeLinuxServer() {
    mkdir -p ${BASE_DIR}/corrade-linux-server

    git clone -b master --single-branch https://github.com/MidnightRift/corrade-linux-server.git ${BASE_DIR}/corrade-linux-server

    cp ${BASE_DIR}/corrade-linux-server/setup/corrade.service /etc/systemd/system/corrade.service
    cp ${BASE_DIR}/corrade-linux-server/setup/corrade /usr/local/bin/corrade

    chmod 755 /usr/local/bin/corrade


}

function setupNginx() {
    NGINX_CONF=$(eval echo "\"$(<${BASE_DIR}/corrade-linux-server/setup/nginx.conf)\"")
    echo "${NGINX_CONF}" > /etc/nginx/nginx.conf



    htpasswd -c -b /etc/nginx/.htpasswd ${BASIC_AUTH_USER} ${RANDOM_PASSWORD}

    systemctl enable nginx.service
    systemctl start nginx.service
}

function setupLetsEncrypt() {
    openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
    certbot certonly --non-interactive --standalone --email ${CERT_BOT_EMAIL} --agree-tos -d $HOSTNAME
    crontab -l | { cat; echo "$((RANDOM %59+1)) 4 * * 1 /usr/local/bin/corrade --cron >> $BASE_DIR/logs/cron.log"; } | crontab -
}

function createDirectoryStructure() {
    mkdir -p ${BASE_DIR}/live
    mkdir -p ${BASE_DIR}/logs
    mkdir -p ${BASE_DIR}/backups
    mkdir -p ${BASE_DIR}/temp
    mkdir -p ${BASE_DIR}/certs
}

function createCerts() {
    openssl genrsa -out ${BASE_DIR}/certs/corrade_private_key.pem 2048
    openssl req -new -key ${BASE_DIR}/certs/corrade_private_key.pem -subj "/CN=$HOSTNAME" -out ${BASE_DIR}/certs/corrade_csr.csr
    openssl x509 -signkey ${BASE_DIR}/certs/corrade_private_key.pem -in ${BASE_DIR}/certs/corrade_csr.csr -req -days 3650 -out ${BASE_DIR}/certs/corrade_cert.pem
    openssl pkcs12 -export -passout pass: -in ${BASE_DIR}/certs/corrade_cert.pem -inkey ${BASE_DIR}/certs/corrade_private_key.pem -out ${BASE_DIR}/certs/corrade_pfx_cert.pfx
    openssl rsa -in ${BASE_DIR}/certs/corrade_private_key.pem -outform PVK -pvk-none -out ${BASE_DIR}/certs/corrade_pvk_cert.pvk
}

function setupMonoCertificatePorts() {
    #tell mono to use a cert on ports:
    su -c "httpcfg -add -port 8008 -pvk ${BASE_DIR}/certs/corrade_pvk_cert.pvk -cert ${BASE_DIR}/certs/corrade_cert.pem" corrade
    su -c "httpcfg -add -port 8009 -pvk ${BASE_DIR}/certs/corrade_pvk_cert.pvk -cert ${BASE_DIR}/certs/corrade_cert.pem" corrade
    #JIC its needed later
    su -c "httpcfg -add -port 8443 -pvk ${BASE_DIR}/certs/corrade_pvk_cert.pvk -cert ${BASE_DIR}/certs/corrade_cert.pem" corrade
}

function createCorradeUserIfNotExist() {
    id -u corrade &>/dev/null || useradd corrade
    id -g corrade &>/dev/null || groupadd corrade
}

installCorrade(){

    mkdir -p ${BASE_DIR}/live
    mkdir -p ${BASE_DIR}/logs
    mkdir -p ${BASE_DIR}/backups
    mkdir -p ${BASE_DIR}/temp

    #incase I need to add ports to selinux
    #semanage port -a -t http_port_t -p tcp 9000
    #semanage port -a -t http_port_t -p tcp 9005

#extract to temp
    if [[ -f ${FILE_PATH_OR_URL_TO_CORRADE_ZIP} ]]
        then
            unzip ${FILE_PATH_OR_URL_TO_CORRADE_ZIP} -d ${BASE_DIR}/temp
    elif [[ ${FILE_PATH_OR_URL_TO_CORRADE_ZIP} =~ https?://* ]]
        then
            curl -Ls ${FILE_PATH_OR_URL_TO_CORRADE_ZIP} | bsdtar -xf - -C ${BASE_DIR}/temp
    else
        echo "Corrade source is not valid."
    fi

#Begin Install
    cp -R ${BASE_DIR}/temp/* ${BASE_DIR}/live
    rm -rf ${BASE_DIR}/temp/*


    if [ PATH_TO_CONFIG_XML != "" ];
        then
            yes | cp -f ${PATH_TO_CONFIG_XML} ${BASE_DIR}/live

            xmlstarlet ed -L -u "Configuration/Servers/TCPServer/TCPCertificate/Password" -v "" ${BASE_DIR}/live/Configuration.xml
            xmlstarlet ed -L -d "Configuration/Servers/TCPServer/TCPCertificate/Protocol" -v "Tls12" ${BASE_DIR}/live/Configuration.xml
            xmlstarlet ed -L -d "Configuration/Servers/TCPServer/Port" -v "8085" ${BASE_DIR}/live/Configuration.xml

            xmlstarlet ed -L -u "Configuration/Servers/TCPServer/TCPCertificate/Path" -v ${BASE_DIR}/certs/corrade_pfx_cert.pfx ${BASE_DIR}/live/Configuration.xml

            xmlstarlet ed -L -u "Configuration/Servers/MQTTServer/MQTTCertificate/Path" -v ${BASE_DIR}/certs/corrade_pfx_cert.pfx ${BASE_DIR}/live/Configuration.xml

            xmlstarlet ed -L -u "Configuration/Servers/HTTPServer/Prefixes/Prefix" -v "https://+:8008/" ${BASE_DIR}/live/Configuration.xml
            #xmlstarlet ed -L -u "Configuration/Servers/Nucleus/Prefixes/Prefix" -v "https://+:8009/" ${BASE_DIR}/live/Configuration.xml


            systemctl enable corrade.service
            systemctl start corrade.service
        else
        echo "Please start corrade manually after you update the configuration.xml"

        #echo "Certificate Pass: $RANDOM_PASSWORD"
        echo "Certificate File: $BASE_DIR/cert/corrade_cert.pfx"
        echo "Configuration File: $BASE_DIR/live/Confinguration.xml"

        echo "systemctl enable corrade.service then systemctl start corrade.service"
    fi

}

function setPerms()  {
  if [ -d "$BASE_DIR/live" ]; then
    chown -R corrade:corrade ${BASE_DIR}/live
  fi
}

function printInfoToCMD() {
    echo " "
    echo "################"
    echo "################"
    echo " "
    echo "HTTP and Nucleus"
    echo " User: ${BASIC_AUTH_USER}"
    echo " Pass: ${RANDOM_PASSWORD}"
    echo " "
    echo "HTTP: https://${HOSTNAME}/api"
    echo "Nucleus: https://${HOSTNAME}/nucleus"
}



###

yum update -y
yum install -y epel-release
yum install -y --enablerepo=epel git openssl openssl-devel nginx firewalld unzip certbot xmlstarlet httpd-tools bsdtar perl-Image-ExifTool



#begin Setup

installMono

setupFirewalld

installCorradeLinuxServer

setupLetsEncrypt

setupNginx

createDirectoryStructure

createCerts

createCorradeUserIfNotExist

setupMonoCertificatePorts

installCorrade

setPerms

printInfoToCMD

# disable kernel protection to increase mono performance.
# might not really be needed.

# grubby --update-kernel=ALL --args="nopti noibrs noibpb nospectre_v2 nospec_store_bypass_disable"
