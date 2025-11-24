FROM alpine

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    python3 \
    py3-pip \
    sed \
    openssh \
    openssh-client \
    jq \
    sudo \
    aws-cli \
    py3-cryptography

# Create buildpiper user
RUN addgroup -g 65522 buildpiper && \
    adduser -D -u 65522 -G buildpiper -h /home/buildpiper buildpiper && \
    mkdir -p /home/buildpiper && \
    chown -R buildpiper:buildpiper /home/buildpiper

# Copy private key INSIDE image
COPY --chown=buildpiper:buildpiper my-pritam.pem /home/buildpiper/key.pem
RUN chmod 400 /home/buildpiper/key.pem

# Create required directories
RUN mkdir -p \
        /src/reports \
        /bp/data \
        /bp/execution_dir \
        /opt/buildpiper/shell-functions \
        /opt/buildpiper/data \
        /bp/workspace && \
    chown -R buildpiper:buildpiper /src /bp /opt

# Copy script + shell functions
COPY --chown=buildpiper:buildpiper build.sh /home/buildpiper/build.sh
COPY --chown=buildpiper:buildpiper BP-BASE-SHELL-STEPS /opt/buildpiper/shell-functions/

# Set script permissions
RUN chmod +x /home/buildpiper/build.sh && \
    mkdir -p /home/buildpiper/reports && \
    chown -R buildpiper:buildpiper /home/buildpiper

# Switch to buildpiper user
USER buildpiper

# Working directory
WORKDIR /home/buildpiper

# ENTRYPOINT ["/home/buildpiper/build.sh"]
ENTRYPOINT ["bash", "/home/buildpiper/build.sh"]
