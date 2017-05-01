#!/bin/bash

set -e

function log_heading ()
{
	echo '[*]' $@
}

function log_info ()
{
	#echo ' +' $@
	echo ' `->' $@
}

if [ -r /.firstboot.tmp ]; then

	log_heading "Initial docker configuration"

	. /.firstboot.tmp

	log_heading "Configuring MySQL"

	# Set MYSQL_ROOT_PASSWORD
	if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
		log_info "MYSQL_ROOT_PASSWORD is not set, use default value 'root'"
		MYSQL_ROOT_PASSWORD=root
	else
		log_info "MYSQL_ROOT_PASSWORD is set to '$MYSQL_ROOT_PASSWORD'" 
	fi

	# Set MYSQL_MISP_PASSWORD
	if [ -z "$MYSQL_MISP_PASSWORD" ]; then
		log_info "MYSQL_MISP_PASSWORD is not set, use default value 'misp'"
		MYSQL_MISP_PASSWORD=misp
	else
		log_info "MYSQL_MISP_PASSWORD is set to '$MYSQL_MISP_PASSWORD'"
	fi

	# Initialize the MySQL database directory if needed.  It will be empty
	# if the container was started with -v <some dir>:/var/lib/mysql
	if [ ! -d /var/lib/mysql/mysql ]; then
		log_info "/var/lib/mysql is empty.  Creating a new MySQL database."
		mysqld --initialize-insecure
	fi
	
	# Create a database and user  
	log_info "Starting MySQL"
	service mysql start

	# If the MySQL root password is empty, this is a fresh install, and we need to set it
	log_info "Setting MySQL root password to $MYSQL_ROOT_PASSWORD"
	mysqladmin password $MYSQL_ROOT_PASSWORD >/dev/null 2>&1 | true

	# Add the debian-sys-maint user so init scripts and log rotation will work.  This
	# step is redundant if we didn't just create a new database, but it doesn't hurt.
	log_info "Fixing debian-sys-maint account"
	SYS_MAINT_PASSWORD=`grep -m 1 password /etc/mysql/debian.cnf | awk '{print $3}'`
	mysql -u root --password="$MYSQL_ROOT_PASSWORD" \
		-e "GRANT ALL PRIVILEGES on *.* TO 'debian-sys-maint'@'localhost' IDENTIFIED BY '$SYS_MAINT_PASSWORD' WITH GRANT OPTION; FLUSH PRIVILEGES;"

	ret=`mysql -u root --password="$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 -P 3306 -e 'SHOW DATABASES'`
	if [ $? -eq 0 ]; then
		log_info "Connected to database successfully!"
		found=0
		for db in $ret; do
			if [ "$db" == "misp" ]; then
				found=1
			fi    
		done
		if [ $found -eq 1 ]; then
			log_info "Database misp found"
		else
			log_info "Database misp not found.  Creating now one."
			cat > /tmp/create_misp_database.sql <<-EOSQL
