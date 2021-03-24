#Delete existing lxc containers
{
lxc list | grep CONTAINER | awk '{print $2}' | while read i
do
  lxc delete -f $i
done
}

#Create K3S LXC Profile
{

LXC_PROFILE="k3s"
LXC_CONTAINER_MEMORY="2GB"
LXC_CONTAINER_CPU="2"
lxc profile delete k3s

cat << EOF > profile_setup.sh
#!/bin/bash

LXC_PROFILE="k3s"
LXC_CONTAINER_MEMORY="2GB"
LXC_CONTAINER_CPU="2"


lxc profile copy default $LXC_PROFILE
lxc profile set ${LXC_PROFILE} security.privileged true
lxc profile set ${LXC_PROFILE} security.nesting true
lxc profile set ${LXC_PROFILE} limits.memory.swap false
lxc profile set ${LXC_PROFILE} limits.memory ${LXC_CONTAINER_MEMORY:-2GB}
lxc profile set ${LXC_PROFILE} limits.cpu ${LXC_CONTAINER_CPU:-2}
lxc profile set ${LXC_PROFILE} linux.kernel_modules overlay,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter,xt_conntrack,nf_conntrack,ip_vs,vxlan

cat <<EOT | lxc profile set ${LXC_PROFILE} raw.lxc -
lxc.apparmor.profile = unconfined
lxc.cgroup.devices.allow = a
lxc.mount.auto=proc:rw sys:rw
lxc.cap.drop =
EOT


lxc profile show ${LXC_PROFILE}
EOF
bash ./profile_setup.sh
}

#Create LXC containers
{
  profile=k3s
  for container_name in lb mysql master1 master2 worker1 worker2
  do
    lxc init images:ubuntu/bionic/amd64 --profile $profile $container_name
    lxc config device add "${container_name}" "kmsg" unix-char source="/dev/kmsg" path="/dev/kmsg"
	sleep 10
	lxc start $container_name
  done
}

#Setup MYSQL K3S DATASTORE
{
  container_name="mysql"
  cat > install_mysql.sh << EOF
  apt update && apt install openssl mysql-server curl -y
  sleep 10
  cp -pr /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf.orig
  sed 's/'127.0.0.1'/'0.0.0.0'/g' -i /etc/mysql/mysql.conf.d/mysqld.cnf
  systemctl restart mysql
  sleep 2
  mysql -u root < /tmp/setup_k3s_db.sql
EOF

  cat > setup_k3s_db.sql << EOF
  CREATE USER 'k3s'@'%' IDENTIFIED BY 'k3s_123';
  GRANT ALL PRIVILEGES ON *.* TO 'k3s'@'%';
  CREATE DATABASE k3s CHARACTER SET latin1 COLLATE latin1_swedish_ci;
EOF

  lxc file push install_mysql.sh $container_name/tmp/install_k3s.sh
  lxc file push setup_k3s_db.sql $container_name/tmp/setup_k3s_db.sql
  lxc exec $container_name -- bash /tmp/install_k3s.sh
  
}

#Setup LB
{
container_name="lb"
cat > install_haproxy.sh << EOF
apt update && apt install openssl net-tools haproxy curl -y
sleep 10
cp -pr /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig
cat /tmp/haproxy.cfg.append >> /etc/haproxy/haproxy.cfg
systemctl restart haproxy

EOF

lb_ip=`lxc list | grep lb | grep CONTAINER | awk '{print $6}'`
master1_ip=`lxc list | grep master1 | grep CONTAINER | awk '{print $6}'`
master2_ip=`lxc list | grep master2 | grep CONTAINER | awk '{print $6}'`
cat > haproxy.cfg.append << EOF

listen kubernetes-apiserver-https
  bind $lb_ip:6443
  mode tcp
  option log-health-checks
  timeout client 3h
  timeout server 3h
  server master1 $master1_ip:6443 check check-ssl verify none inter 10000
  server master2 $master2_ip:6443 check check-ssl verify none inter 10000
  balance roundrobin

EOF
lxc file push haproxy.cfg.append $container_name/tmp/haproxy.cfg.append
lxc file push install_haproxy.sh $container_name/tmp/install_haproxy.sh
lxc exec $container_name -- bash /tmp/install_haproxy.sh
}

#Setup K3S master nodes
{
lb_ip=`lxc list | grep lb | grep CONTAINER | awk '{print $6}'`
mysql_ip=`lxc list | grep mysql | grep CONTAINER | awk '{print $6}'`

for container_name in master1 master2
do

cat > install_k3s.sh << EOF
apt update && apt install openssl curl -y
export K3S_DATASTORE_ENDPOINT='mysql://k3s:k3s_123@tcp($mysql_ip:3306)/k3s'
curl -sfL https://get.k3s.io | sh -s - server --disable servicelb --node-taint CriticalAddonsOnly=true:NoExecute --tls-san $lb_ip

EOF


lxc file push install_k3s.sh $container_name/tmp/install_k3s.sh
lxc exec $container_name -- bash /tmp/install_k3s.sh


echo "writing config to $(pwd)/kubeconfig"
lxc exec $container_name -- bash -c "sed 's/127.0.0.1/$lb_ip/g' /etc/rancher/k3s/k3s.yaml" > $(pwd)/kubeconfig

done
}

#Setup K3S worker nodes
{
for container_name in worker1 worker2
do
K3S_MASTER_IP=`lxc list | grep lb | grep CONTAINER | awk '{print $6}'`
K3S_MASTER_NAME="master1"
K3S_TOKEN_VALUE=$(lxc exec $K3S_MASTER_NAME -- bash -c "cat /var/lib/rancher/k3s/server/node-token")
cat > install_k3s.sh << EOF
apt update && apt install openssl curl -y
curl -sfL https://get.k3s.io | K3S_URL=https://$K3S_MASTER_IP:6443 K3S_TOKEN=$K3S_TOKEN_VALUE sh -
sleep 20
EOF
lxc file push install_k3s.sh $container_name/tmp/install_k3s.sh
lxc exec $container_name -- bash /tmp/install_k3s.sh
done
}

#Install Kubeconfig
{
mkdir -p $HOME/.kube
cp kubeconfig $HOME/.kube/config
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
}

#Deploy MetalLB
{
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.6/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.6/manifests/metallb.yaml
# On first install only
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

cluster_subnet=`lxc list | grep CONTAINER | grep eth0 | grep lb | awk '{print $6}' | cut -f1-3 -d'.'`
cat << EOF > configmap-metallb.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $cluster_subnet.230-$cluster_subnet.250
EOF
kubectl apply -f configmap-metallb.yaml
}


