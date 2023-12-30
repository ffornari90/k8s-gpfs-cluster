FROM registry.access.redhat.com/ubi9/ubi-minimal
COPY ./appstream-el9.repo /etc/yum.repos.d/
RUN rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    rpm -ivh http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/centos-gpg-keys-9.0-23.el9.noarch.rpm && \
    rpm -ivh http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/Packages/centos-stream-repos-9.0-23.el9.noarch.rpm && \
    microdnf --enablerepo=appstream-el9 install -y kernel-{headers-,devel-}5.14.0-362.8.1.el9_3.x86_64 && \
    microdnf clean all && \
    rm -rf /var/cache/* && \
    microdnf --enablerepo=crb install -y python3 python3-devel python3-pip git \
    perl initscripts iproute hostname which dmidecode cronie \
    make cpp gcc gcc-c++ elfutils-devel elfutils openssl \
    openssh-server glibc-locale-source glibc-all-langpacks && \
    microdnf clean all && \
    rm -rf /var/cache/*
RUN pip3 install CherryPy && \
    git clone https://github.com/gdraheim/docker-systemctl-replacement.git && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /usr/bin/ && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /bin/systemctl && \
    cp docker-systemctl-replacement/files/docker/journalctl3.py /bin/journalctl
CMD /usr/sbin/sshd -D
