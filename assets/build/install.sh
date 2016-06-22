#!/bin/bash
set -e

GITLAB_CLONE_URL=https://github.com/gitlabhq/gitlabhq.git
GITLAB_SHELL_URL=https://gitlab.com/gitlab-org/gitlab-shell/repository/archive.tar.gz
GITLAB_WORKHORSE_URL=https://gitlab.com/gitlab-org/gitlab-workhorse/repository/archive.tar.gz

GEM_CACHE_DIR="${GITLAB_BUILD_DIR}/cache"

BUILD_DEPENDENCIES="gcc gcc-c++ make patch pkgconfig cmake \
  glibc-devel rh-ruby22-ruby-devel mysql-devel postgresql-devel \
  zlib-devel libyaml-devel openssl-devel gdbm-devel readline-devel \
  ncurses-devel libffi-devel libxml2-devel libxslt-devel \
  libcurl-devel libicu-devel nodejs wget libuv"

## Execute a command as GITLAB_USER
exec_as_git() {
  if [[ $(whoami) == ${GITLAB_USER} ]]; then
    $@
  else
    sudo -HEu ${GITLAB_USER} "$@"
  fi
}

# install build dependencies for gem installation
yum install -y ${BUILD_DEPENDENCIES}

# https://en.wikibooks.org/wiki/Grsecurity/Application-specific_Settings#Node.js
#paxctl -Cm `which nodejs`

# remove the host keys generated during openssh-server installation
rm -rf /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# add ${GITLAB_USER} user
useradd -c 'GitLab' ${GITLAB_USER}
passwd -d ${GITLAB_USER}

# set PATH (fixes cron job PATH issues)
cat >> ${GITLAB_HOME}/.profile <<EOF
PATH=/usr/local/sbin:/usr/local/bin:\$PATH
EOF

cat >> ${GITLAB_HOME}/.bashrc <<EOF
source /opt/rh/rh-ruby22/enable
EOF

# configure git for ${GITLAB_USER}
exec_as_git git config --global core.autocrlf input
exec_as_git git config --global gc.auto 0

# install gitlab-shell
echo "Downloading gitlab-shell v.${GITLAB_SHELL_VERSION}..."
mkdir -p ${GITLAB_SHELL_INSTALL_DIR}
wget -cq ${GITLAB_SHELL_URL}?ref=v${GITLAB_SHELL_VERSION} -O ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.gz
tar xf ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.gz --strip 1 -C ${GITLAB_SHELL_INSTALL_DIR}
rm -rf ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.gz
chown -R ${GITLAB_USER}: ${GITLAB_SHELL_INSTALL_DIR}

cd ${GITLAB_SHELL_INSTALL_DIR}
exec_as_git cp -a ${GITLAB_SHELL_INSTALL_DIR}/config.yml.example ${GITLAB_SHELL_INSTALL_DIR}/config.yml
exec_as_git scl enable rh-ruby22 './bin/install'

# remove unused repositories directory created by gitlab-shell install
exec_as_git rm -rf ${GITLAB_HOME}/repositories

echo "Downloading gitlab-workhorse v.${GITLAB_WORKHORSE_VERSION}..."
mkdir -p ${GITLAB_WORKHORSE_INSTALL_DIR}
wget -cq ${GITLAB_WORKHORSE_URL}?ref=v${GITLAB_WORKHORSE_VERSION} -O ${GITLAB_BUILD_DIR}/gitlab-workhorse-${GITLAB_WORKHORSE_VERSION}.tar.gz
tar xf ${GITLAB_BUILD_DIR}/gitlab-workhorse-${GITLAB_WORKHORSE_VERSION}.tar.gz --strip 1 -C ${GITLAB_WORKHORSE_INSTALL_DIR}
rm -rf ${GITLAB_BUILD_DIR}/gitlab-workhorse-${GITLAB_WORKHORSE_VERSION}.tar.gz
chown -R ${GITLAB_USER}: ${GITLAB_WORKHORSE_INSTALL_DIR}

echo "Downloading Go ${GOLANG_VERSION}..."
wget -cnv https://storage.googleapis.com/golang/go${GOLANG_VERSION}.linux-amd64.tar.gz -P ${GITLAB_BUILD_DIR}/
tar -xf ${GITLAB_BUILD_DIR}/go${GOLANG_VERSION}.linux-amd64.tar.gz -C /tmp/

cd ${GITLAB_WORKHORSE_INSTALL_DIR}
PATH=/tmp/go/bin:$PATH GOROOT=/tmp/go make install

# remove go
rm -rf ${GITLAB_BUILD_DIR}/go${GOLANG_VERSION}.linux-amd64.tar.gz /tmp/go

