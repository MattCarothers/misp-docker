#!/bin/bash

set -e

if [ -r /.firstboot.tmp ]; then

	echo "Initial docker configuration, please be patient ..."

	. /.firstboot.tmp

	# Set MYSQL_ROOT_PASSWORD
	if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
		echo "MYSQL_ROOT_PASSWORD is not set, use default value 'root'"
		MYSQL_ROOT_PASSWORD=root
	else
		echo "MYSQL_ROOT_PASSWORD is set to '$MYSQL_ROOT_PASSWORD'" 
	fi

	# Set MYSQL_MISP_PASSWORD
	if [ -z "$MYSQL_MISP_PASSWORD" ]; then
		echo "MYSQL_MISP_PASSWORD is not set, use default value 'misp'"
		MYSQL_MISP_PASSWORD=misp
	else
		echo "MYSQL_MISP_PASSWORD is set to '$MYSQL_MISP_PASSWORD'"
	fi

	# Initialize the MySQL database directory if needed.  It will be empty
	# if the container was started with -v <some dir>:/var/lib/mysql
	if [ ! -d /var/lib/mysql/mysql ]; then
		echo "Initializing database ..."
		mysqld --initialize-insecure
	fi
	
	# Create a database and user  
	echo "Connecting to database and setting passwords ..."
	service mysql start

	# If the MySQL root password is empty, this is a fresh install, and we need to set it
	mysqladmin password $MYSQL_ROOT_PASSWORD >/dev/null 2>&1 | true

	# Add the debian-sys-maint user so init scripts and log rotation will work.  This
	# step is redundant if we didn't just create a new database, but it doesn't hurt.
	SYS_MAINT_PASSWORD=`grep -m 1 password /etc/mysql/debian.cnf | awk '{print $3}'`
	mysql -u root --password="$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES on *.* TO 'debian-sys-maint'@'localhost' IDENTIFIED BY '$SYS_MAINT_PASSWORD' WITH GRANT OPTION; FLUSH PRIVILEGES;"

	ret=`echo 'SHOW DATABASES;' | mysql -u root --password="$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 -P 3306 # 2>&1`

	if [ $? -eq 0 ]; then
		echo "Connected to database successfully!"
		found=0
		for db in $ret; do
			if [ "$db" == "misp" ]; then
				found=1
			fi    
		done
		if [ $found -eq 1 ]; then
			echo "Database misp found"
		else
			echo "Database misp not found, creating now one ..."
			cat > /tmp/create_misp_database.sql <<-EOSQL
create database misp;
grant usage on *.* to misp identified by "$MYSQL_MISP_PASSWORD";
grant all privileges on misp.* to misp;
EOSQL
			ret=`mysql -u root --password="$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 -P 3306 2>&1 < /tmp/create_misp_database.sql`
			if [ $? -eq 0 ]; then
				echo "Created database misp successfully!"

				echo "Importing /var/www/MISP/INSTALL/MYSQL.sql ..."
				ret=`mysql -u misp --password="$MYSQL_MISP_PASSWORD" misp -h 127.0.0.1 -P 3306 2>&1 < /var/www/MISP/INSTALL/MYSQL.sql`
				if [ $? -eq 0 ]; then
					echo "Imported /var/www/MISP/INSTALL/MYSQL.sql successfully"
				else
					echo "ERROR: Importing /var/www/MISP/INSTALL/MYSQL.sql failed:"
					echo $ret
				fi
				service mysql stop >/dev/null 2>&1
			else
				echo "ERROR: Creating database misp failed:"
				echo $ret
			fi    
		fi
	else
		echo "ERROR: Connecting to database failed:"
		echo $ret
	fi

	# Stop the MySQL server here because we're going to let
	# supervisord manage the process instead.
	service mysql stop

	# MISP configuration
	echo "Creating MISP configuration files ..."
	cp -an /var/www/MISP/app/.Config.dist/* /var/www/MISP/app/Config/
	cd /var/www/MISP/app/Config
	cp -a database.default.php database.php
	sed -i "s/localhost/127.0.0.1/" database.php
	sed -i "s/db\s*login/misp/" database.php
	sed -i "s/8889/3306/" database.php
	sed -i "s/db\s*password/$MYSQL_MISP_PASSWORD/" database.php

	cp -a core.default.php core.php

	chown -R www-data:www-data /var/www/MISP/app/Config
	chmod -R 750 /var/www/MISP/app/Config

	# Fix php.ini with recommended settings
	echo "Optimizing php.ini (based on MISP recommendations) ..."
	sed -i "s/max_execution_time = 30/max_execution_time = 300/" /etc/php/7.0/apache2/php.ini
	sed -i "s/memory_limit = 128M/memory_limit = 512M/" /etc/php/7.0/apache2/php.ini
	sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 50M/" /etc/php/7.0/apache2/php.ini
	sed -i "s/post_max_size = 8M/post_max_size = 50M/" /etc/php/7.0/apache2/php.ini

	# Configure postfix
	if [ ! -z "$POSTFIX_MAILNAME" ]; then
		echo "Setting postfix mailname"
		sed -i -e "s/^myhostname.*/myhostname = $POSTFIX_MAILNAME/" /etc/postfix/main.cf
	fi
	if [ ! -z "$POSTFIX_RELAY" ]; then
		echo "Setting postfix relay"
		sed -i -e "s/^relayhost.*/relayhost = $POSTFIX_RELAY/" /etc/postfix/main.cf
	fi

	# Generate the admin user PGP key
	if [ -z "$MISP_ADMIN_EMAIL" -o -z "$MISP_GPG_PASSPHRASE" ]; then
		echo "No admin details provided, don't forget to generate the PGP key manually!"
	else
		echo "Generating admin PGP key ... (please be patient, we need some entropy)"
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
	if [ -z "`diff -q /var/www/MISP/app/Config/config.default.php /var/www/MISP/app/Config/config.php`" ]; then
		echo "Setting default MISP configuration"
		export MISP_BASEURL
		export MISP_ADMIN_EMAIL
		export MISP_GPG_PASSPHRASE
		export MISP_SALT
		echo '<?php
include "/var/www/MISP/app/Config/config.default.php";
$config["MISP"]["baseurl"] = $_SERVER["MISP_BASEURL"];
$config["Security"]["salt"] = $_SERVER["MISP_SALT"];
$config["GnuPG"]["email"] = $_SERVER["MISP_ADMIN_EMAIL"];
$config["GnuPG"]["password"] = $_SERVER["MISP_GPG_PASSPHRASE"];
$config["GnuPG"]["homedir"] = "/var/www/MISP/.gnupg";
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
		echo "A non-default MISP configuration already exists in /var/www/MISP/app/Config/"
	fi

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
echo "Starting supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
