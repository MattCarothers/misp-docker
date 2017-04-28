MISP Docker
===========

The files in this repository are used to create a Docker container running a [MISP](http://www.misp-project.org) ("Malware Information Sharing Platform") instance.

All the required components (MySQL, Apache, Redis, ...) are running in a single Docker. At first run, most of the setup is automated but some small steps must be performed manually after the initial run.

The build is based on Ubuntu and will install all the required components. The following configuration steps are performed automatically:
* Reconfiguration of the base URL in `config.php`
* Generation of a self-signed certificate and reconfiguration of the vhost to offer SSL support
* Optimization of the PHP environment (php.ini) to match the MISP recommended values
* Creation of the MySQL database
* Generation of the admin PGP key

# Building the image

```
# git clone https://github.com/MattCarothers/misp-docker
# cd misp-docker

Edit env.txt to set configuration options for the image.

# cat env.txt
# MySQL passwords
MYSQL_ROOT_PASSWORD=my_strong_root_pw
MYSQL_MISP_PASSWORD=my_strong_misp_pw

# Email and passphrase for the PGP keys MISP will use to sign outgoing emails.
# Note that this is the email address to which the key is tied and not the
# one used as a From address or the one used as the default admin login.
MISP_ADMIN_EMAIL=admin@admin.test
MISP_GPG_PASSPHRASE=abc123

# If you don't provide a base URL, MISP will set it to
# the URL you use when you log in for the first time.
MISP_BASEURL=https://misp.local

# If you don't provide a salt, MISP will generate one automatically
MISP_SALT=your_salt_here

# Mailname and relay for postfix.  If you don't set them, the mailname will
# be a docker-generated random hostname, which may or may not impact your
# MISP's ability to delivery email past spam filters.
POSTFIX_MAILNAME=misp.local
POSTFIX_RELAY=smtp.local

# docker build -t misp/misp .
```

Then boot the container:
```
# docker run -d -p 443:443 -v /dev/urandom:/dev/random --restart=always --name misp misp/misp
```

Note: the volume mapping is /dev/urandom is required to generate enough entropy to create the PGP key.

If you wish for the MySQL database to live outside the container, you'll want to map a volume:
```
# docker run -d -p 443:443 -v /dev/urandom:/dev/random -v /opt/misp/mysql:/var/lib/mysql --restart=always --name misp misp/misp
```

If you have a real TLS certificate and want to use that instead of the self-signed cert, name your certificate "misp.crt" and your key "misp.key," and put them in a volume mapped to /etc/apache2/ssl:
```
# docker run -d -p 443:443 -v /dev/urandom:/dev/random -v /opt/misp/certs:/etc/apache2/ssl --restart=always --name misp misp/misp
```

# Post-boot steps

Once the container starts, you can execute a shell in it like so:
```
# docker exec -it misp bash
```

# Usage

Point your browser to `https://<your-docker-server>`. The default credentials remain the same:  `admin@admin.test` with `admin` as password.
To use MISP, refer to the official documentation: http://www.misp-project.org/documentation/
