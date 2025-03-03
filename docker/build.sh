docker build --platform="linux/amd64" -t ffornari/gpfs-mgr:rhel8 -f rhel8.Dockerfile .
docker build --platform="linux/amd64" -t ffornari/gpfs-mgr:rhel9 -f rhel9.Dockerfile .
docker build --platform="linux/amd64" -t ffornari/gpfs-mgr:centos7 --build-arg version=$(uname -r) .
docker build --platform="linux/amd64" -f storm-webdav-rhel8.Dockerfile -t ffornari/gpfs-storm-webdav:rhel8 .
docker build --platform="linux/amd64" -f storm-webdav-centos7.Dockerfile -t ffornari/gpfs-storm-webdav:centos7 --build-arg version=$(uname -r) .
