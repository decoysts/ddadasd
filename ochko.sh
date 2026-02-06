#!/bin/bash

# =================================================================
# FIXED HA CLUSTER DEPLOYMENT (SHELL SQL EDITION)
# =================================================================

# --- 0. НАСТРОЙКИ IP ---
LB_IP="192.168.4.10"
WEB1_IP="192.168.4.11"
WEB2_IP="192.168.4.12"
DB1_IP="192.168.4.21"
DB2_IP="192.168.4.22"

# Пароли
DB_ROOT_PASS="password3204"
WP_DB_PASS="wppassword"
HAPROXY_CHECK_PASS="haproxypass"

echo ">>> [INIT] Начинаем развертывание. Режим: Hardcore Shell SQL..."

# --- 1. ЛОКАЛЬНАЯ ПОДГОТОВКА ---
echo ">>> [LOCAL] Фикс репозиториев и установка Ansible..."

# Жесткий фикс репо на локальной машине
sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS*
sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/CentOS*
sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/CentOS*

yum install -y epel-release
yum install -y ansible sshpass

# --- 2. ГЕНЕРАЦИЯ ИНВЕНТАРЯ ---
echo ">>> [INVENTORY] Генерация хостов..."
cat <<EOF > /etc/ansible/hosts
[all_servers]
$LB_IP
$WEB1_IP
$WEB2_IP
$DB1_IP
$DB2_IP

[loadbalancer]
$LB_IP

[webservers]
$WEB1_IP
$WEB2_IP

[dbservers]
$DB1_IP
$DB2_IP

[db_primary]
$DB1_IP
EOF

cat <<EOF > /etc/ansible/ansible.cfg
[defaults]
host_key_checking = False
deprecation_warnings = False
command_warnings = False
forks = 10
EOF

# --- 3. COMMON SETUP (ФИКС РЕПО ВЕЗДЕ) ---
cat <<EOF > /etc/ansible/00_common.yml
---
- name: Prepare Servers
  hosts: all_servers
  become: yes
  tasks:
    - name: Fix CentOS 7 Repos (Vault)
      shell: |
        sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS*
        sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/CentOS*
        sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/CentOS*
      args:
        warn: no

    - name: Install Base Packages
      yum:
        name: [epel-release, nano, wget, net-tools, rsync, socat]
        state: present

    - name: Disable SELinux
      shell: |
        setenforce 0 || true
        sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
EOF

# --- 4. GALERA CLUSTER (SHELL SQL MODE) ---
cat <<EOF > /etc/ansible/01_galera.yml
---
- name: Install MariaDB 10.11
  hosts: dbservers
  become: yes
  vars:
    node1_ip: "$DB1_IP"
    node2_ip: "$DB2_IP"

  tasks:
    - name: Clean old mariadb libs
      yum:
        name: mariadb-libs
        state: absent

    - name: Add MariaDB Repo
      copy:
        dest: /etc/yum.repos.d/mariadb.repo
        content: |
          [mariadb]
          name = MariaDB
          baseurl = http://yum.mariadb.org/10.11/centos7-amd64
          gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
          gpgcheck=1

    - name: Install MariaDB Server
      yum:
        name: [MariaDB-server, MariaDB-client, MariaDB-shared, MariaDB-backup]
        state: present

    - name: Setup Firewall
      firewalld:
        port: "{{ item }}"
        permanent: yes
        state: enabled
        immediate: yes
      loop:
        - 3306/tcp
        - 4567/tcp
        - 4568/tcp
        - 4444/tcp
        - 4567/udp

    - name: Configure server.cnf
      blockinfile:
        path: /etc/my.cnf.d/server.cnf
        create: yes
        block: |
          [galera]
          wsrep_on=ON
          wsrep_provider=/usr/lib64/galera-4/libgalera_smm.so
          wsrep_cluster_address="gcomm://{{ node1_ip }},{{ node2_ip }}"
          wsrep_cluster_name="galera_cluster"
          wsrep_node_address="{{ ansible_default_ipv4.address }}"
          wsrep_node_name="{{ ansible_hostname }}"
          binlog_format=row
          default_storage_engine=InnoDB
          innodb_autoinc_lock_mode=2
          bind-address=0.0.0.0

    - name: Stop MariaDB explicitly before bootstrap
      systemd:
        name: mariadb
        state: stopped

# --- ЭТАП ЗАПУСКА КЛАСТЕРА ---

- name: Bootstrap Primary Node
  hosts: db_primary
  become: yes
  tasks:
    - name: Run galera_new_cluster
      command: galera_new_cluster

    - name: Wait for MariaDB socket
      wait_for:
        path: /var/lib/mysql/mysql.sock
        timeout: 30

- name: Join Secondary Nodes
  hosts: dbservers:!db_primary
  become: yes
  tasks:
    - name: Start MariaDB (Join)
      systemd:
        name: mariadb
        state: started

# --- ЭТАП НАСТРОЙКИ ПОЛЬЗОВАТЕЛЕЙ (SHELL SQL) ---
# Выполняем ТОЛЬКО на мастере, Галера сама реплицирует юзеров на слейва

