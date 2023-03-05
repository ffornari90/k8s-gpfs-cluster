FROM centos:7
ARG version
ENV JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk
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
    git clone https://github.com/italiangrid/storm-webdav.git && \
    cd storm-webdav && \
    mkdir -p ~/.m2 && \
    cp cnaf-mirror-settings.xml ~/.m2/settings.xml && \
    git checkout tags/v1.4.1 && \
    sed -i '45,93 s/@Validated/\/*@Validated*\//' \
    ./src/main/java/org/italiangrid/storm/webdav/config/ServiceConfigurationProperties.java && \
    mvn -Pnexus package && \
    cd .. && \
    rm -rf ~/.m2 && \
    tar xzvf storm-webdav/target/storm-webdav-server.tar.gz && \
    rm -rf storm-webdav && \
    mv /usr/share/java/storm-webdav/storm-webdav-server.jar \
    /etc/storm/webdav/storm-webdav-server.jar && \
    chown storm:storm -R /etc/grid-security/storm-webdav && \
    chown storm:storm -R /var/log/storm && \
    chown storm:storm -R /var/lib/storm-webdav && \
    chown storm:storm -R /etc/storm
WORKDIR /etc/storm/webdav
CMD /usr/sbin/sshd -D
