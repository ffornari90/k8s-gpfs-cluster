FROM centos:7
ARG version
RUN yum update -y && \
    yum clean all && \
    rm -rf /var/cache/yum && \   
    yum install -y "http://os-server.cr.cnaf.infn.it/distro/Storage/updates/kernel-headers-${version}.rpm" && \
    yum clean all && \
    rm -rf /var/cache/yum && \
    yum install -y "http://os-server.cr.cnaf.infn.it/distro/Storage/updates/kernel-devel-${version}.rpm" && \
    yum clean all && \
    rm -rf /var/cache/yum && \
    yum install -y python3 python3-devel python3-pip git \
    perl initscripts iproute hostname which dmidecode \
    make cpp gcc gcc-c++ elfutils-devel elfutils openssl \
    openssh-server glibc-locale-source glibc-all-langpacks \
    wget git maven sudo && \
    yum clean all && \
    rm -rf /var/cache/yum
RUN pip3 install CherryPy && \
    git clone https://github.com/gdraheim/docker-systemctl-replacement.git && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /usr/bin/ && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /bin/systemctl && \
    cp docker-systemctl-replacement/files/docker/journalctl3.py /bin/journalctl
RUN groupadd -g 991 storm && \
    adduser --uid 991 --gid 991 -m storm && \
    usermod -aG wheel storm && \
    mkdir -p /var/log/storm/webdav && \
    mkdir -p /var/lib/storm-webdav/work && \
    mkdir -p /etc/grid-security/storm-webdav && \
    mkdir -p /etc/grid-security/vomsdir && \
    echo 'storm ALL=(ALL) NOPASSWD: /usr/bin/update-ca-trust' \
    > /etc/sudoers.d/trust && \
    yum install -y https://repository.egi.eu/sw/production/umd/4/centos7/x86_64/updates/storm-webdav-1.4.1-1.el7.noarch.rpm && \
    mkdir storm-webdav-server && \
    cd storm-webdav-server && \
    jar xf /usr/share/java/storm-webdav/storm-webdav-server.jar && \
    cd .. && \
    sed -i 's/    requireClientCert: ${STORM_WEBDAV_REQUIRE_CLIENT_CERT:true}/    requireClientCert: ${STORM_WEBDAV_REQUIRE_CLIENT_CERT:false}/g' \
    storm-webdav-server/BOOT-INF/classes/application.yml && \
    rm -f /usr/share/java/storm-webdav/storm-webdav-server.jar && \
    jar -cvf0m /usr/share/java/storm-webdav/storm-webdav-server.jar \
    storm-webdav-server/META-INF/MANIFEST.MF -C storm-webdav-server . && \
    rm -rf storm-webdav-server && \
    mv /usr/share/java/storm-webdav/storm-webdav-server.jar \
    /etc/storm/webdav/storm-webdav-server.jar && \
    chown storm:storm -R /etc/grid-security/storm-webdav && \
    chown storm:storm -R /var/log/storm && \
    chown storm:storm -R /var/lib/storm-webdav && \
    chown storm:storm -R /etc/storm
WORKDIR /etc/storm/webdav
CMD /usr/sbin/sshd -D
