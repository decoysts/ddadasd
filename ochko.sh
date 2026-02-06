#!/bin/bash

# =================================================================
# ULTIMATE HA CLUSTER DEPLOYMENT SCRIPT (REMASTERED)
# Fixes: Dead CentOS 7 Repos on ALL nodes, SELinux disabled, MariaDB 10.11
# =================================================================

# --- 0. НАСТРОЙКИ IP (ПРОВЕРЬ ПЕРЕД ЗАПУСКОМ!) ---
# Балансировщик
LB_IP="192.168.4.10"

# Веб-сервера (WordPress)
WEB1_IP="192.168.4.11"
WEB2_IP="192.168.4.12"

# Базы данных (Galera Cluster)
DB1_IP="192.168.4.21"
DB2_IP="192.168.4.22"

# Пароли
DB_ROOT_PASS="password3204"
WP_DB_PASS="wppassword"
HAPROXY_CHECK_PASS="haproxypass"

echo ">>> [INIT] Начинаем развертывание правильного кластера..."

# --- 1. ЛОКАЛЬНАЯ ПОДГОТОВКА (Машина, где запущен скрипт) ---
echo ">>> [LOCAL] Фикс локальных репозиториев и установка Ansible..."

# Фикс репозиториев (стиль из твоих скринов)
sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS*
sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/CentOS*
sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/CentOS*

yum install -y epel-release
yum install -y ansible

# --- 2. ГЕНЕРАЦИЯ ИНВЕНТАРЯ ---
echo ">>> [INVENTORY] Создаем /etc/ansible/hosts..."
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

# Отключаем проверку ключей SSH (чтобы не спрашивал yes/no)
cat <<EOF > /etc/ansible/ansible.cfg
[defaults]
host_key_checking = False
deprecation_warnings = False
command_warnings = False
EOF

# --- 3. ПЛЕЙБУК: ОБЩАЯ НАСТРОЙКА (ВАЖНО!) ---
# Этот плейбук чинит репозитории на ВСЕХ нодах перед установкой чего-либо.
cat <<EOF > /etc/ansible/00_common_setup.yml
---
- name: Prepare ALL Servers (Repos & SELinux)
  hosts: all_servers
  become: yes
  tasks:
    - name: Fix CentOS 7 Repositories (Vault)
      shell: |
        sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS*
        sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/CentOS*
        sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/CentOS*
      args:
        warn: no

    - name: Install Base Utils
      yum:
        name:
          - epel-release
          - nano
          - wget
          - net-tools
          - rsync
          - socat
        state: present

    - name: Disable SELinux (Immediate)
      command: setenforce 0
      ignore_errors: yes

    - name: Disable SELinux (Permanent)
      lineinfile:
        path: /etc/selinux/config
        regexp: '^SELINUX='
        line: 'SELINUX=disabled'
EOF

# --- 4. ПЛЕЙБУК: GALERA CLUSTER (БД) ---
# Используем MariaDB 10.11 (как на скрине намекалось, более свежая и стабильная)
cat <<EOF > /etc/ansible/01_galera_cluster.yml
---
- name: Deploy MariaDB 10.11 Galera Cluster
  hosts: dbservers
  become: yes
  vars:
    mysql_root_password: "$DB_ROOT_PASS"
    wp_db_password: "$WP_DB_PASS"
    node1_ip: "$DB1_IP"
    node2_ip: "$DB2_IP"

  tasks:
    - name: Remove Conflicting Libraries
      yum:
        name: mariadb-libs
        state: absent

    - name: Add MariaDB 10.11 Repo
      copy:
        dest: /etc/yum.repos.d/mariadb.repo
        content: |
          [mariadb]
          name = MariaDB
          baseurl = http://yum.mariadb.org/10.11/centos7-amd64
          gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
          gpgcheck=1

    - name: Install MariaDB Server & Galera
      yum:
        name:
          - MariaDB-server
          - MariaDB-client
          - MariaDB-shared
          - MariaDB-backup
        state: present

    - name: Configure Firewalld
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
          wsrep_cluster_name="my_cool_cluster"
          wsrep_node_address="{{ ansible_default_ipv4.address }}"
          wsrep_node_name="{{ ansible_hostname }}"
          binlog_format=row
          default_storage_engine=InnoDB
          innodb_autoinc_lock_mode=2
          bind-address=0.0.0.0

    - name: Ensure MariaDB is stopped before bootstrap
      systemd:
        name: mariadb
        state: stopped

- name: Bootstrap Cluster (Primary Node Only)
  hosts: db_primary
  become: yes
  tasks:
    - name: Start New Cluster
      command: galera_new_cluster
      ignore_errors: yes

- name: Join Secondary Nodes
  hosts: dbservers
  become: yes
  tasks:
    - name: Start MariaDB (Join Cluster)
      systemd:
        name: mariadb
        state: started
        enabled: yes

    - name: Setup DB Users (Run Once)
      run_once: true
      block:
        - name: Create Database
          mysql_db:
            name: wordpress_db
            state: present
            login_unix_socket: /var/lib/mysql/mysql.sock

        - name: Create WP User
          mysql_user:
            name: wp_user
            password: "{{ wp_db_password }}"
            priv: 'wordpress_db.*:ALL'
            host: '%'
            state: present
            login_unix_socket: /var/lib/mysql/mysql.sock

        - name: Create HAProxy Check User
          mysql_user:
            name: haproxy
            host: '%'
            state: present
            login_unix_socket: /var/lib/mysql/mysql.sock
