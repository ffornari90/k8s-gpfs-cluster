docker build -t ffornari/gpfs-mgr:fedora38 -f fedora38.Dockerfile .
docker build -t ffornari/gpfs-mgr:centos7 --build-arg version=$(uname -r) .
docker build -f storm-webdav.Dockerfile -t ffornari/gpfs-storm-webdav:centos7 --build-arg version=$(uname -r) .
