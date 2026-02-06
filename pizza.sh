---
- name: Deploy MariaDB Galera Cluster
  hosts: dbservers
  become: yes
  vars:
    mysql_root_password: "password3204"
    wp_db_password: "wppassword"
    # Твои актуальные IP
    node1_ip: "192.168.10.26"
    node2_ip: "192.168.10.29"

  tasks:
    - name: Удаляем старые репозитории и чистим кэш
      shell: |
        rm -f /etc/yum.repos.d/MariaDB.repo /etc/yum.repos.d/mariadb.repo
        yum clean all
        rm -rf /var/cache/yum

    - name: Удаляем конфликтующие пакеты mariadb-libs
      yum:
        name: mariadb-libs
        state: absent

    - name: Добавляем репозиторий MariaDB 10.11 (ПРЯМОЙ АРХИВ)
      copy:
        dest: /etc/yum.repos.d/MariaDB.repo
        content: |
          [mariadb]
          name = MariaDB
          baseurl = https://archive.mariadb.org/mariadb-10.11/yum/centos7-amd64
          gpgkey = https://archive.mariadb.org/PublicKeyManager
          gpgcheck = 1
          enabled = 1
          sslverify = 0

    - name: Установка пакетов MariaDB и Galera
      yum:
        name:
          - MariaDB-server
          - MariaDB-client
          - socat
          - rsync
          - MySQL-python
        state: present
        validate_certs: no

    - name: Открываем порты Firewall для кластера
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

    - name: Конфигурация Galera Cluster (server.cnf)
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
    - name: Запуск MariaDB на всех нодах
      systemd:
        name: mariadb
        state: started
        enabled: yes

    - name: Создание базы данных (только один раз)
      run_once: true
      mysql_db:
        name: wordpress_db
        state: present
        login_unix_socket: /var/lib/mysql/mysql.sock
