FROM alpine:3.20

WORKDIR /home/buildpiper

RUN apk --no-cache add \
    bash openssh-client jq coreutils && \
    addgroup -g 65522 buildpiper && \
    adduser -D -h /home/buildpiper -u 65522 -G buildpiper buildpiper && \
    mkdir -p /home/buildpiper && \
    chown -R buildpiper:buildpiper /home/buildpiper

ENV SLEEP_DURATION=5s
ENV VALIDATION_FAILURE_ACTION=FAILURE

COPY build.sh .
COPY getDynamicVars.sh .
ADD BP-BASE-SHELL-STEPS /opt/buildpiper/shell-functions/
RUN chmod 700 build.sh getDynamicVars.sh

ENV INSTRUCTION="script"

ENTRYPOINT [ "./build.sh" ]