- name: Configure Users and DBs (Shell Mode)
  hosts: db_primary
  become: yes
  vars:
    root_pass: "$DB_ROOT_PASS"
    wp_pass: "$WP_DB_PASS"
    haproxy_pass: "$HAPROXY_CHECK_PASS"
  tasks:
    - name: Reset Root Password & Create Users (Raw SQL)
      shell: |
        mysql -u root -e "
        -- Создаем базу WP
        CREATE DATABASE IF NOT EXISTS wordpress_db;
        
        -- Создаем юзера WP (доступ отовсюду %)
        CREATE USER IF NOT EXISTS 'wp_user'@'%' IDENTIFIED BY '{{ wp_pass }}';
        GRANT ALL PRIVILEGES ON wordpress_db.* TO 'wp_user'@'%';
        
        -- Создаем юзера для HAProxy (без пароля или с паролем, тут сделаем простым)
        CREATE USER IF NOT EXISTS 'haproxy'@'%' IDENTIFIED BY '{{ haproxy_pass }}';
        
        -- Обновляем рута (если еще не задан)
        ALTER USER 'root'@'localhost' IDENTIFIED BY '{{ root_pass }}';
        
        FLUSH PRIVILEGES;"
      ignore_errors: yes
EOF

# --- 5. HAPROXY ---
cat <<EOF > /etc/ansible/02_haproxy.yml
---
- name: Deploy HAProxy
  hosts: loadbalancer
  become: yes
  vars:
    db1: "$DB1_IP"
    db2: "$DB2_IP"
    web1: "$WEB1_IP"
    web2: "$WEB2_IP"
  
  tasks:
    - name: Install HAProxy
      yum:
        name: haproxy
        state: present

    - name: Config HAProxy
      copy:
        dest: /etc/haproxy/haproxy.cfg
        content: |
          global
              log 127.0.0.1 local2
              chroot /var/lib/haproxy
              pidfile /var/run/haproxy.pid
              maxconn 4000
              user haproxy
              group haproxy
              daemon

          defaults
              mode http
              log global
              option httplog
              option dontlognull
              timeout connect 5000
              timeout client 50000
              timeout server 50000

          frontend main_http
              bind *:80
              default_backend web_nodes

          backend web_nodes
              balance roundrobin
              server web1 {{ web1 }}:80 check
              server web2 {{ web2 }}:80 check

          listen mariadb_galera
              bind *:3306
              mode tcp
              balance source
              # Проверка через mysql-check с юзером haproxy
              option mysql-check user haproxy
              server db1 {{ db1 }}:3306 check
              server db2 {{ db2 }}:3306 check

          listen stats
              bind *:8404
              stats enable
              stats uri /monitor
              stats auth admin:admin

    - name: Open Ports
      firewalld:
        port: "{{ item }}"
        permanent: yes
        state: enabled
        immediate: yes
      loop:
        - 80/tcp
        - 3306/tcp
        - 8404/tcp

    - name: Restart HAProxy
      systemd:
        name: haproxy
        state: restarted
        enabled: yes
EOF

# --- 6. WORDPRESS ---
cat <<EOF > /etc/ansible/03_wordpress.yml
---
- name: Install WP
  hosts: webservers
  become: yes
  vars:
    lb_ip: "$LB_IP"
    wp_pass: "$WP_DB_PASS"

  tasks:
    - name: Install Apache/PHP
      yum:
        name: [httpd, php, php-mysql, php-gd, wget, unarchive]
        state: present

    - name: Firewall HTTP
      firewalld:
        service: http
        permanent: yes
        state: enabled
        immediate: yes

    - name: Start Apache
      systemd:
        name: httpd
        state: started
        enabled: yes

    - name: Download WP
      unarchive:
        src: https://wordpress.org/latest.tar.gz
        dest: /var/www/html/
        remote_src: yes
        extra_opts: [--strip-components=1]
        creates: /var/www/html/index.php

    - name: Config WP
      copy:
        dest: /var/www/html/wp-config.php
        content: |
          <?php
          define( 'DB_NAME', 'wordpress_db' );
          define( 'DB_USER', 'wp_user' );
          define( 'DB_PASSWORD', '{{ wp_pass }}' );
          define( 'DB_HOST', '{{ lb_ip }}' ); 
          define( 'DB_CHARSET', 'utf8' );
          define( 'DB_COLLATE', '' );
          \$table_prefix = 'wp_';
          define( 'WP_DEBUG', false );
          if ( ! defined( 'ABSPATH' ) ) define( 'ABSPATH', __DIR__ . '/' );
          require_once ABSPATH . 'wp-settings.php';

    - name: Permissions
      shell: chown -R apache:apache /var/www/html
EOF

# --- ЗАПУСК ---
echo "----------------------------------------------------"
echo ">>> ЗАПУСК ПЛЕЙБУКОВ..."

ansible-playbook /etc/ansible/00_common.yml
ansible-playbook /etc/ansible/01_galera.yml
ansible-playbook /etc/ansible/02_haproxy.yml
ansible-playbook /etc/ansible/03_wordpress.yml

echo "----------------------------------------------------"
echo "ГОТОВО. ПРОВЕРКА:"
echo "1. Зайди на http://$LB_IP:8404/monitor (admin:admin) и убедись, что SQL сервера зеленые."
echo "2. Если базы красные в HAProxy - проверь, создался ли юзер: mysql -u haproxy -h $DB1_IP"
echo "3. Сайт: http://$LB_IP"
echo "----------------------------------------------------"
