FROM centos:centos7
MAINTAINER jbrooks@redhat.com

RUN yum update -y; yum clean all
RUN yum -y install epel-release; yum clean all
RUN yum install -y supervisor logrotate nginx openssh-server \
    git postgresql ruby rubygems python python-docutils \
    mariadb-devel libpqxx zlib libyaml gdbm readline redis \
    ncurses libffi libxml2 libxslt libcurl libicu rubygem-bundler \
    which sudo passwd tar initscripts cronie nodejs; yum clean all
RUN sed -i 's/Defaults    requiretty/#Defaults    requiretty/g' /etc/sudoers
ADD assets/setup/ /app/setup/
RUN chmod 755 /app/setup/install
RUN /app/setup/install

ENV GITLAB_VERSION=8.8.5 \
    GITLAB_SHELL_VERSION=2.7.2 \
    GITLAB_WORKHORSE_VERSION=0.7.1 \
    GOLANG_VERSION=1.5.3 \
    GITLAB_USER="git" \
    GITLAB_HOME="/home/git" \
    GITLAB_LOG_DIR="/var/log/gitlab" \
    GITLAB_CACHE_DIR="/etc/docker-gitlab" \
    RAILS_ENV=production

ENV GITLAB_INSTALL_DIR="${GITLAB_HOME}/gitlab" \
    GITLAB_SHELL_INSTALL_DIR="${GITLAB_HOME}/gitlab-shell" \
    GITLAB_WORKHORSE_INSTALL_DIR="${GITLAB_HOME}/gitlab-workhorse" \
    GITLAB_DATA_DIR="${GITLAB_HOME}/data" \
    GITLAB_BUILD_DIR="${GITLAB_CACHE_DIR}/build" \
    GITLAB_RUNTIME_DIR="${GITLAB_CACHE_DIR}/runtime"

COPY assets/build/ ${GITLAB_BUILD_DIR}/
RUN bash ${GITLAB_BUILD_DIR}/install.sh

COPY assets/runtime/ ${GITLAB_RUNTIME_DIR}/
COPY entrypoint.sh /sbin/entrypoint.sh
RUN chmod 755 /sbin/entrypoint.sh

EXPOSE 22/tcp 80/tcp 443/tcp

VOLUME ["${GITLAB_DATA_DIR}", "${GITLAB_LOG_DIR}"]
WORKDIR ${GITLAB_INSTALL_DIR}
ENTRYPOINT ["/sbin/entrypoint.sh"]
CMD ["app:start"]
