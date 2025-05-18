FROM ubuntu:latest
RUN apt-get update &&\
    apt-get install -yqq wget  &&\
    mkdir -m 0755 -p /etc/apt/keyrings/ &&\
    wget -qO- https://ipitio.github.io/closure/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/closure.gpg > /dev/null  &&\
    chmod 644 /etc/apt/keyrings/closure.gpg &&\
    echo "deb https://ipitio.github.io/closure master main" | sudo tee /etc/apt/sources.list.d/closure.list  &&\
    chmod 644 /etc/apt/sources.list.d/closure.list  &&\
    apt-get update  &&\
    apt-get install -yqq closure &&\
    bash /opt/closure/init.sh
WORKDIR /opt/closure
