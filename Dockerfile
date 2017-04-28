#
# Dockerfile to build a MISP (https://github.com/MISP/MISP) container
#
# Original docker file by eg5846 (https://github.com/eg5846)
#
# 2016/03/03 - First release
# 
# To build your container:
#
# # git clone https://github.com/xme/misp-docker
# # docker build -t <tag> .

# We are based on Ubuntu:16.04
FROM ubuntu:16.04
MAINTAINER Xavier Mertens <xavier@rootshell.be>

# Set environment variables
ENV DEBIAN_FRONTEND noninteractive

# Preconfigure setting for packages
#RUN echo "postfix postfix/main_mailer_type string Local only" | debconf-set-selections 
#RUN echo "postfix postfix/mailname string localhost.localdomain" | debconf-set-selections

# Upgrade Ubuntu and install packages
RUN \
  apt-get update && \
  apt-get dist-upgrade -y && \
  apt-get install -y cron logrotate supervisor syslog-ng-core \
	libjpeg8-dev apache2 curl git less libapache2-mod-php make mysql-common mysql-client mysql-server php-gd \
	php-mysql php-dev php-pear php-redis postfix redis-server sudo tree vim zip openssl gnupg gnupg-agent  \
	php-mbstring whois python-zmq python-redis \
	python-dev python-pip libxml2-dev libxslt-dev zlib1g-dev \
	php-crypt-gpg php-geoip \
	python3 python3-pip && \
  apt-get autoremove -y && \
  apt-get clean

# Modify syslog configuration
RUN \
  sed -i -E 's/^(\s*)system\(\);/\1unix-stream("\/dev\/log");/' /etc/syslog-ng/syslog-ng.conf

# -----------
# MySQL Setup
# -----------
VOLUME /var/lib/mysql

# -----------
# Redis Setup
# -----------
RUN sed -i 's/^\(daemonize\s*\)yes\s*$/\1no/g' /etc/redis/redis.conf

# Install PEAR packages
#RUN \
#  pear install Crypt_GPG && \
#  pear install Net_GeoIP

# ---------------
# MISP Core Setup
# ---------------
RUN \
  cd /var/www && \
  git clone https://github.com/MISP/MISP.git && \
  cd /var/www/MISP && \
  git config core.filemode false

# Install Mitre's STIX and its dependencies by running the following commands:
RUN \
  cd /var/www/MISP/app/files/scripts && \
  git clone https://github.com/CybOXProject/python-cybox.git && \
  git clone https://github.com/STIXProject/python-stix.git && \
  cd /var/www/MISP/app/files/scripts/python-cybox && \
  git checkout v2.1.0.12 && \
  python setup.py install && \
  cd /var/www/MISP/app/files/scripts/python-stix && \
  git checkout v1.1.1.4 && \
  python setup.py install

# CakePHP is now included as a submodule of MISP, execute the following commands to let git fetch it
RUN \
  cd /var/www/MISP && \
  git submodule init && \
  git submodule update

# Once done, install the dependencies of CakeResque if you intend to use the built in background jobs
RUN \
  cd /var/www/MISP/app && \
  curl -s https://getcomposer.org/installer | php && \
  php composer.phar require kamisama/cake-resque:4.1.2 && \
  php composer.phar config vendor-dir Vendor && \
  php composer.phar install

# To use the scheduler worker for scheduled tasks, do the following
RUN cp -fa /var/www/MISP/INSTALL/setup/config.php /var/www/MISP/app/Plugin/CakeResque/Config/config.php

# Check if the permissions are set correctly using the following commands as root
RUN \
  chown -R www-data:www-data /var/www/MISP && \
  chmod -R 750 /var/www/MISP && \
  cd /var/www/MISP/app && \
  chmod -R g+ws tmp && \
  chmod -R g+ws files && \
  chmod -R g+ws files/scripts/tmp

# ------------
# Apache Setup
# ------------

RUN cp /var/www/MISP/INSTALL/apache.misp.ubuntu /etc/apache2/sites-available/misp.conf && \
	a2dissite 000-default && \
	a2ensite misp && \
	a2enmod rewrite && \
	a2enmod ssl && \
	mkdir -p /etc/apache2/ssl && \
	cd /etc/apache2/ssl && \
	openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout misp.key -out misp.crt -batch && \
	sed -i -E "s/\VirtualHost\s\*:80/VirtualHost *:443/" /etc/apache2/sites-enabled/misp.conf && \
	sed -i -E "s/ServerSignature\sOff/ServerSignature Off\n\tSSLEngine On\n\tSSLCertificateFile \/etc\/apache2\/ssl\/misp.crt\n\tSSLCertificateKeyFile \/etc\/apache2\/ssl\/misp.key/" /etc/apache2/sites-enabled/misp.conf

# ------------------
# MISP Configuration
# ------------------
ADD gpg/.gnupg /var/www/MISP/.gnupg
ADD gpg/gpg.asc /var/www/MISP/app/webroot/gpg.asc

RUN \
  chown -R www-data:www-data /var/www/MISP/.gnupg && \
  chmod 700 /var/www/MISP/.gnupg && \
  chmod 0600 /var/www/MISP/.gnupg/* && \
  chown www-data:www-data /var/www/MISP/app/webroot/gpg.asc && \
  chmod 0644 /var/www/MISP/app/webroot/gpg.asc

# Create boostrap.php
RUN \
  cp /var/www/MISP/app/Config/bootstrap.default.php /var/www/MISP/app/Config/bootstrap.php && \
  chown www-data:www-data /var/www/MISP/app/Config/bootstrap.default.php && \
  chmod 0750 /var/www/MISP/app/Config/bootstrap.default.php

# Create a config.php
RUN \
  cp /var/www/MISP/app/Config/config.default.php /var/www/MISP/app/Config/config.php && \
  chown www-data:www-data /var/www/MISP/app/Config/config.php && \
  chmod 0750 /var/www/MISP/app/Config/config.php

# Replace the default salt
RUN \
  cd /var/www/MISP/app/Config && \
  sed -i -E "s/'salt'\s=>\s'(\S+)'/'salt' => '`openssl rand -base64 32|tr "/" "-"`'/" config.php

# ------------------------------------
# Install MISP Modules (New in 2.4.28)
# ------------------------------------
RUN \
  cd /opt && \
  git clone https://github.com/MISP/misp-modules.git && \
  cd misp-modules && \
  pip3 install --upgrade -r REQUIREMENTS && \
  pip3 install --upgrade .

# Create supervisor.conf
ADD supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Add run script
ADD run.sh /run.sh
RUN chmod 0755 /run.sh

# Trigger to perform first boot operations
ADD env.txt /.firstboot.tmp

# Set the working directory to the MISP home directory
WORKDIR /var/www/MISP

# Set the gpg home dir so we don't have to use --homedir on the command line
# Note: su -s /bin/bash www-data before running any gpg commands in the container
#       to avoid messing up the file ownership
ENV GNUPGHOME /var/www/MISP/.gnupg

EXPOSE 443
CMD ["/run.sh"]
