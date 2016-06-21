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

COPY assets/config/ /app/setup/config/
COPY assets/init /app/init
RUN chmod 755 /app/init

EXPOSE 22
EXPOSE 80
EXPOSE 443

VOLUME ["/home/git/data"]
VOLUME ["/var/log/gitlab"]

ENTRYPOINT ["/app/init"]
CMD ["app:start"]
