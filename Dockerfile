FROM debian:stretch-slim
RUN apt-get update && apt-get install -y awscli jq moreutils
ADD https://storage.googleapis.com/kubernetes-release/release/v1.9.10/bin/linux/amd64/kubectl /usr/local/bin/kubectl
RUN chmod +x /usr/local/bin/kubectl
ADD *.sh /
RUN chmod +x /*.sh
CMD ["/maintain-log.sh"]