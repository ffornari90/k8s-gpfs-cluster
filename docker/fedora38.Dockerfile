FROM registry.fedoraproject.org/fedora:38
RUN dnf install -y kernel-headers-6.6.3-100.fc38.x86_64 && \
    dnf clean all && \
    rm -rf /var/cache/* && \   
    curl -L "https://kojipkgs.fedoraproject.org//packages/kernel/6.6.3/100.fc38/x86_64/kernel-devel-6.6.3-100.fc38.x86_64.rpm" \
    -o kernel-devel-6.6.3-100.fc38.x86_64.rpm && \
    dnf localinstall -y kernel-devel-6.6.3-100.fc38.x86_64.rpm && \
    dnf clean all && \
    rm -rf /var/cache/* && \   
    dnf install -y python3 python3-devel python3-pip git \
    perl initscripts iproute hostname which dmidecode \
    make cpp gcc gcc-c++ elfutils-devel elfutils openssl \
    openssh-server glibc-locale-source glibc-all-langpacks && \
    dnf clean all && \
    rm -rf /var/cache/*
RUN pip3 install CherryPy && \
    git clone https://github.com/gdraheim/docker-systemctl-replacement.git && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /usr/bin/ && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /bin/systemctl && \
    cp docker-systemctl-replacement/files/docker/journalctl3.py /bin/journalctl
CMD /usr/sbin/sshd -D
