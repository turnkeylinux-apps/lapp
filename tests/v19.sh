#!/bin/bash
set -Eeuo pipefail
umask 077

result=${TKL_TEST_RESULT:?TKL_TEST_RESULT is required}
db_password=${TKL_TEST_DB_PASS:?TKL_TEST_DB_PASS is required}
database=tkl_v19_smoke_$$
table=tkl_main_flow
document_root=/var/www
php_test=$document_root/tkl-v19-db.php
python_test=$document_root/cgi-bin/tkl-v19-python.cgi
password_file=/run/tkl-v19-tests/lapp-db-pass.$$
response=/tmp/tkl-lapp-response.$$
cookies=/tmp/tkl-lapp-adminer-cookies.$$

cleanup() {
    rm -f -- "$php_test" "$python_test" "$password_file" "$response" "$cookies"
    su postgres -c "dropdb --if-exists '$database'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

systemctl --quiet is-active apache2.service postgresql.service multi-user.target

apache_version=$(dpkg-query -W -f='${Version}' apache2)
php_version=$(dpkg-query -W -f='${Version}' libapache2-mod-php)
postgresql_version=$(dpkg-query -W -f='${Version}' postgresql)
adminer_version=$(dpkg-query -W -f='${Version}' adminer)
composer_version=$(dpkg-query -W -f='${Version}' composer)

curl --insecure --fail --silent --show-error https://127.0.0.1/ >"$response"
grep -q 'TurnKey LAPP' "$response"
curl --insecure --fail --silent --show-error \
    https://127.0.0.1/phpinfo.php >"$response"
grep -q 'PHP Version 8.4' "$response"
curl --insecure --fail --silent --show-error \
    https://127.0.0.1/server-status >"$response"
grep -q 'Apache Server Status' "$response"
curl --insecure --fail --silent --show-error \
    https://127.0.0.1/cgi-bin/test.cgi >"$response"
grep -q 'Hello, world.' "$response"

cat >"$python_test" <<'PYTHON'
#!/usr/bin/python3
print("Content-Type: text/plain\n")
print("python-cgi-ok")
PYTHON
chmod 0755 "$python_test"
curl --insecure --fail --silent --show-error \
    https://127.0.0.1/cgi-bin/tkl-v19-python.cgi >"$response"
grep -Fxq 'python-cgi-ok' "$response"

python3 -c 'import pg, psycopg2'
perl -MDBD::Pg -e 'exit 0'
php -m | grep -Fxq pgsql
command -v turnkey-composer >/dev/null
composer --version --no-ansi >/dev/null
dpkg-query -W webmin-apache webmin-phpini webmin-postgresql >/dev/null

su postgres -c "createdb '$database'"
su postgres -c "psql -v ON_ERROR_STOP=1 '$database'" <<SQL
CREATE TABLE $table (message text NOT NULL);
INSERT INTO $table VALUES ('database-backed-php-ok');
SQL
printf '%s' "$db_password" >"$password_file"
chown root:www-data "$password_file"
chmod 0640 "$password_file"
cat >"$php_test" <<PHP
<?php
\$password = file_get_contents('$password_file');
\$connection = pg_connect("host=127.0.0.1 dbname=$database user=postgres password=" . \$password);
if (!\$connection) { http_response_code(500); exit('connection-failed'); }
\$query = pg_query(\$connection, 'SELECT message FROM $table');
if (!\$query) { http_response_code(500); exit('query-failed'); }
header('Content-Type: text/plain');
echo pg_fetch_result(\$query, 0, 0);
?>
PHP
chmod 0644 "$php_test"
curl --insecure --fail --silent --show-error \
    https://127.0.0.1/tkl-v19-db.php >"$response"
grep -Fxq 'database-backed-php-ok' "$response"

test "$(su postgres -c "psql -Atqc 'SHOW password_encryption'")" = scram-sha-256
ss -ltn | awk '$4 ~ /^(127\.0\.0\.1|\[::1\]):5432$/ { found=1 } END { exit !found }'
if ss -ltn | awk '$4 ~ /^(0\.0\.0\.0|\[::\]):5432$/ { found=1 } END { exit !found }'; then
    echo 'PostgreSQL unexpectedly listens on all interfaces' >&2
    exit 1
fi
PGPASSWORD=$db_password psql --host=127.0.0.1 --username=postgres \
    --dbname=postgres --no-password --tuples-only --command='SELECT 1' |
    grep -q '1'

curl --insecure --fail --silent --show-error \
    https://127.0.0.1:12322/ >"$response"
grep -qi 'Adminer' "$response"
curl --insecure --silent --show-error --location \
    --cookie-jar "$cookies" --cookie "$cookies" \
    --data-urlencode 'auth[driver]=pgsql' \
    --data-urlencode 'auth[server]=localhost' \
    --data-urlencode 'auth[username]=postgres' \
    --data-urlencode "auth[password]=$db_password" \
    --data-urlencode 'auth[db]=postgres' \
    https://127.0.0.1:12322/ >"$response"
grep -qi 'PostgreSQL' "$response"
if grep -qi 'Invalid credentials\|Access denied' "$response"; then
    echo 'Adminer rejected the PostgreSQL credentials' >&2
    exit 1
fi

before="$apache_version|$php_version|$postgresql_version|$adminer_version|$composer_version"
apt-get update >/dev/null
for package in apache2 libapache2-mod-php postgresql adminer composer; do
    candidate=$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')
    test -n "$candidate"
    test "$candidate" != '(none)'
done
after="$(dpkg-query -W -f='${Version}' apache2)|$(dpkg-query -W -f='${Version}' libapache2-mod-php)|$(dpkg-query -W -f='${Version}' postgresql)|$(dpkg-query -W -f='${Version}' adminer)|$(dpkg-query -W -f='${Version}' composer)"
test "$after" = "$before"
test -f /etc/apt/sources.list.d/debian.sources
! grep -Rqi bookworm /etc/apt/sources.list /etc/apt/sources.list.d

cat >"$result" <<EOF
package_source=Debian 13 Trixie APT repositories for Apache, PHP, PostgreSQL, Adminer, Composer and language database clients; TurnKey APT for Webmin modules
installed_version=apache2 $apache_version; libapache2-mod-php $php_version; postgresql $postgresql_version; adminer $adminer_version; composer $composer_version
runtime_checks=normal init; Apache HTTPS landing page, PHP 8.4 and status; Perl and Python CGI; PostgreSQL local socket and password authentication; PHP PostgreSQL query; Adminer HTTPS and credential login; Composer and Webmin modules
updater_command=apt-get update; apt-cache policy apache2 libapache2-mod-php postgresql adminer composer
updater_result=signed metadata refreshed; eligible candidates found; installed versions unchanged
updater_channel=Debian Trixie and TurnKey Trixie APT repositories
integrity_evidence=APT accepted signed repository metadata through configured Deb822 sources and keyrings; no Bookworm source remained
EOF
