FROM ubuntu:latest
USER root
RUN apt-get update ;\
    DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AllowUnauthenticated=true install -y gpg wget ;\
    mkdir -m 0755 -p /etc/apt/keyrings/ ;\
    wget -qO- https://ipitio.github.io/closure/gpg.key | gpg --dearmor | tee /etc/apt/keyrings/closure.gpg > /dev/null  ;\
    chmod 644 /etc/apt/keyrings/closure.gpg ;\
    echo "deb [signed-by=/etc/apt/keyrings/closure.gpg] https://ipitio.github.io/closure master main" | tee /etc/apt/sources.list.d/closure.list ;\
    chmod 644 /etc/apt/sources.list.d/closure.list ;\
    apt-get update ;\
    DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AllowUnauthenticated=true install --no-install-recommends -y closure
WORKDIR /opt/closure
RUN mv examples/* . ; bash init.sh
