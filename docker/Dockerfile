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
    openssh-server glibc-locale-source glibc-all-langpacks && \
    yum clean all && \
    rm -rf /var/cache/yum
RUN pip3 install CherryPy && \
    git clone https://github.com/gdraheim/docker-systemctl-replacement.git && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /usr/bin/ && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /bin/systemctl && \
    cp docker-systemctl-replacement/files/docker/journalctl3.py /bin/journalctl
CMD /usr/sbin/sshd -D
