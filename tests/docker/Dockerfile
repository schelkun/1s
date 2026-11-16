# Small disposable toolbox for running the 1s scripts and tests on Linux.
# Also used as the simulated server in tests/e2e (it ships dockerd and sshd).
FROM alpine:3.22
RUN apk add --no-cache bash coreutils findutils grep sed gawk tar gzip util-linux util-linux-misc \
      curl jq openssl python3 git iptables ip6tables iproute2 bind-tools openssh sudo shadow \
      procps shellcheck docker docker-cli-compose ca-certificates
