FROM quay.io/rhqp/deliverest:v0.0.6

LABEL org.opencontainers.image.authors="Ondrej Dockal<odockal@redhat.com>"

# Expects one of windows or darwin as builds args
ARG OS

ENV ASSETS_FOLDER=/opt/pde2e-runner \
    OS=${OS}

COPY /lib/${OS}/* ${ASSETS_FOLDER}/