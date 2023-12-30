docker build -t ffornari/gpfs-mgr:rhel8 -f rhel8.Dockerfile .
docker build -t ffornari/gpfs-mgr:rhel9 -f rhel9.Dockerfile .
docker build -t ffornari/gpfs-mgr:centos7 --build-arg version=$(uname -r) .
docker build -f storm-webdav.Dockerfile -t ffornari/gpfs-storm-webdav:centos7 --build-arg version=$(uname -r) .