# shallow clone gitlab-ce
echo "Cloning gitlab-ce v.${GITLAB_VERSION}..."
exec_as_git git clone -q -b v${GITLAB_VERSION} --depth 1 ${GITLAB_CLONE_URL} ${GITLAB_INSTALL_DIR}

# remove HSTS config from the default headers, we configure it in nginx
exec_as_git sed -i "/headers\['Strict-Transport-Security'\]/d" ${GITLAB_INSTALL_DIR}/app/controllers/application_controller.rb

# revert `rake gitlab:setup` changes from gitlabhq/gitlabhq@a54af831bae023770bf9b2633cc45ec0d5f5a66a
exec_as_git sed -i 's/db:reset/db:setup/' ${GITLAB_INSTALL_DIR}/lib/tasks/gitlab/setup.rake

cd ${GITLAB_INSTALL_DIR}

# install gems, use local cache if available
if [[ -d ${GEM_CACHE_DIR} ]]; then
  mv ${GEM_CACHE_DIR} ${GITLAB_INSTALL_DIR}/vendor/cache
  chown -R ${GITLAB_USER}: ${GITLAB_INSTALL_DIR}/vendor/cache
fi
exec_as_git scl enable rh-ruby22 'bundle install -j$(nproc) --deployment --without development test aws'

# make sure everything in ${GITLAB_HOME} is owned by ${GITLAB_USER} user
chown -R ${GITLAB_USER}: ${GITLAB_HOME}

# gitlab.yml and database.yml are required for `assets:precompile`
exec_as_git cp ${GITLAB_INSTALL_DIR}/config/gitlab.yml.example ${GITLAB_INSTALL_DIR}/config/gitlab.yml
exec_as_git cp ${GITLAB_INSTALL_DIR}/config/database.yml.mysql ${GITLAB_INSTALL_DIR}/config/database.yml

echo "Compiling assets. Please be patient, this could take a while..."
exec_as_git scl enable rh-ruby22 'bundle exec rake assets:clean assets:precompile USE_DB=false >/dev/null 2>&1'

# remove auto generated ${GITLAB_DATA_DIR}/config/secrets.yml
rm -rf ${GITLAB_DATA_DIR}/config/secrets.yml

exec_as_git mkdir -p ${GITLAB_INSTALL_DIR}/tmp/pids/ ${GITLAB_INSTALL_DIR}/tmp/sockets/
chmod -R u+rwX ${GITLAB_INSTALL_DIR}/tmp

# symlink ${GITLAB_HOME}/.ssh -> ${GITLAB_LOG_DIR}/gitlab
rm -rf ${GITLAB_HOME}/.ssh
exec_as_git ln -sf ${GITLAB_DATA_DIR}/.ssh ${GITLAB_HOME}/.ssh

# symlink ${GITLAB_INSTALL_DIR}/log -> ${GITLAB_LOG_DIR}/gitlab
rm -rf ${GITLAB_INSTALL_DIR}/log
ln -sf ${GITLAB_LOG_DIR}/gitlab ${GITLAB_INSTALL_DIR}/log

# symlink ${GITLAB_INSTALL_DIR}/public/uploads -> ${GITLAB_DATA_DIR}/uploads
rm -rf ${GITLAB_INSTALL_DIR}/public/uploads
exec_as_git ln -sf ${GITLAB_DATA_DIR}/uploads ${GITLAB_INSTALL_DIR}/public/uploads

# symlink ${GITLAB_INSTALL_DIR}/.secret -> ${GITLAB_DATA_DIR}/.secret
rm -rf ${GITLAB_INSTALL_DIR}/.secret
exec_as_git ln -sf ${GITLAB_DATA_DIR}/.secret ${GITLAB_INSTALL_DIR}/.secret

# WORKAROUND for https://github.com/sameersbn/docker-gitlab/issues/509
rm -rf ${GITLAB_INSTALL_DIR}/builds
rm -rf ${GITLAB_INSTALL_DIR}/shared

# set correct selinux labels
#chcon -t user_home_dir_t ${GITLAB_HOME}

# install gitlab bootscript, to silence gitlab:check warnings
cp ${GITLAB_INSTALL_DIR}/lib/support/init.d/gitlab /etc/init.d/gitlab
chmod +x /etc/init.d/gitlab

# disable default nginx configuration and enable gitlab's nginx configuration
rm -rf /etc/nginx/conf.d/default.conf

# configure sshd
sed -i \
  -e "s|^[#]*UsePAM yes|UsePAM no|" \
  -e "s|^[#]*UsePrivilegeSeparation yes|UsePrivilegeSeparation no|" \
  -e "s|^[#]*PasswordAuthentication yes|PasswordAuthentication no|" \
  -e "s|^[#]*LogLevel INFO|LogLevel VERBOSE|" \
  /etc/ssh/sshd_config
