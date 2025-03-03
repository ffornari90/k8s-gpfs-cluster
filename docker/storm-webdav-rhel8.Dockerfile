FROM registry.access.redhat.com/ubi8/ubi-minimal
COPY ./baseos-el8.repo /etc/yum.repos.d/
RUN rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm && \
    rpm -ivh http://vault.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-gpg-keys-8-6.el8.noarch.rpm && \
    rpm -ivh http://vault.centos.org/centos/8-stream/BaseOS/x86_64/os/Packages/centos-stream-repos-8-6.el8.noarch.rpm && \
    sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/*.repo && \
    sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/*.repo && \
    sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/*.repo && \
    microdnf --enablerepo=baseos-el8 install -y kernel-{headers-,devel-}4.18.0-553.el8_10.x86_64 && \
    microdnf clean all && \
    rm -rf /var/cache/* && \
    microdnf --enablerepo=powertools install -y python3 python3-devel python3-pip git \
    perl initscripts iproute hostname which dmidecode cronie tar \
    make cpp gcc gcc-c++ elfutils-devel elfutils openssl sudo \
    openssh-server glibc-locale-source glibc-all-langpacks attr \
    java-17-openjdk java-17-devel jpackage-utils && \
    microdnf clean all && \
    rm -rf /var/cache/* && \
    update-alternatives --set java "$(update-alternatives --list | grep -w jre_17 | awk '{print $3}')/bin/java" && \
    update-alternatives --set javac "$(update-alternatives --list | grep -w jre_17 | awk '{print $3}')/bin/javac"
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
    rpm -ivh https://github.com/italiangrid/storm-webdav/releases/download/v1.6.1/storm-webdav-1.6.1-1.el8.noarch.rpm && \
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
