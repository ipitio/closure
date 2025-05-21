FROM ubuntu:latest
RUN apt-get update ;\
    apt-get install -qq curl ;\
    curl -sSLNZ https://ipitio.github.io/closure/i | bash
WORKDIR /opt/closure
RUN mv examples/* . ; bash init.sh &>/dev/null