echo "UseDNS no" >> /etc/ssh/sshd_config

# move supervisord.log file to ${GITLAB_LOG_DIR}/supervisor/
sed -i "s|^[#]*logfile=.*|logfile=${GITLAB_LOG_DIR}/supervisor/supervisord.log ;|" /etc/supervisord.conf

# move nginx logs to ${GITLAB_LOG_DIR}/nginx
sed -i \
  -e "s|access_log /var/log/nginx/access.log;|access_log ${GITLAB_LOG_DIR}/nginx/access.log;|" \
  -e "s|error_log /var/log/nginx/error.log;|error_log ${GITLAB_LOG_DIR}/nginx/error.log;|" \
  /etc/nginx/nginx.conf

# configure supervisord log rotation
cat > /etc/logrotate.d/supervisord <<EOF
${GITLAB_LOG_DIR}/supervisor/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab log rotation
cat > /etc/logrotate.d/gitlab <<EOF
${GITLAB_LOG_DIR}/gitlab/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab-shell log rotation
cat > /etc/logrotate.d/gitlab-shell <<EOF
${GITLAB_LOG_DIR}/gitlab-shell/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab vhost log rotation
cat > /etc/logrotate.d/gitlab-nginx <<EOF
${GITLAB_LOG_DIR}/nginx/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure supervisord to start unicorn
cat > /etc/supervisord.d/unicorn.ini <<EOF
[program:unicorn]
priority=10
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=scl enable rh-ruby22 'bundle exec unicorn_rails -c ${GITLAB_INSTALL_DIR}/config/unicorn.rb -E ${RAILS_ENV}'
user=git
autostart=true
autorestart=true
stopsignal=QUIT
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start sidekiq
cat > /etc/supervisord.d/sidekiq.ini <<EOF
[program:sidekiq]
priority=10
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=scl enable rh-ruby22 'bundle exec sidekiq -c {{SIDEKIQ_CONCURRENCY}}
  -q post_receive
  -q mailers
  -q archive_repo
  -q system_hook
  -q project_web_hook
  -q gitlab_shell
  -q incoming_email
  -q runner
  -q common
  -q default
  -e ${RAILS_ENV}
  -t {{SIDEKIQ_SHUTDOWN_TIMEOUT}}
  -P ${GITLAB_INSTALL_DIR}/tmp/pids/sidekiq.pid
  -L ${GITLAB_INSTALL_DIR}/log/sidekiq.log'
user=git
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start gitlab-workhorse
cat > /etc/supervisord.d/gitlab-workhorse.ini <<EOF
[program:gitlab-workhorse]
priority=20
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=/usr/local/bin/gitlab-workhorse
  -listenUmask 0
  -listenNetwork unix
  -listenAddr ${GITLAB_INSTALL_DIR}/tmp/sockets/gitlab-workhorse.socket
  -authBackend http://127.0.0.1:8080{{GITLAB_RELATIVE_URL_ROOT}}
  -authSocket ${GITLAB_INSTALL_DIR}/tmp/sockets/gitlab.socket
  -documentRoot ${GITLAB_INSTALL_DIR}/public
  -proxyHeadersTimeout {{GITLAB_WORKHORSE_TIMEOUT}}
user=git
autostart=true
autorestart=true
stdout_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
stderr_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
EOF

# configure supervisord to start mail_room
cat > /etc/supervisord.d/mail_room.ini <<EOF
[program:mail_room]
priority=20
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=scl enable rh-ruby22 'bundle exec mail_room -c ${GITLAB_INSTALL_DIR}/config/mail_room.yml'
user=git
autostart={{GITLAB_INCOMING_EMAIL_ENABLED}}
autorestart=true
stdout_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
stderr_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
EOF

# configure supervisor to start sshd
mkdir -p /var/run/sshd
cat > /etc/supervisord.d/sshd.ini <<EOF
[program:sshd]
directory=/
command=/usr/sbin/sshd -D -E ${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start nginx
cat > /etc/supervisord.d/nginx.ini <<EOF
[program:nginx]
priority=20
directory=/tmp
command=/usr/sbin/nginx -g "daemon off;"
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start crond
cat > /etc/supervisord.d/cron.ini <<EOF
[program:cron]
priority=20
directory=/tmp
command=/usr/sbin/crond -n
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# purge build dependencies and cleanup apt
yum remove -y gcc gcc-c++ patch cmake \
  glibc-devel ruby-devel community-mysql-devel postgresql-devel \
  zlib-devel libyaml-devel openssl-devel gdbm-devel readline-devel \
  ncurses-devel libxml2-devel libxslt-devel \
  libcurl-devel libicu-devel 
yum clean all