create database misp;
grant usage on *.* to misp identified by "$MYSQL_MISP_PASSWORD";
grant all privileges on misp.* to misp;
EOSQL
			ret=`mysql -u root --password="$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 -P 3306 2>&1 < /tmp/create_misp_database.sql`
			if [ $? -eq 0 ]; then
				log_info "Created database misp successfully!"

				log_info "Importing /var/www/MISP/INSTALL/MYSQL.sql"
				ret=`mysql -u misp --password="$MYSQL_MISP_PASSWORD" misp -h 127.0.0.1 -P 3306 2>&1 < /var/www/MISP/INSTALL/MYSQL.sql`
				if [ $? -eq 0 ]; then
					log_info "Imported /var/www/MISP/INSTALL/MYSQL.sql successfully"
				else
					log_info "ERROR: Importing /var/www/MISP/INSTALL/MYSQL.sql failed:"
					log_info $ret
				fi
			else
				log_info "ERROR: Creating database misp failed:"
				log_info $ret
			fi    
		fi
	else
		log_info "ERROR: Connecting to database failed:"
		log_info $ret
	fi

	# Stop the MySQL server here because we're going to let
	# supervisord manage the process instead.
	service mysql stop

	# MISP configuration
	log_heading "Creating MISP configuration files"
	cp -an /var/www/MISP/app/.Config.dist/* /var/www/MISP/app/Config/
	cd /var/www/MISP/app/Config
	if [ ! -f /var/www/MISP/app/Config/database.php ]; then
		log_info "Creating a default database.php"
		cp -a database.default.php database.php
		sed -i "s/localhost/127.0.0.1/" database.php
		sed -i "s/db\s*login/misp/" database.php
		sed -i "s/8889/3306/" database.php
		sed -i "s/db\s*password/$MYSQL_MISP_PASSWORD/" database.php
	else
		log_info "Using existing database configuration"
	fi

	cp -an core.default.php core.php

	chown -R www-data:www-data /var/www/MISP/app/Config
	chmod -R 750 /var/www/MISP/app/Config

	# Check to see if config.php exists. If not, generate a new one.
	if [ ! -f /var/www/MISP/app/Config/config.php ]; then
		echo "Setting default MISP configuration"
		export MISP_BASEURL
		export MISP_EMAIL
		export MISP_CONTACT
		export MISP_ADMIN_EMAIL
		export MISP_GPG_PASSPHRASE
		export MISP_SALT
		echo '<?php
include "/var/www/MISP/app/Config/config.default.php";
$config["MISP"]["baseurl"]   = $_SERVER["MISP_BASEURL"];
$config["MISP"]["email"]     = $_SERVER["MISP_EMAIL"];
$config["MISP"]["contact"]   = $_SERVER["MISP_CONTACT"];
$config["Security"]["salt"]  = $_SERVER["MISP_SALT"];
$config["GnuPG"]["email"]    = $_SERVER["MISP_ADMIN_EMAIL"];
$config["GnuPG"]["password"] = $_SERVER["MISP_GPG_PASSPHRASE"];
$config["GnuPG"]["homedir"]  = "/var/www/MISP/.gnupg";
$config["Plugin"]["ZeroMQ_enable"] = true;
$config["Plugin"]["Enrichment_services_enable"] = true;
$config["Plugin"]["Import_services_enable"] = true;
$config["Plugin"]["Export_services_enable"] = true;
print "<?php\n\$config = ";
print var_export($config);
print ";\n";
' > /tmp/setup.php
		/usr/bin/php /tmp/setup.php > /var/www/MISP/app/Config/config.php
		chown www-data:www-data /var/www/MISP/app/Config/config.php
		chmod 0750 /var/www/MISP/app/Config/config.php
	else
		log_info "Not creating a new MISP config because one already exists in /var/www/MISP/app/Config/"
	fi

	# Fix php.ini with recommended settings
	log_heading "Optimizing php.ini (based on MISP recommendations) ..."
	sed -i "s/max_execution_time = 30/max_execution_time = 300/" /etc/php/7.0/apache2/php.ini
	sed -i "s/memory_limit = 128M/memory_limit = 512M/" /etc/php/7.0/apache2/php.ini
	sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 50M/" /etc/php/7.0/apache2/php.ini
	sed -i "s/post_max_size = 8M/post_max_size = 50M/" /etc/php/7.0/apache2/php.ini

	# Configure postfix
	log_heading "Configuring postfix"
	if [ ! -z "$POSTFIX_MAILNAME" ]; then
		log_info "Setting postfix mailname"
		sed -i -e "s/^myhostname.*/myhostname = $POSTFIX_MAILNAME/" /etc/postfix/main.cf
	fi
	if [ ! -z "$POSTFIX_RELAY" ]; then
		log_info "Setting postfix relay"
		sed -i -e "s/^relayhost.*/relayhost = $POSTFIX_RELAY/" /etc/postfix/main.cf
	fi

	log_heading "Configuring GPG"
	# Generate the admin user PGP key
	if [ ! -f /var/www/MISP/.gnupg/secring.gpg ]; then
		if [ -z "$MISP_ADMIN_EMAIL" -o -z "$MISP_GPG_PASSPHRASE" ]; then
			log_info "No admin details provided, don't forget to generate the PGP key manually!"
		else
			log_info "Generating admin PGP key ... (please be patient, we need some entropy)"
			chown www-data.www-data /var/www/MISP/.gnupg
			chmod 700 /var/www/MISP/.gnupg
			cat >/tmp/gpg.tmp <<GPGEOF
%echo Generating a basic OpenPGP key
Key-Type: RSA
Key-Length: 2048
Name-Real: MISP Admin
Name-Email: $MISP_ADMIN_EMAIL
Expire-Date: 0
Passphrase: $MISP_GPG_PASSPHRASE
%commit
%echo Done
GPGEOF
			sudo -u www-data gpg --homedir /var/www/MISP/.gnupg --gen-key --batch /tmp/gpg.tmp >/dev/null 2>&1
			rm -f /tmp/gpg.tmp
		fi
	else
		log_info "A secret keyring already exists in /var/www/MISP/.gnupg"
	fi
	log_info "Copying public key for $MISP_ADMIN_EMAIL into the web root"
	sudo -u www-data gpg --homedir /var/www/MISP/.gnupg --armor --export $MISP_ADMIN_EMAIL > /var/www/MISP/app/webroot/gpg.asc

	log_heading "Configuring ZMQ"
	echo '{"redis_host":"localhost","redis_port":"6379","redis_password":"","redis_database":"1","redis_namespace":"mispq","port":50000}' > /var/www/MISP/app/files/scripts/mispzmq/settings.json
	chown www-data.www-data /var/www/MISP/app/files/scripts/mispzmq/settings.json

	# Display tips
	cat <<__WELCOME__
Congratulations!
Your MISP docker has been successfully booted for the first time.
You may now log in via https using the default credentials.

Username: admin@admin.test
Password: admin

__WELCOME__
	rm -f /.firstboot.tmp
fi

# Start supervisord 
log_heading "Starting supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
