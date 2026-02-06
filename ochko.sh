#!/bin/bash

# =================================================================
# ULTIMATE HA CLUSTER DEPLOYMENT SCRIPT (RU WP VERSION)
# Role: HAProxy + Galera Cluster (2 Nodes) + WordPress (2 Nodes)
# =================================================================

# --- 0. НАСТРОЙКИ IP (Впиши сюда свои адреса!) ---
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

echo ">>> Начинаем развертывание ебейшего кластера (RU)..."

# --- 1. СИСТЕМНАЯ ПОДГОТОВКА ---
echo ">>> Фикс репозиториев и установка Ansible..."
sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS*
sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/CentOS*
sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/CentOS*

yum install -y epel-release
yum install -y ansible

# --- 2. ГЕНЕРАЦИЯ ИНВЕНТАРЯ ---
echo ">>> Создаем /etc/ansible/hosts..."
cat <<EOF > /etc/ansible/hosts
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

# --- 3. ПЛЕЙБУК: GALERA CLUSTER (БД) ---
cat <<EOF > /etc/ansible/galera_cluster.yml
---
- name: Deploy MariaDB Galera Cluster
  hosts: dbservers
  become: yes
  vars:
    mysql_root_password: "$DB_ROOT_PASS"
    haproxy_user_password: "$HAPROXY_CHECK_PASS"
    wp_db_password: "$WP_DB_PASS"
    node1_ip: "$DB1_IP"
    node2_ip: "$DB2_IP"

  tasks:
    - name: Добавляем репозиторий MariaDB 10.5
      copy:
        dest: /etc/yum.repos.d/mariadb.repo
        content: |
          [mariadb]
          name = MariaDB
          baseurl = http://yum.mariadb.org/10.5/centos7-amd64
          gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
          gpgcheck=1

    - name: Установка пакетов MariaDB и Galera
      yum:
        name:
          - MariaDB-server
          - MariaDB-client
          - MariaDB-common
          - socat
          - rsync
          - MySQL-python
        state: present

    - name: Открываем порты Firewall
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

    - name: Конфигурация server.cnf для Galera
      blockinfile:
        path: /etc/my.cnf.d/server.cnf
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

    - name: Остановка MariaDB перед бутстрапом
      systemd:
        name: mariadb
        state: stopped

- name: Bootstrap Cluster (Первая нода)
  hosts: db_primary
  become: yes
  tasks:
    - name: Запуск нового кластера
      command: galera_new_cluster
      ignore_errors: yes

- name: Start other nodes
  hosts: dbservers
  become: yes
  tasks:
    - name: Запуск MariaDB
      systemd:
        name: mariadb
        state: started
        enabled: yes

    - name: Создание базы и юзеров (run_once)
      run_once: true
      block:
        - name: Создать базу WordPress
          mysql_db:
            name: wordpress_db
            state: present
            login_unix_socket: /var/lib/mysql/mysql.sock

        - name: Создать юзера для WP
          mysql_user:
            name: wp_user
            password: "{{ wp_db_password }}"
            priv: 'wordpress_db.*:ALL'
            host: '%'
            state: present
            login_unix_socket: /var/lib/mysql/mysql.sock

        - name: Создать юзера для HAProxy check
          mysql_user:
            name: haproxy
            host: '%'
            state: present
            login_unix_socket: /var/lib/mysql/mysql.sock
EOF

# --- 4. ПЛЕЙБУК: HAPROXY (БАЛАНСЕР) ---
cat <<EOF > /etc/ansible/haproxy_lb.yml
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

    - name: Разрешить HAProxy коннектиться (SELinux)
      command: setsebool -P haproxy_connect_any 1
      ignore_errors: yes

    - name: Настройка конфига haproxy.cfg
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

    - name: Открыть порты Firewall
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

# --- 5. ПЛЕЙБУК: WORDPRESS (ВЕБ-СЕРВЕРА) ---
cat <<EOF > /etc/ansible/wordpress_nodes.yml
---
- name: Deploy WordPress Nodes (RU)
  hosts: webservers
  become: yes
  vars:
    db_host: "$LB_IP"
    db_name: "wordpress_db"
    db_user: "wp_user"
    db_pass: "$WP_DB_PASS"
    # ССЫЛКА НА РУССКИЙ WORDPRESS
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

    - name: Firewall HTTP
      firewalld:
        service: http
        permanent: yes
        state: enabled
        immediate: yes

    - name: Download Russian WordPress
      get_url:
        url: "{{ wp_url }}"
        dest: /tmp/wordpress.tar.gz

    - name: Unpack WP
      unarchive:
        src: /tmp/wordpress.tar.gz
        dest: /var/www/html/
        remote_src: yes
        extra_opts: [--strip-components=1]

    - name: Настройка wp-config.php
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

    - name: Права доступа
      file:
        path: /var/www/html
        owner: apache
        group: apache
        mode: '0755'
        recurse: yes
      
    - name: SELinux httpd network connect
      command: setsebool -P httpd_can_network_connect 1
      ignore_errors: yes
EOF

echo "----------------------------------------------------------------"
echo "Конфигурация завершена. Файлы лежат в /etc/ansible/"
echo ""
echo "ЗАПУСК:"
echo "1. ansible-playbook /etc/ansible/galera_cluster.yml"
echo "2. ansible-playbook /etc/ansible/haproxy_lb.yml"
echo "3. ansible-playbook /etc/ansible/wordpress_nodes.yml"
echo "----------------------------------------------------------------"
