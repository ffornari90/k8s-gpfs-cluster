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
    openssh-server glibc-locale-source glibc-all-langpacks && \
    microdnf clean all && \
    rm -rf /var/cache/*
RUN pip3 install CherryPy && \
    git clone https://github.com/gdraheim/docker-systemctl-replacement.git && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /usr/bin/ && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /bin/systemctl && \
    cp docker-systemctl-replacement/files/docker/journalctl3.py /bin/journalctl
CMD /usr/sbin/sshd -D