EOF

# --- 5. ПЛЕЙБУК: HAPROXY ---
cat <<EOF > /etc/ansible/02_haproxy_lb.yml
---
- name: Setup HAProxy Load Balancer
  hosts: loadbalancer
  become: yes
  vars:
    web1_ip: "$WEB1_IP"
    web2_ip: "$WEB2_IP"
    db1_ip: "$DB1_IP"
    db2_ip: "$DB2_IP"

  tasks:
    - name: Install HAProxy
      yum:
        name: haproxy
        state: present

    - name: Configure HAProxy
      copy:
        dest: /etc/haproxy/haproxy.cfg
        content: |
          global
              log         127.0.0.1 local2
              chroot      /var/lib/haproxy
              pidfile     /var/run/haproxy.pid
              maxconn     4000
              user        haproxy
              group       haproxy
              daemon

          defaults
              mode                    http
              log                     global
              option                  httplog
              option                  dontlognull
              option http-server-close
              option forwardfor       except 127.0.0.0/8
              option                  redispatch
              retries                 3
              timeout http-request    10s
              timeout queue           1m
              timeout connect         10s
              timeout client          1m
              timeout server          1m
              timeout http-keep-alive 10s
              timeout check           10s
              maxconn                 3000

          frontend main_http
              bind *:80
              default_backend web_cluster

          backend web_cluster
              balance roundrobin
              server web1 {{ web1_ip }}:80 check
              server web2 {{ web2_ip }}:80 check

          listen mysql-cluster
              bind *:3306
              mode tcp
              option mysql-check user haproxy
              balance leastconn
              server db1 {{ db1_ip }}:3306 check
              server db2 {{ db2_ip }}:3306 check

          listen stats
              bind *:8404
              stats enable
              stats uri /monitor
              stats refresh 5s
              stats auth admin:admin

    - name: Open Firewall Ports
      firewalld:
        port: "{{ item }}"
        permanent: yes
        state: enabled
        immediate: yes
      loop:
        - 80/tcp
        - 3306/tcp
        - 8404/tcp

    - name: Start HAProxy
      systemd:
        name: haproxy
        state: restarted
        enabled: yes
EOF

# --- 6. ПЛЕЙБУК: WORDPRESS ---
cat <<EOF > /etc/ansible/03_wordpress_nodes.yml
---
- name: Deploy WordPress Nodes
  hosts: webservers
  become: yes
  vars:
    db_host: "$LB_IP"
    db_name: "wordpress_db"
    db_user: "wp_user"
    db_pass: "$WP_DB_PASS"
    wp_url: "https://ru.wordpress.org/latest-ru_RU.tar.gz"

  tasks:
    - name: Install Web Stack
      yum:
        name:
          - httpd
          - php
          - php-mysql
          - php-gd
          - wget
        state: present

    - name: Start HTTPD
      systemd:
        name: httpd
        state: started
        enabled: yes

    - name: Open Firewall for HTTP
      firewalld:
        service: http
        permanent: yes
        state: enabled
        immediate: yes

    - name: Check if WP already installed
      stat:
        path: /var/www/html/wp-config.php
      register: wp_check

    - name: Download and Unpack WordPress
      unarchive:
        src: "{{ wp_url }}"
        dest: /var/www/html/
        remote_src: yes
        extra_opts: [--strip-components=1]
      when: not wp_check.stat.exists

    - name: Configure wp-config.php
      copy:
        dest: /var/www/html/wp-config.php
        content: |
          <?php
          define( 'DB_NAME', '{{ db_name }}' );
          define( 'DB_USER', '{{ db_user }}' );
          define( 'DB_PASSWORD', '{{ db_pass }}' );
          define( 'DB_HOST', '{{ db_host }}' );
          define( 'DB_CHARSET', 'utf8' );
          define( 'DB_COLLATE', '' );
          \$table_prefix = 'wp_';
          define( 'WP_DEBUG', false );
          if ( ! defined( 'ABSPATH' ) ) {
            define( 'ABSPATH', __DIR__ . '/' );
          }
          require_once ABSPATH . 'wp-settings.php';

    - name: Set Permissions
      file:
        path: /var/www/html
        owner: apache
        group: apache
        mode: '0755'
        recurse: yes
EOF

echo "----------------------------------------------------------------"
echo "Скрипты сгенерированы в /etc/ansible/"
echo "Запускаю Ansible автоматически по очереди..."
echo "----------------------------------------------------------------"

# Автоматический запуск (чтобы руками не тыкать)
echo ">>> [1/4] ОБЩАЯ НАСТРОЙКА (РЕПОЗИТОРИИ)..."
ansible-playbook /etc/ansible/00_common_setup.yml

echo ">>> [2/4] УСТАНОВКА GALERA CLUSTER..."
ansible-playbook /etc/ansible/01_galera_cluster.yml

echo ">>> [3/4] УСТАНОВКА HAPROXY..."
ansible-playbook /etc/ansible/02_haproxy_lb.yml

echo ">>> [4/4] УСТАНОВКА WORDPRESS..."
ansible-playbook /etc/ansible/03_wordpress_nodes.yml

echo "----------------------------------------------------------------"
echo "ГОТОВО! ПРОВЕРЯЙ:"
echo "Статистика HAProxy: http://$LB_IP:8404/monitor (login: admin/admin)"
echo "WordPress сайт: http://$LB_IP"
echo "----------------------------------------------------------------"
